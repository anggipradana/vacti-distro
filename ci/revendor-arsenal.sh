#!/usr/bin/env bash
# revendor-arsenal.sh - refresh the vendored arsenal snapshot
# (distro/packages/arsenal-manifest.json) from the engine's AUTHORITATIVE
# manifest for the pinned ref, reusing arsenal-sync-check.sh's resolver (the
# single source of truth - no second resolution path is invented here).
#
# WHEN THIS RUNS: AUTO-TRIGGERED distro rebuilds only (repository_dispatch:
#   engine-deb-published, mapped to VACTI_ENGINE_REF=<published release>). On such
#   a rebuild the engine arsenal set may legitimately have drifted from the
#   committed snapshot; re-vendoring in-workspace BEFORE arsenal-sync-check keeps
#   the build GREEN and makes the (host-side) ISO package list track the ref.
#
# WHEN THIS MUST NOT RUN: a normal manual/push build. There the COMMITTED snapshot
#   is authoritative and arsenal-sync-check's drift detection must stay live; the
#   build.yml step that calls this is gated on github.event_name == 'repository_dispatch'.
#
# SOFT by design: if no authoritative reference is reachable (no apt creds / repo
# unreachable), the resolver soft-skips, this leaves the committed snapshot
# untouched, and the subsequent arsenal-sync-check also soft-skips - still green.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDORED="${ROOT}/distro/packages/arsenal-manifest.json"
CHECK="${ROOT}/ci/arsenal-sync-check.sh"

[[ -x "$CHECK" ]] || { echo "[revendor] ${CHECK} missing or not executable" >&2; exit 1; }

echo "[revendor] refreshing vendored arsenal snapshot for engine ref='${VACTI_ENGINE_REF:-latest}'"
before=""
[[ -f "$VENDORED" ]] && before="$(sha256sum "$VENDORED" | awk '{print $1}')"

"$CHECK" --revendor "$VENDORED"

after=""
[[ -f "$VENDORED" ]] && after="$(sha256sum "$VENDORED" | awk '{print $1}')"
if [[ "$before" == "$after" ]]; then
  echo "[revendor] vendored snapshot unchanged (already in sync, or no reference reachable - committed snapshot kept)"
else
  echo "[revendor] vendored snapshot updated to track the engine ref"
fi
