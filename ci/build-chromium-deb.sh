#!/usr/bin/env bash
# ci/build-chromium-deb.sh - build the `vacti-engine-chromium` .deb on the distro CI host (fetch-engine-debs.sh
# tier 3), with NO cross-repo auth and NO secret.
#
# WHY THIS EXISTS: the ~226MB (amd64) / ~285MB (arm64) chromium .deb is too big for the apt pool (Cloudflare
# 100MB cap -> engine upload 413s), so instead of fetching a prebuilt chromium .deb we BUILD it here from the
# public, SHA256-pinned upstream archives. Chromium is NOT methodology IP; building it downstream re-publishes
# nothing the engine .deb did not already carry.
#
# SINGLE SOURCE OF TRUTH: distro/packages/chromium-pin.json (vacti-owned; mirrored in the engine repo and
# guarded by ci/arsenal-sync-check.sh CHECK C). This used to extract playwright-core from the engine .deb and
# run its install cli; it is now a thin wrapper over distro/chromium/build-chromium-deb.sh, which downloads +
# SHA256-verifies the archives directly. Any host arch can build any target arch (nothing is executed).
#
# Usage: ci/build-chromium-deb.sh --arch <amd64|arm64> --out <dir> [--engine-deb <file>] [--pin <file>]
#   --engine-deb is accepted for call-site compatibility and ignored (the pin no longer comes from it).
# Produces: <out>/vacti-engine-chromium_<revision>_<arch>.deb (prints its path on the last line)
# Exit: 0 on success; non-zero on any failure (caller treats a failure as "fall back to another source").
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILDER="${SCRIPT_DIR}/../distro/chromium/build-chromium-deb.sh"

ARCH=""
OUT=""
PASS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --engine-deb) shift 2 ;;
    --arch)       ARCH="${2:-}"; shift 2 ;;
    --out)        OUT="${2:-}";  shift 2 ;;
    --pin)        PASS+=(--pin "${2:-}"); shift 2 ;;
    -h | --help)  sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "[build-chromium-deb][err] unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -n "$ARCH" ] || { echo "[build-chromium-deb][err] need --arch <amd64|arm64>" >&2; exit 2; }
[ -n "$OUT" ]  || { echo "[build-chromium-deb][err] need --out <dir>" >&2; exit 2; }
[ -f "$BUILDER" ] || { echo "[build-chromium-deb][err] builder missing: ${BUILDER}" >&2; exit 3; }

exec bash "$BUILDER" --arch "$ARCH" --out "$OUT" "${PASS[@]}"
