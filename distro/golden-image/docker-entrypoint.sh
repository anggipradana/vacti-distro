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
#   VACTI_URL or VACTI_CP_URL or CP_URL   control-plane base URL (required)
#   VACTI_TOKEN                       a producer token (skips the enroll exchange)
#   VACTI_ENROLL_TOKEN or ENROLL_TOKEN  a single-use mint token (3h TTL) to
#                                     exchange. ALSO accepts an 8-char pairing
#                                     code (K7X9-R8W2): if the value looks like a
#                                     short code it is first exchanged at the CP
#                                     for the full token (see VACTI_PAIRING_CODE).
#   VACTI_PAIRING_CODE               an 8-char pairing code (explicit alias for an
#                                     operator who prefers not to overload
#                                     VACTI_ENROLL_TOKEN). Either form works; a
#                                     pairing code REQUIRES the CP URL to be set
#                                     (the code is control-plane-scoped) and is
#                                     exchanged for the full enrollment token
#                                     before anything else runs.
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

# Shared short-code pairing exchange (lets VACTI_ENROLL_TOKEN / VACTI_PAIRING_CODE
# accept an 8-char pairing code, like the GUI kiosk + headless TUI). Sourced from
# the runtime install path, with a source-tree fallback for dev/CI. Fail-soft: if
# the helper is absent, only a FULL token works and a pairing code is rejected
# with a clear error - a producer/full token path is unaffected.
for _ph in \
  /usr/local/lib/vacti/pairing-exchange.sh \
  "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")/../enroll/common/pairing-exchange.sh"; do
  if [[ -r "$_ph" ]]; then
    # shellcheck source=/dev/null
    . "$_ph"
    break
  fi
done

# Normalize the URL aliases.
VACTI_URL="${VACTI_URL:-${VACTI_CP_URL:-${CP_URL:-}}}"

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

# PAIRING CODE -> FULL TOKEN. An operator may supply an 8-char pairing code
# (K7X9-R8W2) instead of a full enrollment token, either explicitly via
# VACTI_PAIRING_CODE or simply as the value of VACTI_ENROLL_TOKEN. The code is
# control-plane-scoped and single-use; it is exchanged for the full enrollment
# token HERE - before ensure_engine_installed, which uses the full token as the
# private-apt password to pull the engine .deb, and before the enroll POST below.
# Only when no producer token short-circuits the enroll path.
PAIRING_CODE="${VACTI_PAIRING_CODE:-}"
if [[ -z "$PAIRING_CODE" && -z "${VACTI_TOKEN:-}" && -n "$ENROLL_TOKEN" ]] \
   && declare -F vacti_is_short_code >/dev/null 2>&1 && vacti_is_short_code "$ENROLL_TOKEN"; then
  PAIRING_CODE="$ENROLL_TOKEN"   # VACTI_ENROLL_TOKEN was actually a short code
fi
if [[ -n "$PAIRING_CODE" ]]; then
  declare -F vacti_pairing_exchange >/dev/null 2>&1 \
    || die "pairing-code support helper missing (/usr/local/lib/vacti/pairing-exchange.sh); supply a full VACTI_ENROLL_TOKEN instead"
  [[ -n "${VACTI_URL:-}" ]] \
    || die "VACTI_CP_URL required when VACTI_ENROLL_TOKEN is a short code (the pairing code is control-plane-scoped)"
  log "pairing code detected - exchanging for the full enrollment token at ${BASE}/api/pentest/enroll/exchange (code not logged)"
  if _tok="$(vacti_pairing_exchange "$BASE" "$PAIRING_CODE")"; then
    ENROLL_TOKEN="$_tok"
  else
    _xrc=$?
    die "pairing-code exchange failed: $(vacti_pairing_error_en "$_xrc")"
  fi
  [[ -n "$ENROLL_TOKEN" ]] || die "pairing-code exchange returned an empty token"
fi

# THIN-BOOTSTRAP: the engine package is NOT baked into the published image (no
# /usr/lib/vacti-engine, no prompt-bundle, no skill-bundle - the plain-text IP
# never rides a public image). Pull the engine .deb now, from the private apt repo,
# authenticated with HTTP Basic (login vacti, password = the enrollment token, or
# the producer token when one is supplied directly). apt GET does not consume the
# single-use enroll token; the enroll POST below does. No credential or private
# host is baked: the auth.conf + source are written here, at container start.
ensure_engine_installed() {
  local marker="${APP}/dist/runner/cli.js"
  [[ -e "$marker" ]] && { log "engine already present (${marker})"; return 0; }
  local apt_token="${ENROLL_TOKEN:-${VACTI_TOKEN:-}}"
  if [[ -z "$apt_token" ]]; then
    die "engine not baked and no token to pull it: supply VACTI_ENROLL_TOKEN (single-use mint) or VACTI_TOKEN (producer)"
  fi
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "engine not baked and this entrypoint is not root; cannot apt-get install ${VACTI_ENGINE_PKG:-vacti-engine}"
  fi
  local apt_machine
  apt_machine="$(printf '%s/apt' "${BASE}" | sed -E 's#^[a-z]+://##')"
  install -d -m0755 /etc/apt/auth.conf.d /etc/apt/sources.list.d
  umask 077
  printf 'machine %s login vacti password %s\n' "${apt_machine}" "${apt_token}" \
    > /etc/apt/auth.conf.d/vacti-engine.conf
  chmod 0600 /etc/apt/auth.conf.d/vacti-engine.conf
  umask 022
  printf 'deb [trusted=yes] %s/apt ./\n' "${BASE}" > /etc/apt/sources.list.d/vacti-engine.list
  log "pulling ${VACTI_ENGINE_PKG:-vacti-engine} from ${BASE}/apt (engine not baked; token not logged)"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update || die "apt-get update failed against ${BASE}/apt (network / token?)"
  apt-get install -y --no-install-recommends "${VACTI_ENGINE_PKG:-vacti-engine}" \
    || die "apt-get install ${VACTI_ENGINE_PKG:-vacti-engine} failed (token expired/invalid or repo unreachable)"
  [[ -e "$marker" ]] || die "engine install reported success but ${marker} is missing"
  rm -rf /var/lib/apt/lists/* 2>/dev/null || true
}
ensure_engine_installed

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
