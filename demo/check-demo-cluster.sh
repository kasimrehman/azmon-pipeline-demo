#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <pipeline-namespace> <pipeline-name> <persistent-volume-name>" >&2
  exit 2
fi

pipeline_namespace="$1"
pipeline_name="$2"
persistent_volume_name="$3"
state_file="/var/lib/azure-monitor-pipeline-demo/blocked-dce-routes"
pipeline_service="${pipeline_name}-service"

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

if [[ -s "$state_file" ]]; then
  echo "outage=ACTIVE"
  exit 1
fi
echo "outage=INACTIVE"

volume_phase="$(kubectl get pv "$persistent_volume_name" -o jsonpath='{.status.phase}')"
volume_modes="$(kubectl get pv "$persistent_volume_name" -o jsonpath='{.spec.accessModes[*]}')"
volume_capacity="$(kubectl get pv "$persistent_volume_name" -o jsonpath='{.spec.capacity.storage}')"
echo "persistentVolume=${persistent_volume_name}"
echo "persistentVolumePhase=${volume_phase}"
echo "persistentVolumeAccessModes=${volume_modes}"
echo "persistentVolumeCapacity=${volume_capacity}"

if [[ " $volume_modes " != *" ReadWriteMany "* ]]; then
  echo "Persistent volume does not advertise ReadWriteMany." >&2
  exit 1
fi
if [[ "$volume_phase" != "Bound" ]]; then
  echo "Persistent volume is not bound to the pipeline yet." >&2
  exit 1
fi

service_ports="$(kubectl get service "$pipeline_service" -n "$pipeline_namespace" -o jsonpath='{range .spec.ports[*]}{.port}{" "}{end}')"
ready_addresses="$(kubectl get endpoints "$pipeline_service" -n "$pipeline_namespace" -o jsonpath='{range .subsets[*].addresses[*]}{.ip}{" "}{end}')"
echo "servicePorts=${service_ports}"
echo "readyAddresses=${ready_addresses}"

if [[ " $service_ports " != *" 514 "* || " $service_ports " != *" 4317 "* ]]; then
  echo "Pipeline service does not expose both required receiver ports." >&2
  exit 1
fi
if [[ -z "$ready_addresses" ]]; then
  echo "Pipeline service has no ready endpoints." >&2
  exit 1
fi

df -h /var/lib/azure-monitor-pipeline-demo/buffer | tail -n 1 | awk '{print "bufferDisk=" $4 "-free-of-" $2}'
