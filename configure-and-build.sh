#!/usr/bin/env bash
# Headless Arc loader configure + build.
#
# Strategy: seed user-config.yml over SSH, reboot into Arc Automated Mode
# (automated_arc kernel param). arc.sh runs on the loader console where dialog
# works — no Config Mode browser (:7080) required.
#
# Usage:
#   ./configure-and-build.sh LOADER_IP
#   ./configure-and-build.sh LOADER_IP --model DS920+ --platform geminilake
#   ./configure-and-build.sh LOADER_IP --seed-only
#
# Prerequisites:
#   - Arc loader running (root/arc), online for PAT download
#   - sshpass on Proxmox host
#
# DSM first-boot wizard remains manual after build boots DSM.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"

SEED_SCRIPT="${SCRIPT_DIR}/loader-seed-config.sh"
TRIGGER_SCRIPT="${SCRIPT_DIR}/loader-trigger-automated.sh"
JUNIOR_SCRIPT="${SCRIPT_DIR}/loader-reboot-junior.sh"

LOADER_IP="${1:-}"
REBOOT_JUNIOR=false
SEED_ONLY=false
WAIT_ONLY=false
WAIT_TIMEOUT="${WAIT_TIMEOUT:-1200}"
POLL_INTERVAL="${POLL_INTERVAL:-20}"

shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pve-host) PVE_HOST="$2"; shift 2 ;;
    --model) ARC_MODEL="$2"; shift 2 ;;
    --platform) ARC_PLATFORM="$2"; shift 2 ;;
    --productver) ARC_PRODUCTVER="$2"; shift 2 ;;
    --buildnum) ARC_BUILDNUM="$2"; shift 2 ;;
    --pat-url) ARC_PAT_URL="$2"; shift 2 ;;
    --pat-hash) ARC_PAT_HASH="$2"; shift 2 ;;
    --reboot-junior) REBOOT_JUNIOR=true; shift ;;
    --seed-only) SEED_ONLY=true; shift ;;
    --wait-only) WAIT_ONLY=true; shift ;;
    -h|--help)
      echo "Usage: $(basename "$0") LOADER_IP [options]" >&2
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "${LOADER_IP}" ]] || {
  echo "Usage: $(basename "$0") LOADER_IP [--pve-host HOST] [--model M] [--platform P] ..." >&2
  exit 2
}

arc_require_ipv4 "${LOADER_IP}"

clear_pve_known_host() {
  ssh -o ControlMaster=no "root@${PVE_HOST}" \
    "ssh-keygen -f /root/.ssh/known_hosts -R ${LOADER_IP} 2>/dev/null || true" \
    >/dev/null 2>&1 || true
}

run_on_loader() {
  local script_path="$1"
  clear_pve_known_host
  arc_pve_loader_run_script "${LOADER_IP}" "${script_path}" "$(loader_seed_env_exports)"
}

loader_ssh() {
  local cmd="$1"
  clear_pve_known_host
  arc_pve_loader_ssh "${LOADER_IP}" "${cmd}" 2>/dev/null
}

get_build_status() {
  loader_ssh "yq eval '.arc.confdone + \" \" + .arc.builddone' /mnt/p1/user-config.yml" || echo "unreachable"
}

get_loader_detail() {
  loader_ssh "yq eval '.arc.offline,.arc.confdone,.arc.builddone' /mnt/p1/user-config.yml; cat /proc/cmdline" || echo "unreachable"
}

dsm_assistant_up() {
  curl -sf --connect-timeout 5 "http://${LOADER_IP}:5000/" >/dev/null 2>&1
}

LOG="/tmp/arc-headless-build-$(date +%Y%m%d-%H%M%S).log"
echo "Logging to ${LOG}"
echo "Model: ${ARC_MODEL} platform=${ARC_PLATFORM} DSM ${ARC_PRODUCTVER}-${ARC_BUILDNUM}" | tee -a "${LOG}"

