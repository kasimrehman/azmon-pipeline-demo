#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <pipeline-namespace>" >&2
  exit 2
fi

pipeline_namespace="$1"

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
    echo "Azure Monitor pipeline certificate trust is ready."
    exit 0
  fi
  if [[ "$attempt" -eq 60 ]]; then
    echo "The Azure Monitor trust bundles were not synchronized." >&2
    exit 1
  fi
  sleep 10
done