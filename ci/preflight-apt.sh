#!/usr/bin/env bash
# ci/preflight-apt.sh - FAST, EARLY apt-pool pre-flight for the image build.
#
# WHY THIS EXISTS
# The FAT-OVA bake fetches the vacti-engine .deb from the private apt pool deep inside the ~1h47m golden
# job (ci/fetch-engine-debs.sh). When the release cascade dispatches the image build before the engine
# .deb has finished publishing - or, as in the 0.2.502->0.2.505 arm64 regression, the arm64 .deb is not
# in the pool AT ALL - that failure only surfaces after the runner has already spent an hour+ installing
# libguestfs, freeing disk and starting virt-customize. This pre-flight runs in the cheap LINT job
# (ubuntu-latest, seconds) and asserts the engine .deb for the target ARCH + pinned version is actually
# in the pool BEFORE the expensive golden job starts, so a missing/unpublished .deb fails in ~1 min
# instead of ~1h47m.
#
# RACE-TOLERANT: a dispatch can legitimately outrun the apt publish by a few minutes, so this WAITS
# (VACTI_PREFLIGHT_WAIT, default 900s) polling the index until the .deb appears, then exits 0. It only
# fails once the wait elapses. chromium is NOT checked here: it is engine-independent (built locally /
# HF-backfilled) and never the raced artifact.
#
# FAIL-SOFT ON MISSING CREDS: if the apt URL/token are not available (a fork, or a dispatch without the
# secret), this WARNS and exits 0 - it must never block a build that fetch-engine-debs.sh would still be
# able to run with its own fallbacks. It is an early-warning gate, not a second source of truth.
#
# Usage: ci/preflight-apt.sh <arch>
# Env:
#   VACTI_APT_URL              apt base URL (same var build.yml uses)
#   VACTI_APT_PRODUCER_TOKEN   producer/read token for the private apt pool
#   VACTI_ENGINE_REF           pinned engine version (exact; X.Y.Z matches X.Y.Z and X.Y.Z+build); empty = any
#   VACTI_PREFLIGHT_WAIT       seconds to wait for the .deb to appear (default 900; 0 = single check)
#   VACTI_PREFLIGHT_INTERVAL   poll interval in seconds (default 30)
set -uo pipefail

ARCH="${1:?usage: preflight-apt.sh <arch>}"
TOKEN="${VACTI_APT_PRODUCER_TOKEN:-}"
REF="${VACTI_ENGINE_REF:-}"; REF="${REF#v}"; REF="${REF%%+*}"
WAIT="${VACTI_PREFLIGHT_WAIT:-900}"
INTERVAL="${VACTI_PREFLIGHT_INTERVAL:-30}"

log()  { echo "[preflight-apt] $*"; }
warn() { echo "::warning::[preflight-apt] $*"; }
skip() { warn "$*; skipping the pre-flight (fetch-engine-debs.sh retains its own fallbacks)"; exit 0; }

[[ -n "${VACTI_APT_URL:-}" ]] || skip "VACTI_APT_URL not set"
[[ -n "$TOKEN" ]]            || skip "VACTI_APT_PRODUCER_TOKEN not set"

base="${VACTI_APT_URL%/}/apt"

# version_matches <version> <pin>: exact or pin + a Debian separator (mirrors fetch-engine-debs.sh).
version_matches() {
  local v="$1" p="$2"
  [[ -z "$p" || "$v" == "$p" || "$v" == "$p"+* || "$v" == "$p"-* || "$v" == "$p"~* ]]
}

# engine_present: read the index and return 0 if a vacti-engine stanza for ARCH (or 'all') matching the
# pin exists. Prints a one-line reason. Exit 2 = HARD (index unreadable: auth/path/network).
engine_present() {
  local idx
  idx="$(curl -fsSL --max-time 30 -u "vacti:${TOKEN}" "${base}/Packages" 2>/dev/null \
         || curl -fsSL --max-time 30 -u "vacti:${TOKEN}" "${base}/Packages.gz" 2>/dev/null | gunzip -c 2>/dev/null \
         || true)"
  [[ -n "$idx" ]] || return 2
  awk -v arch="$ARCH" -v pin="$REF" '
    BEGIN { RS=""; FS="\n"; found=0 }
    {
      p=""; v=""; a=""
      for (i=1;i<=NF;i++) {
        if      ($i ~ /^Package: /)      { p=substr($i,10) }
        else if ($i ~ /^Version: /)      { v=substr($i,10) }
        else if ($i ~ /^Architecture: /) { a=substr($i,15) }
      }
      if (p=="vacti-engine" && (a==arch || a=="all")) {
        if (pin=="" || v==pin || index(v,pin"+")==1 || index(v,pin"-")==1 || index(v,pin"~")==1) found=1
      }
    }
    END { exit (found ? 0 : 1) }
  ' <<<"$idx"
}

log "pre-flight: vacti-engine ${REF:-<any>} (${ARCH}) in ${base} (wait up to ${WAIT}s)"
deadline=$(( SECONDS + WAIT ))
while :; do
  engine_present; rc=$?
  if [[ "$rc" -eq 0 ]]; then
    log "OK: vacti-engine${REF:+ ${REF}} (${ARCH}) is present in the apt pool"
    exit 0
  elif [[ "$rc" -eq 2 ]]; then
    skip "could not read the apt index at ${base}/Packages[.gz] (auth/path/network)"
  fi
  if [[ "$SECONDS" -ge "$deadline" ]]; then
    echo "::error::[preflight-apt] vacti-engine${REF:+ ${REF}} (${ARCH}) is NOT in the apt pool after ${WAIT}s." >&2
    echo "::error::[preflight-apt] The ${ARCH} engine .deb was never published (run release-deb.yml / release-onbox for this arch)," >&2
    echo "::error::[preflight-apt] so the ~1h47m golden build would fail at the fetch step. Failing fast instead." >&2
    exit 1
  fi
  log "not present yet; retrying in ${INTERVAL}s ..."
  sleep "$INTERVAL"
done
