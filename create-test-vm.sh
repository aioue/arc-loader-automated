#!/usr/bin/env bash
# Create (or start) an Arc loader VM on Proxmox.
#
# Idempotent: if the VMID already exists, verifies Arc layout before start.
# Does not modify an existing VM's disks or settings.
#
# Usage:
#   ./create-test-vm.sh --start
#   ./create-test-vm.sh --vmid 105 --name my-arc --storage local-lvm --start

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"

START=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] [--start]

Create an Arc loader VM (OVMF, sata0=loader, sata1=data) or start if it exists.

Options:
  --pve-host HOST       Proxmox SSH host (default: ${PVE_HOST})
  --vmid ID             VM ID (default: ${ARC_VMID})
  --name NAME           VM name (default: ${ARC_VM_NAME})
  --arc-img PATH        arc.img on Proxmox (default: ${ARC_IMG})
  --storage POOL        Proxmox storage for disks (default: ${ARC_STORAGE})
  --memory MB           RAM in MiB (default: ${ARC_MEMORY})
  --cores N             vCPU count (default: ${ARC_CORES})
  --data-disk-gb GB     Data disk size (default: ${ARC_DATA_DISK_GB})
  --bridge BR           Network bridge (default: ${ARC_BRIDGE})
  --start               Start VM after create (or if already exists)
  -h, --help            Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pve-host) PVE_HOST="$2"; shift 2 ;;
    --vmid) ARC_VMID="$2"; shift 2 ;;
    --name) ARC_VM_NAME="$2"; shift 2 ;;
    --arc-img) ARC_IMG="$2"; shift 2 ;;
    --storage) ARC_STORAGE="$2"; shift 2 ;;
    --memory) ARC_MEMORY="$2"; shift 2 ;;
    --cores) ARC_CORES="$2"; shift 2 ;;
    --data-disk-gb) ARC_DATA_DISK_GB="$2"; shift 2 ;;
    --bridge) ARC_BRIDGE="$2"; shift 2 ;;
    --start) START=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

arc_require_vmid "${ARC_VMID}"

if arc_vm_id_protected "${ARC_VMID}"; then
  echo "Refusing to create over protected VM ${ARC_VMID}" >&2
  exit 1
fi

ssh -o ControlMaster=no "root@${PVE_HOST}" bash -s -- \
  "${ARC_VMID}" "${ARC_VM_NAME}" "${ARC_IMG}" "${START}" \
  "${ARC_MEMORY}" "${ARC_CORES}" "${ARC_DATA_DISK_GB}" "${ARC_BRIDGE}" \
  "${ARC_STORAGE}" "${ARC_LOADER_PASS}" <<REMOTE
set -euo pipefail
VMID="\$1"
VM_NAME="\$2"
ARC_IMG="\$3"
START="\$4"
MEMORY="\$5"
CORES="\$6"
DATA_DISK_GB="\$7"
BRIDGE="\$8"
STORAGE="\$9"
LOADER_PASS="\${10}"
${ARC_VERIFY_VM_SNIPPET}
if qm status "\${VMID}" &>/dev/null; then
  echo "VM \${VMID} already exists — verifying Arc loader layout"
  verify_arc_loader_vm "\${VMID}" "\${VM_NAME}" "\${LOADER_PASS}" || exit 1
  qm config "\${VMID}" | grep -E '^(name|sata|efi|onboot|memory|cores):'
  if [[ "\${START}" == "true" && "\$(qm status "\${VMID}" | awk '{print \$2}')" != "running" ]]; then
    qm start "\${VMID}"
    echo "Started existing VM \${VMID}"
  fi
  exit 0
fi

test -f "\${ARC_IMG}" || { echo "Arc image not found: \${ARC_IMG}" >&2; exit 1; }

qm create "\${VMID}" --name "\${VM_NAME}" --memory "\${MEMORY}" --cores "\${CORES}" --cpu host \
  --machine q35 --bios ovmf --net0 "virtio,bridge=\${BRIDGE}" --onboot 0 --agent enabled=1
qm set "\${VMID}" --efidisk0 "\${STORAGE}:1,efitype=4m,pre-enrolled-keys=0"
qm importdisk "\${VMID}" "\${ARC_IMG}" "\${STORAGE}" --format raw
qm set "\${VMID}" --sata0 "\${STORAGE}:vm-\${VMID}-disk-1,ssd=1"
qm set "\${VMID}" --sata1 "\${STORAGE}:\${DATA_DISK_GB},ssd=1,discard=on,backup=0"
qm set "\${VMID}" --boot order=sata0
qm set "\${VMID}" --delete unused0 2>/dev/null || true

echo "Created VM \${VMID} (\${VM_NAME}) on storage \${STORAGE}"
qm config "\${VMID}" | grep -E '^(name|sata|efi|onboot|memory|cores):'

if [[ "\${START}" == "true" ]]; then
  qm start "\${VMID}"
  echo "Started VM \${VMID} — wait ~30s for loader SSH"
fi
REMOTE
