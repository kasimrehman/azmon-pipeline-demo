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
host_path="/var/lib/azure-monitor-pipeline-demo/buffer"
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
host_path_mode="$(stat -c '%a' "$host_path")"
echo "persistentVolume=${persistent_volume_name}"
echo "persistentVolumePhase=${volume_phase}"
echo "persistentVolumeAccessModes=${volume_modes}"
echo "persistentVolumeCapacity=${volume_capacity}"
echo "bufferHostPathMode=${host_path_mode}"

if [[ " $volume_modes " != *" ReadWriteMany "* ]]; then
  echo "Persistent volume does not advertise ReadWriteMany." >&2
  exit 1
fi
if [[ "$volume_phase" != "Bound" ]]; then
  echo "Persistent volume is not bound to the pipeline yet." >&2
  exit 1
fi
if [[ "$host_path_mode" != "777" ]]; then
  echo "Demo buffer host path is not writable by the user-namespaced collector. Re-run setup-demo.ps1." >&2
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
  kubectl get pods -n "$pipeline_namespace" -o wide >&2 || true
  pipeline_pod="$(kubectl get pods -n "$pipeline_namespace" -o name | grep "/${pipeline_name}-statefulset-" | head -n 1 || true)"
  if [[ -n "$pipeline_pod" ]]; then
    kubectl get "$pipeline_pod" -n "$pipeline_namespace" \
      -o jsonpath='{range .status.containerStatuses[*]}{.name}{" ready="}{.ready}{" restarts="}{.restartCount}{" waiting="}{.state.waiting.reason}{" lastExit="}{.lastState.terminated.exitCode}{" lastReason="}{.lastState.terminated.reason}{"\n"}{end}' >&2 || true
    kubectl logs "$pipeline_pod" -n "$pipeline_namespace" -c collector --previous --tail=30 >&2 || \
      kubectl logs "$pipeline_pod" -n "$pipeline_namespace" -c collector --tail=30 >&2 || true
  fi
  exit 1
fi

df -h "$host_path" | tail -n 1 | awk '{print "bufferDisk=" $4 "-free-of-" $2}'
