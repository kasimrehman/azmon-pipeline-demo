#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: refresh-demo-certificates.sh <pipeline-namespace> <pipeline-name>" >&2
  exit 2
fi

pipeline_namespace="$1"
pipeline_name="$2"
gateway_certificate="gateway-client-cert"
pipeline_certificate="${pipeline_name}-pipeline-tls-certificate"
gateway_deployment="traefik-${pipeline_name}"
pipeline_statefulset="${pipeline_name}-statefulset"
trust_updated=false

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

certificate_fingerprint_from_secret() {
  kubectl get secret "$1" -n "$2" -o jsonpath='{.data.tls\.crt}' |
    base64 -d |
    openssl x509 -outform DER |
    sha256sum |
    cut -d ' ' -f 1
}

certificate_fingerprint_from_configmap() {
  kubectl get configmap "$1" -n "$2" -o jsonpath='{.data.ca\.crt}' |
    openssl x509 -outform DER |
    sha256sum |
    cut -d ' ' -f 1
}

reconcile_root_alias() {
  local base="$1"
  local current="${base}-current"
  local base_fingerprint
  local current_fingerprint=""

  base_fingerprint="$(certificate_fingerprint_from_secret "$base" cert-manager)"
  if kubectl get secret "$current" -n cert-manager >/dev/null 2>&1; then
    current_fingerprint="$(certificate_fingerprint_from_secret "$current" cert-manager)"
  fi
  if [[ "$base_fingerprint" != "$current_fingerprint" ]]; then
    kubectl get secret "$base" -n cert-manager -o json | jq \
      --arg base "$base" \
      --arg current "$current" \
      '{
        apiVersion: "v1",
        kind: "Secret",
        metadata: {
          name: $current,
          namespace: "cert-manager",
          labels: {
            "microsoft-certmanagement.clusterextensions.azure.com/ac-rotation-active": $base
          }
        },
        type: .type,
        data: .data
      }' | kubectl apply -f - >/dev/null
    trust_updated=true
    echo "Updated certificate rotation alias ${current}."
  fi
}

wait_for_trust_bundle() {
  local root_secret="$1"
  local trust_bundle="$2"
  local source_fingerprint

  source_fingerprint="$(certificate_fingerprint_from_secret "$root_secret" cert-manager)"
  for _ in {1..60}; do
    if [[ "$(certificate_fingerprint_from_configmap "$trust_bundle" "$pipeline_namespace")" == "$source_fingerprint" ]]; then
      return
    fi
    sleep 2
  done
  echo "Trust bundle '$trust_bundle' did not synchronize with '$root_secret'." >&2
  exit 1
}

leaf_matches_trust_bundle() {
  local certificate_name="$1"
  local trust_bundle="$2"
  local secret_name
  local temporary_directory

  secret_name="$(
    kubectl get certificate "$certificate_name" \
      -n "$pipeline_namespace" \
      -o jsonpath='{.spec.secretName}'
  )"
  if ! kubectl get secret "$secret_name" -n "$pipeline_namespace" >/dev/null 2>&1; then
    return 1
  fi

  temporary_directory="$(mktemp -d)"
  kubectl get secret "$secret_name" \
    -n "$pipeline_namespace" \
    -o jsonpath='{.data.tls\.crt}' |
    base64 -d > "${temporary_directory}/leaf.crt"
  kubectl get configmap "$trust_bundle" \
    -n "$pipeline_namespace" \
    -o jsonpath='{.data.ca\.crt}' > "${temporary_directory}/ca.crt"
  local verification_status
  if openssl verify \
    -CAfile "${temporary_directory}/ca.crt" \
    "${temporary_directory}/leaf.crt" >/dev/null 2>&1; then
    verification_status=0
  else
    verification_status=1
  fi
  rm -rf "$temporary_directory"
  return "$verification_status"
}

ensure_leaf_matches_trust_bundle() {
  local certificate_name="$1"
  local trust_bundle="$2"
  local secret_name

  if leaf_matches_trust_bundle "$certificate_name" "$trust_bundle"; then
    return
  fi

  secret_name="$(
    kubectl get certificate "$certificate_name" \
      -n "$pipeline_namespace" \
      -o jsonpath='{.spec.secretName}'
  )"
  echo "Reissuing certificate ${certificate_name}: its leaf does not match ${trust_bundle}."
  kubectl delete secret "$secret_name" -n "$pipeline_namespace" --ignore-not-found
  trust_updated=true

  for _ in {1..150}; do
    if leaf_matches_trust_bundle "$certificate_name" "$trust_bundle"; then
      return
    fi
    sleep 2
  done
  echo "Certificate '$certificate_name' was not reissued from the current trust root." >&2
  exit 1
}

certificate_not_before() {
  kubectl get certificate "$1" \
    -n "$pipeline_namespace" \
    -o jsonpath='{.status.notBefore}'
}

oldest_pod_start() {
  local workload_name="$1"
  local pod_name

  pod_name="$(
    kubectl get pods -n "$pipeline_namespace" -o name |
      grep "^pod/${workload_name}" |
      head -n 1
  )"
  if [[ -n "$pod_name" ]]; then
    kubectl get "$pod_name" \
      -n "$pipeline_namespace" \
      -o jsonpath='{.status.startTime}'
  fi
}

restart_if_stale() {
  local certificate_name="$1"
  local workload_type="$2"
  local workload_name="$3"
  local not_before
  local pod_started

  kubectl wait --for=condition=Ready \
    "certificate/${certificate_name}" \
    -n "$pipeline_namespace" \
    --timeout=300s

  not_before="$(certificate_not_before "$certificate_name")"
  pod_started="$(oldest_pod_start "$workload_name")"
  if [[ -z "$not_before" || -z "$pod_started" ]]; then
    echo "Could not compare certificate '$certificate_name' with workload '$workload_name'." >&2
    exit 1
  fi

  if [[ "$trust_updated" == "true" ]] ||
    (( $(date -d "$not_before" +%s) > $(date -d "$pod_started" +%s) )); then
    echo "Restarting ${workload_type}/${workload_name}: its pod predates certificate ${certificate_name}."
    kubectl rollout restart "${workload_type}/${workload_name}" -n "$pipeline_namespace"
    kubectl rollout status "${workload_type}/${workload_name}" \
      -n "$pipeline_namespace" \
      --timeout=300s
  else
    echo "${workload_type}/${workload_name} already uses the current certificate."
  fi
}

reconcile_root_alias arc-amp-root-ca
reconcile_root_alias arc-amp-client-root-ca
wait_for_trust_bundle arc-amp-root-ca arc-amp-trust-bundle
wait_for_trust_bundle arc-amp-client-root-ca arc-amp-client-trust-bundle
ensure_leaf_matches_trust_bundle \
  "$pipeline_certificate" \
  arc-amp-trust-bundle
ensure_leaf_matches_trust_bundle \
  "$gateway_certificate" \
  arc-amp-client-trust-bundle

restart_if_stale \
  "$pipeline_certificate" \
  statefulset \
  "$pipeline_statefulset"

restart_if_stale \
  "$gateway_certificate" \
  deployment \
  "$gateway_deployment"
