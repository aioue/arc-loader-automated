#!/usr/bin/env bash
# Shared defaults and helpers for Proxmox + Arc headless install scripts.
# Source from other scripts: . "$(dirname "$0")/lib.sh"

# Proxmox / VM — override via env or CLI flags on each script.
PVE_HOST="${PVE_HOST:-192.168.1.10}"
ARC_VMID="${ARC_VMID:-104}"
ARC_VM_NAME="${ARC_VM_NAME:-xpenology-arc-test}"
ARC_IMG="${ARC_IMG:-/var/lib/vz/template/iso/arc.img}"
ARC_STORAGE="${ARC_STORAGE:-local-zfs}"
ARC_MEMORY="${ARC_MEMORY:-4096}"
ARC_CORES="${ARC_CORES:-2}"
ARC_DATA_DISK_GB="${ARC_DATA_DISK_GB:-40}"
ARC_BRIDGE="${ARC_BRIDGE:-vmbr0}"
ARC_LOADER_PASS="${ARC_LOADER_PASS:-arc}"
# Comma-separated VMIDs that must never be destroyed (set via env, e.g. PROTECTED_VMIDS=103).
PROTECTED_VMIDS="${PROTECTED_VMIDS:-}"

# Loader seed — override for models other than DS923+ / r1000.
ARC_MODEL="${ARC_MODEL:-DS923+}"
ARC_PLATFORM="${ARC_PLATFORM:-r1000}"
ARC_PRODUCTVER="${ARC_PRODUCTVER:-7.2}"
ARC_BUILDNUM="${ARC_BUILDNUM:-72806}"
ARC_SMALLNUM="${ARC_SMALLNUM:-0}"
ARC_PAT_URL="${ARC_PAT_URL:-https://global.download.synology.com/download/DSM/release/7.2.2/72806/DSM_DS923%2B_72806.pat}"
ARC_PAT_HASH="${ARC_PAT_HASH:-1ab30d0ab9d9d5e53942e101c1011513}"
ARC_PATCH="${ARC_PATCH:-true}"

arc_require_vmid() {
  [[ "${1}" =~ ^[0-9]+$ ]] || {
    echo "Invalid VMID (digits only): ${1}" >&2
    exit 1
  }
}

