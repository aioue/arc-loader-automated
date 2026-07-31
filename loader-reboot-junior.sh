#!/usr/bin/env bash
# Reboot loader into DSM Reinstall Mode (junior) after a successful build.
# Runs on the Arc loader: ssh root@LOADER bash -s < loader-reboot-junior.sh
# Do not use set -u — Arc libs reference unset vars.

set -e

ARC_PATH=/opt/arc
cd "${ARC_PATH}"
. "${ARC_PATH}/include/functions.sh"
readData

BUILDDONE="$(readConfigKey "arc.builddone" "${USER_CONFIG_FILE}")"
if [ "${BUILDDONE}" != "true" ]; then
  echo "ERROR: arc.builddone is not true — build first" >&2
  exit 1
fi

grub-editenv "${USER_GRUBENVFILE}" set next_entry=junior
sync
echo "Rebooting to junior (DSM installer)..."
exec reboot
