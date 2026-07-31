#!/usr/bin/env bash
# Seed user-config.yml before automated_arc boot.
#
# Runs on the Arc loader: ssh root@LOADER bash -s < loader-seed-config.sh
# Override model/PAT via env (see lib.sh defaults).
#
# Uses yq only — never source Arc libs here (partial edits corrupt user-config.yml).

set -euo pipefail

USER_CONFIG=/mnt/p1/user-config.yml

ARC_MODEL="${ARC_MODEL:-DS923+}"
ARC_PLATFORM="${ARC_PLATFORM:-r1000}"
ARC_PRODUCTVER="${ARC_PRODUCTVER:-7.2}"
ARC_BUILDNUM="${ARC_BUILDNUM:-72806}"
ARC_SMALLNUM="${ARC_SMALLNUM:-0}"
ARC_PAT_URL="${ARC_PAT_URL:-https://global.download.synology.com/download/DSM/release/7.2.2/72806/DSM_DS923%2B_72806.pat}"
ARC_PAT_HASH="${ARC_PAT_HASH:-1ab30d0ab9d9d5e53942e101c1011513}"
ARC_PATCH="${ARC_PATCH:-true}"

[[ -f "${USER_CONFIG}" ]] || {
  echo "ERROR: ${USER_CONFIG} missing" >&2
  exit 1
}

rm -f /mnt/p2/zImage /mnt/p2/rd.gz /mnt/p3/zImage-dsm /mnt/p3/initrd-dsm 2>/dev/null || true
yq eval 'del(.synoinfo) | del(.sn) | del(.network) | del(.modules) | del(.["ramdisk-hash"]) | del(.["zimage-hash"])' \
  -i "${USER_CONFIG}"

export ARC_MODEL ARC_PLATFORM ARC_PRODUCTVER ARC_BUILDNUM ARC_SMALLNUM ARC_PAT_URL ARC_PAT_HASH ARC_PATCH
yq eval -i '
  .model = strenv(ARC_MODEL) |
  .platform = strenv(ARC_PLATFORM) |
  .productver = strenv(ARC_PRODUCTVER) |
  .buildnum = strenv(ARC_BUILDNUM) |
  .smallnum = strenv(ARC_SMALLNUM) |
  .paturl = strenv(ARC_PAT_URL) |
  .pathash = strenv(ARC_PAT_HASH) |
  .kernel = "official" |
  .governor = "performance" |
  .arc.patch = strenv(ARC_PATCH) |
  .arc.offline = "false" |
  .arc.confdone = "false" |
  .arc.builddone = "false" |
  .addons = {} |
  .layout = "qwerty"
' "${USER_CONFIG}"

echo "=== seeded user-config ==="
yq eval '.model, .platform, .productver, .buildnum, .paturl, .pathash, .arc.offline, .arc.confdone, .arc.builddone' "${USER_CONFIG}"