arc_require_ipv4() {
  local ip="$1"
  [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || {
    echo "Invalid IPv4 address: ${ip}" >&2
    exit 1
  }
  local o
  IFS=. read -r o _ _ _ <<< "${ip}"
  [[ "${o}" -ge 1 && "${o}" -le 223 && "${ip}" != *.*.*.0 && "${ip}" != *.*.*.255 ]] || {
    echo "Invalid IPv4 address: ${ip}" >&2
    exit 1
  }
}

arc_vm_id_protected() {
  local vmid="$1"
  local id
  IFS=',' read -ra ids <<< "${PROTECTED_VMIDS}"
  for id in "${ids[@]}"; do
    [[ "${vmid}" == "${id// /}" ]] && return 0
  done
  return 1
}

# Remote bash snippet: verify VM looks like our Arc loader (create reuse + destroy).
# Args: VMID EXPECTED_NAME [LOADER_PASS]
# Prints: absent | ok
ARC_VERIFY_VM_SNIPPET='
verify_arc_loader_vm() {
  local vmid="$1"
  local expected_name="$2"
  local loader_pass="${3:-arc}"
  if ! qm status "${vmid}" &>/dev/null; then
    echo "absent"
    return 0
  fi
  local name bios
  name=$(qm config "${vmid}" | awk -F": " "/^name:/{print \$2; exit}")
  bios=$(qm config "${vmid}" | awk -F": " "/^bios:/{print \$2; exit}")
  if [[ "${name}" != "${expected_name}" ]]; then
    echo "Refusing: VM ${vmid} name is \"${name}\", expected \"${expected_name}\"" >&2
    return 1
  fi
  if [[ "${bios}" != "ovmf" ]]; then
    echo "Refusing: VM ${vmid} bios is \"${bios}\", expected ovmf (Arc loader uses UEFI)" >&2
    return 1
  fi
  if ! qm config "${vmid}" | grep -q "^sata0:"; then
    echo "Refusing: VM ${vmid} has no sata0 disk (not an Arc loader layout)" >&2
    return 1
  fi
  if ! qm config "${vmid}" | grep -q "^sata1:"; then
    echo "Refusing: VM ${vmid} has no sata1 data disk (not an Arc loader layout)" >&2
    return 1
  fi
  if ! qm config "${vmid}" | grep -q "^boot:.*sata0"; then
    echo "Refusing: VM ${vmid} does not boot from sata0" >&2
    return 1
  fi
  if ! qm config "${vmid}" | grep -q "^agent:.*enabled=1"; then
    echo "Refusing: VM ${vmid} does not have guest agent enabled=1" >&2
    return 1
  fi
  if qm status "${vmid}" | grep -q running; then
    local ip
    ip=$(qm guest cmd "${vmid}" network-get-interfaces 2>/dev/null | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for iface in data:
    if iface.get(\"name\") in (\"lo\", \"Loopback\"):
        continue
    for addr in iface.get(\"ip-addresses\", []):
        ip = addr.get(\"ip-address\", \"\")
        if addr.get(\"ip-address-type\") == \"ipv4\" and not ip.startswith(\"127.\"):
            print(ip)
            sys.exit(0)
sys.exit(1)
" 2>/dev/null || true)
    if [[ -n "${ip}" ]] && command -v sshpass >/dev/null 2>&1; then
      if ! sshpass -p "${loader_pass}" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
        "root@${ip}" test -d /opt/arc 2>/dev/null; then
        echo "Refusing: VM ${vmid} at ${ip} has no /opt/arc (not an Arc loader)" >&2
        return 1
      fi
    fi
  fi
  echo "ok"
  return 0
}
'

loader_seed_env_exports() {
  printf 'ARC_MODEL=%q ARC_PLATFORM=%q ARC_PRODUCTVER=%q ARC_BUILDNUM=%q ARC_SMALLNUM=%q ARC_PAT_URL=%q ARC_PAT_HASH=%q ARC_PATCH=%q\n' \
    "${ARC_MODEL}" "${ARC_PLATFORM}" "${ARC_PRODUCTVER}" "${ARC_BUILDNUM}" "${ARC_SMALLNUM}" \
    "${ARC_PAT_URL}" "${ARC_PAT_HASH}" "${ARC_PATCH}"
}

# SSH from local → Proxmox → Arc loader. Args after loader_ip are passed to loader bash -lc.
arc_pve_loader_ssh() {
  local loader_ip="$1"
  shift
  arc_require_ipv4 "${loader_ip}"
  local pass_q ip_q remote_cmd
  pass_q=$(printf '%q' "${ARC_LOADER_PASS}")
  ip_q=$(printf '%q' "${loader_ip}")
  remote_cmd=$(printf '%q ' "$@")
  ssh -o ControlMaster=no -o ConnectTimeout=10 "root@${PVE_HOST}" \
    "sshpass -p ${pass_q} ssh -T -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@${ip_q} bash -c ${remote_cmd}"
}

# Run a local script on the loader via stdin (seed/trigger). Optional env prefix from loader_seed_env_exports.
arc_pve_loader_run_script() {
  local loader_ip="$1"
  local script_path="$2"
  local env_prefix="${3:-}"
  arc_require_ipv4 "${loader_ip}"
  local pass_q ip_q
  pass_q=$(printf '%q' "${ARC_LOADER_PASS}")
  ip_q=$(printf '%q' "${loader_ip}")
  ssh -o ControlMaster=no -o ConnectTimeout=30 "root@${PVE_HOST}" \
    "sshpass -p ${pass_q} ssh -T -o StrictHostKeyChecking=no -o ConnectTimeout=30 root@${ip_q} ${env_prefix} bash -s" \
    < "${script_path}"
}

# Guest-agent network query on Proxmox — VMID passed as argv, not interpolated in shell.
arc_pve_guest_ipv4() {
  local vmid="$1"
  arc_require_vmid "${vmid}"
  ssh -o ControlMaster=no -o ConnectTimeout=10 "root@${PVE_HOST}" bash -s -- "${vmid}" <<'REMOTE'
set -euo pipefail
vmid="$1"
[[ "${vmid}" =~ ^[0-9]+$ ]] || exit 1
qm guest cmd "${vmid}" network-get-interfaces 2>/dev/null | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for iface in data:
    if iface.get('name') in ('lo', 'Loopback'):
        continue
    for addr in iface.get('ip-addresses', []):
        ip = addr.get('ip-address', '')
        if addr.get('ip-address-type') == 'ipv4' and not ip.startswith('127.'):
            print(ip)
            sys.exit(0)
sys.exit(1)
"
REMOTE
}

# Test loader SSH from Proxmox hop.
arc_pve_loader_probe() {
  local loader_ip="$1"
  arc_require_ipv4 "${loader_ip}"
  local pass_q ip_q
  pass_q=$(printf '%q' "${ARC_LOADER_PASS}")
  ip_q=$(printf '%q' "${loader_ip}")
  ssh -o ControlMaster=no -o ConnectTimeout=10 "root@${PVE_HOST}" \
    "sshpass -p ${pass_q} ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@${ip_q} true" \
    2>/dev/null
}
