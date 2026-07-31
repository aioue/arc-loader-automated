#!/usr/bin/env bash
# Wait for Arc loader SSH after VM boot. Prints IP to stdout.
#
# Usage:
#   LOADER_IP=$(./wait-for-loader-ip.sh)
#   LOADER_IP=$(./wait-for-loader-ip.sh --vmid 105)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"

TIMEOUT="${TIMEOUT:-180}"

usage() {
  echo "Usage: $(basename "$0") [--pve-host HOST] [--vmid ID] [--timeout SEC]" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pve-host) PVE_HOST="$2"; shift 2 ;;
    --vmid) ARC_VMID="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

arc_require_vmid "${ARC_VMID}"

deadline=$((SECONDS + TIMEOUT))
while (( SECONDS < deadline )); do
  ip="$(arc_pve_guest_ipv4 "${ARC_VMID}" 2>/dev/null || true)"
  if [[ -n "${ip}" ]]; then
    arc_require_ipv4 "${ip}"
    if arc_pve_loader_probe "${ip}"; then
      echo "${ip}"
      exit 0
    fi
  fi
  sleep 10
done

echo "ERROR: loader SSH not ready on VM ${ARC_VMID} within ${TIMEOUT}s" >&2
exit 1
