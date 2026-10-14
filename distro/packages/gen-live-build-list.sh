#!/usr/bin/env bash
# gen-live-build-list.sh - emit a package list (one package per line, comments/
# blank lines stripped) for a build flavour, with the ENGINE-ARSENAL half DERIVED
# from the shared engine manifest (packaging/arsenal-manifest.json) and the
# DISTRO-OWNED half read from distro-owned.list. This is the single bridge that
# makes every image (the golden/OVA virt-customize set and the ISO live-build
# chroot set) install the EXACT same packages the engine declares - no more
# hand-transcribed fork of the engine's apt arrays.
#
# Usage:
#   gen-live-build-list.sh [OUT]
#     OUT  path to write the generated list (default: stdout)
#
# Env:
#   VACTI_FULL_ARSENAL=1  emit the full apt core superset (.apt.core) instead of
#                         the lean default (core minus the per-vertical sets).
#   VACTI_CTF_ARSENAL=1   additionally include the apt-installable CTF tools
#                         (.apt.ctf). The non-apt CTF half (gems/pipx/GEF) is
#                         installed by golden-image/install-ctf-arsenal.sh.
#   VACTI_GEN_MODE        "main" (default): distro-owned + manifest arsenal for
#                         the flavour above. "ctf-apt": ONLY the manifest CTF apt
#                         set, no distro-owned base (for install-ctf-arsenal.sh).
#   VACTI_ARSENAL_MANIFEST  explicit path to the engine manifest. When unset the
#                         manifest is resolved in this order:
#                           1. the installed engine .deb path
#                              (/usr/lib/vacti-engine/packaging/arsenal-manifest.json)
#                           2. the vendored snapshot next to this script
#                         So an in-guest build reads the manifest straight from the
#                         installed .deb; a host-side / ISO / offline run uses the
#                         vendored snapshot (kept in sync by ci/arsenal-sync-check.sh).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-/dev/stdout}"
FULL="${VACTI_FULL_ARSENAL:-0}"
CTF="${VACTI_CTF_ARSENAL:-0}"
MODE="${VACTI_GEN_MODE:-main}"

# shellcheck source=manifest-lib.sh
. "${HERE}/manifest-lib.sh"

# resolve the manifest: explicit override, else the installed .deb, else vendored.
INSTALLED_MANIFEST="/usr/lib/vacti-engine/packaging/arsenal-manifest.json"
VENDORED_MANIFEST="${HERE}/arsenal-manifest.json"
MANIFEST="${VACTI_ARSENAL_MANIFEST:-}"
if [[ -z "$MANIFEST" ]]; then
  if [[ -f "$INSTALLED_MANIFEST" ]]; then
    MANIFEST="$INSTALLED_MANIFEST"
  else
    MANIFEST="$VENDORED_MANIFEST"
  fi
fi
[[ -f "$MANIFEST" ]] || { echo "[gen] no arsenal manifest found (tried '$MANIFEST')" >&2; exit 1; }

# strip comments + blank lines from a .list file
strip() { sed -e 's/#.*$//' -e 's/[[:space:]]\+$//' "$1" | grep -vE '^[[:space:]]*$' || true; }

flavour() { if [[ "$FULL" =~ ^(1|true|yes|on)$ ]]; then echo full; else echo lean; fi; }
ctf_on()  { [[ "$CTF" =~ ^(1|true|yes|on)$ ]]; }

{
  if [[ "$MODE" == "ctf-apt" ]]; then
    # ONLY the manifest CTF apt set (install-ctf-arsenal.sh's apt half).
    manifest_pkgs "$MANIFEST" ctf
  else
    # distro-owned base + the manifest arsenal for this flavour (+ ctf if asked).
    [[ -f "${HERE}/distro-owned.list" ]] && strip "${HERE}/distro-owned.list"
    manifest_pkgs "$MANIFEST" "$(flavour)"
    if ctf_on; then manifest_pkgs "$MANIFEST" ctf; fi
  fi
} | sort -u > "$OUT"

echo "[+] wrote $(grep -c . "$OUT" 2>/dev/null || echo '?') packages to ${OUT} (mode=${MODE} full=${FULL} ctf=${CTF} manifest=${MANIFEST})" >&2
