#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <pipeline-namespace> <pipeline-name> <traefik-chart-version>" >&2
  exit 2
fi

pipeline_namespace="$1"
pipeline_name="$2"
traefik_chart_version="$3"
gateway_selector="${pipeline_name}-gateway"
helm_release="traefik-${pipeline_name}"
pipeline_service="${pipeline_name}-service"

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

kubectl wait --for=jsonpath='{.status.phase}'=Active \
  "namespace/${pipeline_namespace}" --timeout=300s
kubectl label namespace "$pipeline_namespace" \
  arc-amp-client=true \
  arc-amp-trust-bundle=true \
  --overwrite

for attempt in {1..60}; do
  if kubectl get secret arc-amp-root-ca -n cert-manager >/dev/null 2>&1 && \
    kubectl get secret arc-amp-client-root-ca -n cert-manager >/dev/null 2>&1; then
    break
  fi
  if [[ "$attempt" -eq 60 ]]; then
    echo "The Azure Monitor root certificates were not created." >&2
    exit 1
  fi
  sleep 10
done

for base in arc-amp-root-ca arc-amp-client-root-ca; do
  current="${base}-current"
  if ! kubectl get secret "$current" -n cert-manager >/dev/null 2>&1; then
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
  fi
  kubectl label secret "$current" -n cert-manager \
    "microsoft-certmanagement.clusterextensions.azure.com/ac-rotation-active=${base}" \
    --overwrite >/dev/null
done

kubectl wait --for=condition=Ready \
  clusterissuer/arc-amp-root-ca-cluster-issuer \
  clusterissuer/arc-amp-client-root-ca-cluster-issuer \
  --timeout=300s

for attempt in {1..60}; do
  if kubectl get configmap arc-amp-trust-bundle -n "$pipeline_namespace" >/dev/null 2>&1 && \
    kubectl get configmap arc-amp-client-trust-bundle -n "$pipeline_namespace" >/dev/null 2>&1; then
    break
  fi
  if [[ "$attempt" -eq 60 ]]; then
    echo "The Azure Monitor trust bundles were not synchronized." >&2
    exit 1
  fi
  sleep 10
done

cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: gateway-client-cert
  namespace: ${pipeline_namespace}
spec:
  secretName: gateway-client-tls
  duration: 48h
  renewBefore: 24h
  issuerRef:
    name: arc-amp-client-root-ca-cluster-issuer
    kind: ClusterIssuer
    group: cert-manager.io
  commonName: traefik-gateway-client
  usages:
    - client auth
  privateKey:
    algorithm: ECDSA
    size: 256
EOF

kubectl wait --for=condition=Ready certificate/gateway-client-cert \
  -n "$pipeline_namespace" --timeout=300s

for attempt in {1..90}; do
  service_ports="$(kubectl get service "$pipeline_service" \
    -n "$pipeline_namespace" \
    -o jsonpath='{range .spec.ports[*]}{.port}{" "}{end}' \
    2>/dev/null || true)"
  ready_addresses="$(kubectl get endpoints "$pipeline_service" \
    -n "$pipeline_namespace" \
    -o jsonpath='{range .subsets[*].addresses[*]}{.ip}{" "}{end}' \
    2>/dev/null || true)"
  if [[ " $service_ports " == *" 514 "* ]] && \
    [[ " $service_ports " == *" 4317 "* ]] && \
    [[ -n "$ready_addresses" ]]; then
    break
  fi
  if [[ "$attempt" -eq 90 ]]; then
    echo "The Azure Monitor pipeline service did not expose ready Syslog and OTLP endpoints." >&2
    kubectl get service "$pipeline_service" -n "$pipeline_namespace" -o wide >&2 || true
    kubectl get endpoints "$pipeline_service" -n "$pipeline_namespace" -o wide >&2 || true
    kubectl get pods -n "$pipeline_namespace" -o wide >&2 || true
    exit 1
  fi
  sleep 10
done

helm repo add traefik https://traefik.github.io/charts 2>/dev/null || true
helm repo update traefik
helm show crds traefik/traefik --version "$traefik_chart_version" | kubectl apply -f -

cat <<EOF | kubectl apply -f -
apiVersion: traefik.io/v1alpha1
kind: ServersTransportTCP
metadata:
  name: ${pipeline_name}-mtls-transport
  namespace: ${pipeline_namespace}
  labels:
    traefik-instance: ${gateway_selector}
spec:
  tls:
    serverName: "${pipeline_service}.${pipeline_namespace}.svc.cluster.local"
    rootCAs:
      - configMap: arc-amp-trust-bundle
    certificatesSecrets:
      - gateway-client-tls
    insecureSkipVerify: false
---
apiVersion: traefik.io/v1alpha1
kind: IngressRouteTCP
metadata:
  name: ${pipeline_name}-syslog-route
  namespace: ${pipeline_namespace}
  labels:
    traefik-instance: ${gateway_selector}
spec:
  entryPoints:
    - tcp-syslog
  routes:
    - match: HostSNI(\`*\`)
      services:
        - name: ${pipeline_service}
          port: 514
          tls: true
          serversTransport: ${pipeline_name}-mtls-transport
---
apiVersion: traefik.io/v1alpha1
kind: IngressRouteTCP
metadata:
  name: ${pipeline_name}-otlp-route
  namespace: ${pipeline_namespace}
  labels:
    traefik-instance: ${gateway_selector}
spec:
  entryPoints:
    - tcp-otlp
  routes:
    - match: HostSNI(\`*\`)
      services:
        - name: ${pipeline_service}
          port: 4317
          tls: true
          serversTransport: ${pipeline_name}-mtls-transport
EOF

helm upgrade --install "$helm_release" traefik/traefik \
  --version "$traefik_chart_version" \
  --namespace "$pipeline_namespace" \
  --set deployment.replicas=1 \
  --set providers.kubernetesIngress.enabled=false \
  --set providers.kubernetesCRD.enabled=true \
  --set "providers.kubernetesCRD.labelSelector=traefik-instance=${gateway_selector}" \
  --set ports.tcp-syslog.port=514 \
  --set ports.tcp-syslog.expose.default=true \
  --set ports.tcp-syslog.exposedPort=514 \
  --set ports.tcp-syslog.protocol=TCP \
  --set ports.tcp-otlp.port=4317 \
  --set ports.tcp-otlp.expose.default=true \
  --set ports.tcp-otlp.exposedPort=4317 \
  --set ports.tcp-otlp.protocol=TCP \
  --set ports.web.expose.default=false \
  --set ports.websecure.expose.default=false \
  --set service.type=LoadBalancer \
  --wait \
  --timeout 10m

kubectl wait --for=condition=Available "deployment/${helm_release}" \
  -n "$pipeline_namespace" \
  --timeout=300s

service_ip="$(kubectl get service "$helm_release" -n "$pipeline_namespace" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
echo "Gateway is Ready. Kubernetes LoadBalancer address: ${service_ip:-pending}"