#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 6 ]]; then
  echo "Usage: $0 <subscription-id> <resource-group> <cluster-name> <location> <k3s-version> <custom-locations-oid>" >&2
  exit 2
fi

subscription_id="$1"
resource_group="$2"
cluster_name="$3"
location="$4"
k3s_version="$5"
custom_locations_oid="$6"

if [[ ! "$k3s_version" =~ ^v1\.[0-9]+\.[0-9]+\+k3s[0-9]+$ ]]; then
  echo "K3s version must use the form v1.33.3+k3s1." >&2
  exit 2
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl jq

cat > /etc/sysctl.d/99-arcmon-k3s.conf <<EOF
fs.inotify.max_user_instances=8192
fs.inotify.max_user_watches=1048576
EOF
sysctl --system >/dev/null

private_ip="$(hostname -I | awk '{print $1}')"
if ! command -v k3s >/dev/null 2>&1; then
  curl -sfL https://get.k3s.io | \
    INSTALL_K3S_VERSION="$k3s_version" \
    INSTALL_K3S_EXEC="server --disable traefik --node-ip ${private_ip} --tls-san ${private_ip}" \
    K3S_KUBECONFIG_MODE=600 \
    sh -
fi

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
for attempt in {1..60}; do
  if [[ -n "$(kubectl get nodes --output=name 2>/dev/null || true)" ]]; then
    break
  fi
  if [[ "$attempt" -eq 60 ]]; then
    echo "K3s did not register a node within 300 seconds." >&2
    exit 1
  fi
  sleep 5
done

kubectl wait --for=condition=Ready node --all --timeout=300s

if ! command -v helm >/dev/null 2>&1; then
  export DESIRED_VERSION=v3.18.6
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

if ! command -v az >/dev/null 2>&1; then
  apt-get install -y apt-transport-https gnupg lsb-release
  mkdir -p /etc/apt/keyrings
  curl -sLS https://packages.microsoft.com/keys/microsoft.asc | \
    gpg --dearmor --yes --output /etc/apt/keyrings/microsoft.gpg
  chmod go+r /etc/apt/keyrings/microsoft.gpg
  cat > /etc/apt/sources.list.d/azure-cli.sources <<EOF
Types: deb
URIs: https://packages.microsoft.com/repos/azure-cli/
Suites: $(lsb_release -cs)
Components: main
Architectures: $(dpkg --print-architecture)
Signed-by: /etc/apt/keyrings/microsoft.gpg
EOF
  apt-get update
  apt-get install -y azure-cli
fi

command -v az >/dev/null 2>&1 || {
  echo "Azure CLI installation did not succeed." >&2
  exit 1
}

az extension add --name connectedk8s --upgrade --only-show-errors
az extension add --name k8s-extension --upgrade --only-show-errors
az extension add --name customlocation --upgrade --only-show-errors

identity_subscription_ready=false
for attempt in {1..30}; do
  if az login --identity --allow-no-subscriptions --output none --only-show-errors && \
    az account show \
      --subscription "$subscription_id" \
      --output none \
      --only-show-errors; then
    identity_subscription_ready=true
    break
  fi

  echo "Managed identity cannot access subscription yet (attempt ${attempt}/30); retrying in 10 seconds." >&2
  sleep 10
done

if [[ "$identity_subscription_ready" != true ]]; then
  echo "Managed identity login succeeded, but subscription ${subscription_id} did not become accessible after waiting for role propagation." >&2
  exit 1
fi

az account set --subscription "$subscription_id"

arc_connected=false
arc_features_requested=false
for attempt in {1..12}; do
  arc_status="$(az connectedk8s show \
    --subscription "$subscription_id" \
    --resource-group "$resource_group" \
    --name "$cluster_name" \
    --query connectivityStatus \
    --output tsv \
    --only-show-errors 2>/dev/null || true)"
  if [[ "$arc_status" == "Connected" ]]; then
    arc_connected=true
    break
  fi

  if [[ -n "$arc_status" ]]; then
    sleep 10
    continue
  fi

  if az connectedk8s connect \
    --subscription "$subscription_id" \
    --resource-group "$resource_group" \
    --name "$cluster_name" \
    --location "$location" \
    --kube-config "$KUBECONFIG" \
    --distribution k3s \
    --infrastructure azure \
    --custom-locations-oid "$custom_locations_oid" \
    --yes \
    --only-show-errors \
    --output none; then
    arc_features_requested=true
    for status_attempt in {1..30}; do
      arc_status="$(az connectedk8s show \
        --subscription "$subscription_id" \
        --resource-group "$resource_group" \
        --name "$cluster_name" \
        --query connectivityStatus \
        --output tsv \
        --only-show-errors 2>/dev/null || true)"
      if [[ "$arc_status" == "Connected" ]]; then
        arc_connected=true
        break 2
      fi
      sleep 10
    done
  fi

  sleep 10
done

if [[ "$arc_connected" != true ]]; then
  echo "Azure Arc connection did not succeed after waiting for role propagation." >&2
  exit 1
fi

if [[ "$arc_features_requested" != true ]]; then
  for attempt in {1..3}; do
    if az connectedk8s enable-features \
      --subscription "$subscription_id" \
      --resource-group "$resource_group" \
      --name "$cluster_name" \
      --kube-config "$KUBECONFIG" \
      --custom-locations-oid "$custom_locations_oid" \
      --features cluster-connect custom-locations \
      --only-show-errors \
      --output none; then
      arc_features_requested=true
      break
    fi

    if [[ "$attempt" -lt 3 ]]; then
      echo "Azure Arc feature enablement attempt ${attempt} failed; retrying in 30 seconds." >&2
      sleep 30
    fi
  done
fi

if [[ "$arc_features_requested" != true ]] || \
  ! kubectl wait --for=condition=Available deployment --all \
    --namespace azure-arc \
    --timeout=300s; then
  echo "Azure Arc cluster-connect and custom-locations features did not become ready." >&2
  kubectl get pods --namespace azure-arc --output=wide >&2 || true
  exit 1
fi

actual_version="$(kubectl get node -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}')"
if [[ "$actual_version" != "$k3s_version" ]]; then
  echo "Expected K3s ${k3s_version}, but the node reports ${actual_version}." >&2
  exit 1
fi

echo "K3s ${actual_version} is Ready and connected to Azure Arc as ${cluster_name}."