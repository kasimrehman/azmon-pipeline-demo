#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: manage-arc-portal-token.sh <issue|revoke> <namespace> <service-account-name>" >&2
  exit 2
fi

action="$1"
namespace="$2"
service_account="$3"
view_binding="${service_account}-view"
cluster_details_role="${service_account}-cluster-details"
cluster_details_binding="${service_account}-cluster-details"
token_secret="${service_account}-token"

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

if [[ "$action" == "revoke" ]]; then
  kubectl delete clusterrolebinding \
    "$view_binding" \
    "$cluster_details_binding" \
    --ignore-not-found >/dev/null
  kubectl delete clusterrole "$cluster_details_role" --ignore-not-found >/dev/null
  kubectl delete secret "$token_secret" -n "$namespace" --ignore-not-found >/dev/null
  kubectl delete serviceaccount "$service_account" -n "$namespace" --ignore-not-found >/dev/null
  echo "Revoked portal access for ${namespace}/${service_account}."
  exit 0
fi

if [[ "$action" != "issue" ]]; then
  echo "Action must be 'issue' or 'revoke'." >&2
  exit 2
fi

kubectl create serviceaccount "$service_account" \
  -n "$namespace" \
  --dry-run=client \
  -o yaml |
  kubectl apply -f - >/dev/null

cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ${cluster_details_role}
rules:
  - apiGroups: [""]
    resources: ["namespaces", "nodes", "persistentvolumes"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["storage.k8s.io"]
    resources: ["storageclasses", "csidrivers", "csinodes", "volumeattachments"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apiextensions.k8s.io"]
    resources: ["customresourcedefinitions"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${view_binding}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: view
subjects:
  - kind: ServiceAccount
    name: ${service_account}
    namespace: ${namespace}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${cluster_details_binding}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ${cluster_details_role}
subjects:
  - kind: ServiceAccount
    name: ${service_account}
    namespace: ${namespace}
EOF

kubectl delete secret "$token_secret" -n "$namespace" --ignore-not-found >/dev/null
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Secret
metadata:
  name: ${token_secret}
  namespace: ${namespace}
  annotations:
    kubernetes.io/service-account.name: ${service_account}
type: kubernetes.io/service-account-token
EOF

token=""
for _ in {1..30}; do
  token="$(
    kubectl get secret "$token_secret" \
      -n "$namespace" \
      -o jsonpath='{.data.token}' 2>/dev/null |
      base64 -d
  )"
  if [[ -n "$token" ]]; then
    break
  fi
  sleep 1
done
if [[ -z "$token" ]]; then
  echo "The service account token Secret was not populated." >&2
  exit 1
fi

if ! kubectl auth can-i list pods \
  --all-namespaces \
  --as="system:serviceaccount:${namespace}:${service_account}" |
  grep -qx yes; then
  echo "The service account cannot list pods." >&2
  exit 1
fi
if kubectl auth can-i get secrets \
  --all-namespaces \
  --as="system:serviceaccount:${namespace}:${service_account}" |
  grep -qx yes; then
  echo "The service account unexpectedly has permission to read Secrets." >&2
  exit 1
fi

printf '%s\n' '__ARC_PORTAL_TOKEN_BEGIN__'
printf '%s\n' "$token"
printf '%s\n' '__ARC_PORTAL_TOKEN_END__'
