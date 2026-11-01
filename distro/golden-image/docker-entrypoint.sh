#!/usr/bin/env bash
# docker-entrypoint.sh - the container twin of distro/enroll/firstboot/vacti-firstboot.
#
# Installed as /usr/local/sbin/vacti-docker-entrypoint (the image ENTRYPOINT). A
# container has no systemd, so this script does what the firstboot unit + the
# vacti-engine.service ExecStart do together: locate a per-run token (never baked),
# exchange a single-use enroll token for the scoped engine tokens if needed, make
# the engine config available in the process environment, then exec the engine
# runner as PID 1 (it traps SIGTERM for a graceful finish-the-tick shutdown, and
# it starts Caido and Xvfb itself per engagement, so this entrypoint does not).
#
# Accepted per-run inputs (supplied at "docker run", never on the image):
#   VACTI_URL   or CP_URL             control-plane base URL (required)
#   VACTI_TOKEN                       a producer token (skips the enroll exchange)
#   VACTI_ENROLL_TOKEN or ENROLL_TOKEN  a single-use mint token (3h TTL) to exchange
#   ENGINE_ID                         optional engine id (defaults to the hostname)
#
# The scoped tokens obtained from an exchange are persisted to the state volume
# ($ENGINE_STATE_DIR/engine.env, 0600) so a restart inside the TTL comes back
# authenticated without re-minting.
set -euo pipefail

APP="${APP:-/usr/lib/vacti-engine}"
STATE_DIR="${ENGINE_STATE_DIR:-/var/lib/vacti-engine}"
STATE_ENV="${STATE_DIR}/engine.env"

log() { echo "[vacti-docker] $*"; }
die() { echo "[vacti-docker][FATAL] $*" >&2; exit 1; }

# Normalize the URL aliases.
VACTI_URL="${VACTI_URL:-${CP_URL:-}}"

# A prior run on this state volume already wrote the scoped tokens: reuse them.
if [[ -z "${VACTI_TOKEN:-}" && -f "$STATE_ENV" ]]; then
  log "reusing persisted engine config from ${STATE_ENV}"
  set -a
  # shellcheck source=/dev/null
  . "$STATE_ENV"
  set +a
fi

[[ -n "${VACTI_URL:-}" ]] || die "set VACTI_URL=https://<control-plane> (or CP_URL)"

# Accept the enroll-token aliases.
ENROLL_TOKEN="${VACTI_ENROLL_TOKEN:-${ENROLL_TOKEN:-}}"
ENGINE_ID="${ENGINE_ID:-$(hostname -s 2>/dev/null || echo engine)}"
BASE="${VACTI_URL%/}"

# Exchange a single-use enroll token for the scoped tokens, mirroring the
# firstboot POST /api/pentest/enroll handshake. Only when no producer token
# was supplied or persisted.
if [[ -z "${VACTI_TOKEN:-}" && -n "${ENROLL_TOKEN}" ]]; then
  log "enrolling engine_id=${ENGINE_ID} at ${BASE}/api/pentest/enroll (token not logged)"
  http_code="$(curl -sS -o /tmp/vacti-enroll.out -w '%{http_code}' \
    --connect-timeout 10 --max-time 60 \
    -H "Authorization: Bearer ${ENROLL_TOKEN}" \
    -H 'Content-Type: application/json' \
    -X POST "${BASE}/api/pentest/enroll" \
    -d "{\"engine_id\":\"${ENGINE_ID}\"}" || echo "000")"
  if [[ "$http_code" != "200" ]]; then
    body="$(cat /tmp/vacti-enroll.out 2>/dev/null || true)"; rm -f /tmp/vacti-enroll.out
    die "enroll failed (HTTP ${http_code}). The token may be expired or used (single-use, 3h TTL). Re-mint and retry. Response: ${body:-none}"
  fi
  install -d -m0755 "$STATE_DIR"
  umask 077
  {
    echo "VACTI_URL=${BASE}"
    if command -v jq >/dev/null 2>&1; then
      jq -r '
        "VACTI_TOKEN=\(.producer_token // .producer // "")",
        "VACTI_VERIFIER_TOKEN=\(.verifier_token // .verifier // "")",
        "VACTI_GATEKEEPER_TOKEN=\(.gatekeeper_token // .gatekeeper // "")"
      ' /tmp/vacti-enroll.out
    fi
  } > "$STATE_ENV"
  chmod 0600 "$STATE_ENV"
  umask 022
  rm -f /tmp/vacti-enroll.out
  set -a
  # shellcheck source=/dev/null
  . "$STATE_ENV"
  set +a
fi

export VACTI_URL="${BASE}"
[[ -n "${VACTI_TOKEN:-}" ]] || die "no engine token available: supply VACTI_TOKEN (producer) or VACTI_ENROLL_TOKEN (single-use mint)"
export VACTI_TOKEN
[[ -n "${VACTI_VERIFIER_TOKEN:-}" ]] && export VACTI_VERIFIER_TOKEN
[[ -n "${VACTI_GATEKEEPER_TOKEN:-}" ]] && export VACTI_GATEKEEPER_TOKEN

# Pre-start a virtual display so the first headful evidence capture does not have
# to fall back (the orchestrator will spawn its own Xvfb otherwise).
if command -v Xvfb >/dev/null 2>&1 && ! xdpyinfo -display :0 >/dev/null 2>&1; then
  Xvfb :0 -screen 0 1920x1080x24 -nolisten tcp >/tmp/xvfb.log 2>&1 &
fi

# Best-effort pinned-Chromium self-heal (the .deb postinst/ExecStartPre do this
# under systemd; here the first run heals it). Non-fatal: the runner self-heals too.
if [[ -x "${APP}/bin/ensure-browser.sh" ]]; then
  "${APP}/bin/ensure-browser.sh" || log "ensure-browser best-effort (runtime self-heal covers it)"
fi

# If the caller passed an explicit command, honour it; otherwise run the engine
# the same way the systemd unit does (node dist/runner/cli.js from WorkingDirectory).
cd "$APP"
if [[ "$#" -gt 0 ]]; then
  exec "$@"
fi
log "starting vacti-engine runner"
exec /usr/bin/node "${APP}/dist/runner/cli.js"