if [[ "${WAIT_ONLY}" != "true" ]]; then
  echo "=== Seeding user-config ==="
  run_on_loader "${SEED_SCRIPT}" 2>&1 | tee -a "${LOG}"

  if [[ "${SEED_ONLY}" == "true" ]]; then
    echo "Seed complete (--seed-only)."
    exit 0
  fi

  echo "=== Triggering automated_arc reboot ==="
  set +o pipefail
  run_on_loader "${TRIGGER_SCRIPT}" 2>&1 | tee -a "${LOG}"
  trigger_rc=${PIPESTATUS[0]}
  set -o pipefail
  if (( trigger_rc != 0 )) && ! grep -q "Rebooting into automated_arc" "${LOG}"; then
    echo "ERROR: automated reboot trigger failed — see log above" >&2 | tee -a "${LOG}"
    exit 1
  fi
  echo "Loader rebooting — waiting for automated build..."
  sleep 45
fi

echo "=== Waiting for build (timeout ${WAIT_TIMEOUT}s) ==="
deadline=$((SECONDS + WAIT_TIMEOUT))
stall_config=0
stall_build=0
while (( SECONDS < deadline )); do
  status="$(get_build_status)"
  echo "$(date +%H:%M:%S) status=${status}"

  if [[ "${status}" == "true true" ]]; then
    echo "=== Build OK (arc.builddone=true) ===" | tee -a "${LOG}"
    if [[ "${REBOOT_JUNIOR}" == "true" ]]; then
      echo "=== Rebooting to junior (DSM installer) ==="
      set +o pipefail
      run_on_loader "${JUNIOR_SCRIPT}" 2>&1 | tee -a "${LOG}" || true
      set -o pipefail
      sleep 30
    fi
    if dsm_assistant_up; then
      echo "DSM Web Assistant: http://${LOADER_IP}:5000" | tee -a "${LOG}"
    fi
    echo "Done. Full log: ${LOG}"
    exit 0
  fi

  if [[ "${status}" == "unreachable" ]] && dsm_assistant_up; then
    echo "=== Build OK (DSM assistant on :5000, loader SSH closed) ===" | tee -a "${LOG}"
    echo "DSM Web Assistant: http://${LOADER_IP}:5000" | tee -a "${LOG}"
    echo "Done. Full log: ${LOG}"
    exit 0
  fi

  if [[ "${status}" == "false false" ]]; then
    stall_config=$((stall_config + 1))
    if (( stall_config >= 6 )); then
      cmdline="$(loader_ssh 'cat /proc/cmdline' || echo unreachable)"
      if [[ "${cmdline}" == *force_arc* ]]; then
        echo "ERROR: still in Config Mode (force_arc) — grub automated entry did not run" >&2 | tee -a "${LOG}"
        echo "Check /mnt/p1/automated exists before reboot; re-run seed + trigger." >&2 | tee -a "${LOG}"
        exit 1
      fi
      if [[ "${cmdline}" == *automated_arc* ]]; then
        echo "Automated mode running (confdone pending) — continuing..." | tee -a "${LOG}"
        stall_config=0
      fi
    fi
  else
    stall_config=0
  fi

  if [[ "${status}" == "true false" ]]; then
    stall_build=$((stall_build + 1))
    if (( stall_build >= 9 )); then
      detail="$(get_loader_detail)"
      echo "ERROR: config done but build stuck (status=true false)" >&2 | tee -a "${LOG}"
      echo "${detail}" | tee -a "${LOG}"
      if echo "${detail}" | head -1 | grep -q '^true'; then
        echo "Hint: arc.offline=true blocks PAT download — seed must set arc.offline=false" >&2 | tee -a "${LOG}"
      fi
      exit 1
    fi
  else
    stall_build=0
  fi

  sleep "${POLL_INTERVAL}"
done

echo "ERROR: timed out (last status=${status})" >&2 | tee -a "${LOG}"
if dsm_assistant_up; then
  echo "DSM may be up anyway: http://${LOADER_IP}:5000" | tee -a "${LOG}"
fi
exit 1
