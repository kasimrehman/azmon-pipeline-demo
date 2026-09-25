#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: prepare-demo-storage.sh <pipeline-namespace> <persistent-volume-name> <capacity>" >&2
  exit 2
fi

pipeline_namespace="$1"
persistent_volume_name="$2"
capacity="$3"
host_path="/var/lib/azure-monitor-pipeline-demo/buffer"

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

kubectl wait --for=jsonpath='{.status.phase}'=Active \
  "namespace/${pipeline_namespace}" --timeout=300s
# K3s user namespaces remap container root to an unprivileged host UID. Keep this
# permissive path isolated to the disposable demo buffer; do not use it in production.
install -d -m 0777 "$host_path"
chmod 0777 "$host_path"

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${persistent_volume_name}
  labels:
    app.kubernetes.io/part-of: azure-monitor-pipeline-demo
    app.kubernetes.io/component: exporter-buffer
spec:
  capacity:
    storage: ${capacity}
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  volumeMode: Filesystem
  hostPath:
    path: ${host_path}
    type: DirectoryOrCreate
EOF

access_modes="$(kubectl get pv "$persistent_volume_name" -o jsonpath='{.spec.accessModes[*]}')"
if [[ " $access_modes " != *" ReadWriteMany "* ]]; then
  echo "Persistent volume does not advertise ReadWriteMany." >&2
  exit 1
fi

echo "Persistent volume: ${persistent_volume_name}"
echo "Phase: $(kubectl get pv "$persistent_volume_name" -o jsonpath='{.status.phase}')"
echo "Capacity: $(kubectl get pv "$persistent_volume_name" -o jsonpath='{.spec.capacity.storage}')"
echo "Host path mode: $(stat -c '%a' "$host_path")"
echo "Storage note: hostPath is suitable only for this single-node demonstration."
