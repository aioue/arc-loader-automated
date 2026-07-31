#!/usr/bin/env bash
# README must link to aioue.net using Jekyll pretty permalinks (trailing slash, no .html).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
readme="${ROOT}/README.md"

[[ -f "${readme}" ]] || { echo "ERROR: README.md missing" >&2; exit 1; }

if ! grep -qE 'https://aioue\.net/[0-9]{4}/[0-9]{2}/[0-9]{2}/[^)[:space:]]+/' "${readme}"; then
  echo "ERROR: README must include an aioue.net blog link with pretty permalink (trailing slash)" >&2
  exit 1
fi

if grep -E 'https://aioue\.(net|github\.io)/[0-9]{4}/[0-9]{2}/[0-9]{2}/[^)[:space:]]+\.html' "${readme}"; then
  echo "ERROR: README uses .html blog URL; Jekyll permalink:pretty needs trailing slash" >&2
  exit 1
fi

echo "Blog link checks passed."
