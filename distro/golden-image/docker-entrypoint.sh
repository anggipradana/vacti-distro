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

# --- interactive FAIL-CLOSED fallback (TG 7212) ------------------------------
# If we have no way to authenticate - no producer token (persisted/env) AND not
# both an enroll token AND a URL - start the browser activation UI on
# VACTI_WEBUI_PORT (default 3100) so the user can point a browser and paste the
# control-plane URL + the single-use license token, with NO `docker exec` and NO
# shell. It blocks until enrollment succeeds (writes engine.env, 0600), then this
# entrypoint continues and exec's the engine. A wrong/expired token just re-shows
# the form - there is no shell fallback. Set VACTI_WEBUI=0 for scripted /
# --env-file deployments that prefer a hard fail over the interactive UI.
ENGINE_ID="${ENGINE_ID:-$(hostname -s 2>/dev/null || echo engine)}"
ENROLL_TOKEN="${VACTI_ENROLL_TOKEN:-${ENROLL_TOKEN:-}}"
have_auth() { [[ -n "${VACTI_TOKEN:-}" ]] || { [[ -n "${ENROLL_TOKEN}" && -n "${VACTI_URL:-}" ]]; }; }
if ! have_auth; then
  if [[ "${VACTI_WEBUI:-1}" == "1" ]] && command -v node >/dev/null 2>&1 && [[ -f /usr/local/sbin/vacti-enroll-webui.js ]]; then
    log "no enrollment token supplied - starting the browser activation UI on :${VACTI_WEBUI_PORT:-3100} (open it and paste your license; no docker exec needed)"
    ENGINE_ID="$ENGINE_ID" STATE_ENV="$STATE_ENV" VACTI_URL="${VACTI_URL:-}" \
      VACTI_WEBUI_PORT="${VACTI_WEBUI_PORT:-3100}" \
      node /usr/local/sbin/vacti-enroll-webui.js   # blocks until enrolled
    if [[ -f "$STATE_ENV" ]]; then
      set -a; # shellcheck source=/dev/null
      . "$STATE_ENV"; set +a
    fi
  else
    die "no engine token available: supply VACTI_ENROLL_TOKEN (single-use mint) or VACTI_TOKEN (producer) plus VACTI_URL, or leave VACTI_WEBUI unset to use the browser activation UI on :${VACTI_WEBUI_PORT:-3100}"
  fi
fi

[[ -n "${VACTI_URL:-}" ]] || die "set VACTI_URL=https://<control-plane> (or CP_URL), or use the browser activation UI (leave VACTI_WEBUI unset)"

# Accept the enroll-token aliases (re-read in case the web UI / state env set them).
ENROLL_TOKEN="${VACTI_ENROLL_TOKEN:-${ENROLL_TOKEN:-}}"
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
[[ -n "${VACTI_TOKEN:-}" ]] || die "no engine token available: supply VACTI_TOKEN (producer) or VACTI_ENROLL_TOKEN (single-use mint), or use the browser activation UI (leave VACTI_WEBUI unset)"
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
