#!/usr/bin/env bash
# Destroy (optional), create, and run headless Arc build end-to-end.
#
# Usage:
#   ./run-from-scratch.sh --yes
#   ./run-from-scratch.sh --vmid 105 --name my-arc-test --yes
#   ./run-from-scratch.sh --skip-destroy --skip-create   # existing running loader
#
# Destroy requires --yes and passes safety checks (see destroy-test-vm.sh).
# Pick a VMID/name that do not collide with existing guests on your Proxmox host.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"

REBOOT_JUNIOR=false
SKIP_DESTROY=false
SKIP_CREATE=false
CONFIRM_DESTROY=false
CREATE_START=true
extra_vm=()
extra_seed=()

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Full headless Arc install on Proxmox: optional destroy, create VM, seed, build, wait for DSM :5000.

Options:
  --pve-host HOST       Proxmox SSH host (default: ${PVE_HOST})
  --vmid ID             VM ID (default: ${ARC_VMID})
  --name NAME           VM name (default: ${ARC_VM_NAME})
  --arc-img PATH        arc.img path on Proxmox (default: ${ARC_IMG})
  --memory MB           RAM (default: ${ARC_MEMORY})
  --cores N             vCPUs (default: ${ARC_CORES})
  --data-disk-gb GB     Data disk (default: ${ARC_DATA_DISK_GB})
  --bridge BR           Network bridge (default: ${ARC_BRIDGE})
  --storage POOL        Proxmox storage pool (default: ${ARC_STORAGE})
  --model MODEL         DSM model to seed (default: ${ARC_MODEL})
  --platform PLATFORM   CPU platform (default: ${ARC_PLATFORM})
  --productver VER      DSM major (default: ${ARC_PRODUCTVER})
  --buildnum NUM        DSM build (default: ${ARC_BUILDNUM})
  --pat-url URL         PAT download URL
  --pat-hash HASH       PAT sha1 hash
  --yes                 Allow destroy step (required unless --skip-destroy)
  --skip-destroy        Do not destroy existing VM
  --skip-create         Do not create VM (use with --start on existing loader)
  --no-start            Do not pass --start to create (VM must already be running)
  --reboot-junior       Reboot to junior after build (DSM installer path)
  -h, --help            Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pve-host) PVE_HOST="$2"; extra_vm+=(--pve-host "$2"); shift 2 ;;
    --vmid) ARC_VMID="$2"; extra_vm+=(--vmid "$2"); shift 2 ;;
    --name) ARC_VM_NAME="$2"; extra_vm+=(--name "$2"); shift 2 ;;
    --arc-img) ARC_IMG="$2"; extra_vm+=(--arc-img "$2"); shift 2 ;;
    --memory) ARC_MEMORY="$2"; extra_vm+=(--memory "$2"); shift 2 ;;
    --cores) ARC_CORES="$2"; extra_vm+=(--cores "$2"); shift 2 ;;
    --data-disk-gb) ARC_DATA_DISK_GB="$2"; extra_vm+=(--data-disk-gb "$2"); shift 2 ;;
    --bridge) ARC_BRIDGE="$2"; extra_vm+=(--bridge "$2"); shift 2 ;;
    --storage) ARC_STORAGE="$2"; extra_vm+=(--storage "$2"); shift 2 ;;
    --model) ARC_MODEL="$2"; extra_seed+=(--model "$2"); shift 2 ;;
    --platform) ARC_PLATFORM="$2"; extra_seed+=(--platform "$2"); shift 2 ;;
    --productver) ARC_PRODUCTVER="$2"; extra_seed+=(--productver "$2"); shift 2 ;;
    --buildnum) ARC_BUILDNUM="$2"; extra_seed+=(--buildnum "$2"); shift 2 ;;
    --pat-url) ARC_PAT_URL="$2"; extra_seed+=(--pat-url "$2"); shift 2 ;;
    --pat-hash) ARC_PAT_HASH="$2"; extra_seed+=(--pat-hash "$2"); shift 2 ;;
    --yes) CONFIRM_DESTROY=true; shift ;;
    --skip-destroy) SKIP_DESTROY=true; shift ;;
    --skip-create) SKIP_CREATE=true; shift ;;
    --no-start) CREATE_START=false; shift ;;
    --reboot-junior) REBOOT_JUNIOR=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

export PVE_HOST ARC_VMID ARC_VM_NAME ARC_IMG ARC_STORAGE ARC_MEMORY ARC_CORES ARC_DATA_DISK_GB ARC_BRIDGE
export ARC_MODEL ARC_PLATFORM ARC_PRODUCTVER ARC_BUILDNUM ARC_PAT_URL ARC_PAT_HASH

if [[ "${SKIP_DESTROY}" != "true" ]]; then
  if [[ "${CONFIRM_DESTROY}" != "true" ]]; then
    echo "Refusing to run destroy step without --yes (or pass --skip-destroy)" >&2
    exit 1
  fi
  echo "=== Destroy VM ${ARC_VMID} (${ARC_VM_NAME}) ==="
  "${SCRIPT_DIR}/destroy-test-vm.sh" "${extra_vm[@]}" --yes
else
  echo "=== Skipping destroy ==="
fi

if [[ "${SKIP_CREATE}" != "true" ]]; then
  echo "=== Create VM ${ARC_VMID} (${ARC_VM_NAME}) ==="
  create_args=("${extra_vm[@]}")
  [[ "${CREATE_START}" == "true" ]] && create_args+=(--start)
  "${SCRIPT_DIR}/create-test-vm.sh" "${create_args[@]}"
else
  echo "=== Skipping create ==="
fi

echo "=== Wait for loader IP ==="
LOADER_IP="$("${SCRIPT_DIR}/wait-for-loader-ip.sh" "${extra_vm[@]}")"
echo "Loader IP: ${LOADER_IP}"

build_extra=()
[[ "${REBOOT_JUNIOR}" == "true" ]] && build_extra+=(--reboot-junior)

echo "=== Headless configure + build ==="
"${SCRIPT_DIR}/configure-and-build.sh" "${LOADER_IP}" \
  --pve-host "${PVE_HOST}" \
  "${extra_seed[@]}" \
  "${build_extra[@]}"
