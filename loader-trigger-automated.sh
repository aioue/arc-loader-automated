#!/usr/bin/env bash
# Set grub next_entry=automated and reboot — Arc runs arc.sh on serial console (dialog OK).
#
# Runs on the Arc loader: ssh root@LOADER bash -s < loader-trigger-automated.sh
#
# Do not use set -u — Arc libs reference unset vars (e.g. HTTPPORT) and abort silently.
# Both automated marker files are required:
#   /mnt/p3/automated — Arc rebootTo convention
#   /mnt/p1/automated — grub [ -e /automated ] check at boot (without this, next_entry=automated is ignored)

set -e

ARC_PATH=/opt/arc
cd "${ARC_PATH}"
. "${ARC_PATH}/include/functions.sh"

readData

if [ -z "${MODEL}" ]; then
  echo "ERROR: model not set in user-config — run loader-seed-config.sh first" >&2
  exit 1
fi

if [ "$(readConfigKey "arc.offline" "${USER_CONFIG_FILE}")" = "true" ]; then
  echo "WARNING: arc.offline=true — PAT download will fail; fix seed first" >&2
fi

echo "arc-${MODEL}-${PRODUCTVER}-${ARC_VERSION}" >"${PART3_PATH}/automated"
touch "${PART1_PATH}/automated"
grub-editenv "${USER_GRUBENVFILE}" set next_entry=automated
grub-editenv "${USER_GRUBENVFILE}" list | grep -E 'next_entry|system_version'
sync
echo "Rebooting into automated_arc (model=${MODEL} platform=${PLATFORM} ${PRODUCTVER}-${BUILDNUM})..."
exec reboot
