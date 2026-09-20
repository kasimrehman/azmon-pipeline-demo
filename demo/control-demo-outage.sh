#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <block|restore|status> <dce-hostname>" >&2
  exit 2
fi

action="${1,,}"
dce_hostname="$2"
state_dir="/var/lib/azure-monitor-pipeline-demo"
state_file="${state_dir}/blocked-dce-routes"
route_metric="42760"

install -d -m 0750 "$state_dir"

case "$action" in
  block)
    if [[ -s "$state_file" ]]; then
      echo "Demo outage is already active."
      cat "$state_file"
      exit 0
    fi

    mapfile -t addresses < <(getent ahostsv4 "$dce_hostname" | awk '{print $1}' | sort -u)
    if [[ ${#addresses[@]} -eq 0 ]]; then
      echo "Could not resolve an IPv4 address for ${dce_hostname}." >&2
      exit 1
    fi

    temporary_state="${state_file}.tmp"
    added_addresses=()
    rollback_routes() {
      status="${1:-1}"
      trap - ERR INT TERM
      for added_address in "${added_addresses[@]}"; do
        ip route del blackhole "${added_address}/32" metric "$route_metric" 2>/dev/null || true
      done
      rm -f "$temporary_state"
      exit "$status"
    }
    trap 'rollback_routes $?' ERR
    trap 'rollback_routes 130' INT
    trap 'rollback_routes 143' TERM
    : > "$temporary_state"
    for address in "${addresses[@]}"; do
      if ip route show exact "${address}/32" | grep -q .; then
        echo "A host route already exists for ${address}; refusing to replace it." >&2
        false
      fi
      ip route add blackhole "${address}/32" metric "$route_metric"
      added_addresses+=("$address")
      echo "$address" >> "$temporary_state"
    done
    mv "$temporary_state" "$state_file"
    trap - ERR INT TERM
    echo "Demo outage active for addresses currently resolved by ${dce_hostname}: ${addresses[*]}"
    echo "Other destinations sharing these addresses can also be affected."
    ;;

  restore)
    if [[ ! -s "$state_file" ]]; then
      rm -f "$state_file"
      echo "Demo outage is not active."
      exit 0
    fi

    remaining_state="${state_file}.remaining"
    : > "$remaining_state"
    while IFS= read -r address; do
      ip route del blackhole "${address}/32" metric "$route_metric" 2>/dev/null || true
      if ip route show exact "${address}/32" | grep -q "blackhole"; then
        echo "$address" >> "$remaining_state"
      fi
    done < "$state_file"

    if [[ -s "$remaining_state" ]]; then
      mv "$remaining_state" "$state_file"
      echo "Some demo blackhole routes could not be removed; recovery state was retained:" >&2
      cat "$state_file" >&2
      exit 1
    fi

    rm -f "$remaining_state" "$state_file"
    echo "Demo outage restored; all recorded blackhole routes were removed."
    ;;

  status)
    if [[ -s "$state_file" ]]; then
      echo "ACTIVE"
      cat "$state_file"
    else
      echo "INACTIVE"
    fi
    ;;

  *)
    echo "Action must be block, restore, or status." >&2
    exit 2
    ;;
esac
