#!/usr/bin/env bash
# Destroy an Arc loader VM on Proxmox — only if it matches name/layout checks.
#
# Refuses protected VMIDs (default: 103). Refuses VM 104 (or any --vmid) if the
# guest is not named as expected, does not use OVMF, or is not an sata0-boot Arc layout.
# Requires --yes to actually destroy.
#
# Usage:
#   ./destroy-test-vm.sh --yes
#   ./destroy-test-vm.sh --vmid 105 --name my-arc-test --yes
#   PVE_HOST=192.168.1.10 PROTECTED_VMIDS=103,101 ./destroy-test-vm.sh --yes

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"

CONFIRM=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] --yes

Destroy an Arc loader VM after safety checks. Does nothing without --yes.

Options:
  --pve-host HOST     Proxmox SSH host (default: ${PVE_HOST})
  --vmid ID           VM ID (default: ${ARC_VMID})
  --name NAME         Expected VM name (default: ${ARC_VM_NAME})
  --yes               Confirm destroy (required)
  -h, --help          Show this help

Environment:
  PROTECTED_VMIDS     Comma-separated VMIDs that can never be destroyed (default: ${PROTECTED_VMIDS})
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pve-host) PVE_HOST="$2"; shift 2 ;;
    --vmid) ARC_VMID="$2"; shift 2 ;;
    --name) ARC_VM_NAME="$2"; shift 2 ;;
    --yes) CONFIRM=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

arc_require_vmid "${ARC_VMID}"

if arc_vm_id_protected "${ARC_VMID}"; then
  echo "Refusing to destroy protected VM ${ARC_VMID} (PROTECTED_VMIDS=${PROTECTED_VMIDS})" >&2
  exit 1
fi

if [[ "${CONFIRM}" != "true" ]]; then
  echo "Refusing to destroy VM ${ARC_VMID} without --yes" >&2
  echo "Will only destroy if name=${ARC_VM_NAME}, bios=ovmf, boots from sata0." >&2
  exit 1
fi

ssh -o ControlMaster=no "root@${PVE_HOST}" bash -s -- "${ARC_VMID}" "${ARC_VM_NAME}" "${ARC_LOADER_PASS}" <<REMOTE
set -euo pipefail
VMID="\$1"
EXPECTED_NAME="\$2"
LOADER_PASS="\$3"
${ARC_VERIFY_VM_SNIPPET}
status=\$(verify_arc_loader_vm "\${VMID}" "\${EXPECTED_NAME}" "\${LOADER_PASS}") || exit 1
if [[ "\${status}" == "absent" ]]; then
  echo "VM \${VMID} does not exist"
  exit 0
fi
qm status "\${VMID}" | grep -q running && qm stop "\${VMID}" && sleep 3
qm destroy "\${VMID}" --purge 0
echo "Destroyed VM \${VMID} (\${EXPECTED_NAME})"
REMOTE
