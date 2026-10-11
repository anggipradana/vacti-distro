#!/usr/bin/env bash
# gen-live-build-list.sh - emit a live-build package list (one package per line,
# comments/blank lines stripped) from the shared arsenal manifest. This is the
# bridge that makes the ISO's live-build chroot install the EXACT same package
# set the golden image's virt-customize installs: one source of truth.
#
# Usage:
#   gen-live-build-list.sh [OUT]
#     OUT  path to write the generated list (default: stdout)
#   VACTI_FULL_ARSENAL=1  include the per-vertical sets (full.list) on top of
#                         the web-lean CORE; otherwise just web-lean.list.
#   VACTI_CTF_ARSENAL=1   additionally include the apt-installable CTF tools
#                         (ctf.list). The non-apt CTF half (gems/pipx/GEF) is
#                         installed by golden-image/install-ctf-arsenal.sh at
#                         golden-build time, not via this list.
#
# It is normally invoked by the live-build driver to produce
#   config/package-lists/vacti-core.list.chroot
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-/dev/stdout}"
FULL="${VACTI_FULL_ARSENAL:-0}"
CTF="${VACTI_CTF_ARSENAL:-0}"

# strip comments + blank lines from a .list file
strip() { sed -e 's/#.*$//' -e 's/[[:space:]]\+$//' "$1" | grep -vE '^[[:space:]]*$'; }

{
  strip "${HERE}/web-lean.list"
  if [[ "$FULL" =~ ^(1|true|yes|on)$ ]]; then
    strip "${HERE}/full.list"
  fi
  if [[ "$CTF" =~ ^(1|true|yes|on)$ ]]; then
    strip "${HERE}/ctf.list"
  fi
} | sort -u > "$OUT"

echo "[+] wrote $(grep -c . "$OUT" 2>/dev/null || echo '?') packages to ${OUT} (full=${FULL} ctf=${CTF})" >&2
