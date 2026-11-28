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
# SLICE-CAP NOTE (parity with the OVA's vacti-slice-cap.service). A container has
# no systemd manager at all, so the vacti.slice cgroup the OVA's engine-user
# manager uses to cap transient agent/browser/tool scopes does not exist here. The
# OVA's firstboot reconcile (/usr/local/sbin/vacti-slice-cap) is therefore NOT
# invoked in the container path by design, and the service unit it drives is
# gated by ConditionVirtualization=!container so it would be inert even if
# systemd were present. The engine's memory guard (src/runner/agent-memory.ts)
# handles the null-slice case cleanly: readSliceMemory returns null when no
# vacti.slice cgroup files exist and boxUnderPressure then falls back to the
# MemAvailable floor (plus PSI from /proc/pressure/memory when the host kernel
# exposes it). The container's own cgroup MemoryMax (the docker --memory flag) is
# respected by the kernel independently of this slice cap, so the engine remains
# memory-guarded in the container-limited case; the distro-side regression test
# distro/test/slice-cap-contract.sh asserts this contract.
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
#   VACTI_ENGINE_SHARED_SECRET        optional; normally taken from the enroll response
#                                     (the X-Engine-Auth edge secret). Pass it with -e
#                                     only on the direct VACTI_TOKEN path (no enroll).
#   VACTI_TAILSCALED=0                skip starting tailscaled (default: start it)
#
# Recommended for kernel-mode tailscale: --cap-add=NET_ADMIN --device=/dev/net/tun.
# Without them tailscaled runs in userspace-networking mode (no extra caps).
#
# The scoped tokens obtained from an exchange (and the edge shared secret) are
# persisted to the state volume ($ENGINE_STATE_DIR/engine.env, 0600) so a restart
# inside the TTL comes back authenticated without re-minting.
#
# PROVISIONING ORDER (parity with the OVA's vacti-firstboot + systemd units):
#   1. enroll -> engine.env: scoped tokens + VACTI_ENGINE_SHARED_SECRET. FATAL on failure.
#   2. engine binaries/browser/caido-cli self-heal (fail-open).
#   3. tailscaled daemon up, no key (fail-open) - twin of `systemctl enable tailscaled`.
#   4. exec the engine. It fetches engine-config WITH X-Engine-Auth (needs step 1), which
#      delivers tailscale.auth_key/login_server (the engine runs `tailscale up`, needs
#      step 3) and the Caido email/password (the engine logs Caido in per engagement).
#      Neither the tailnet join nor the Caido login happens in this script - same as
#      the OVA, where both are engine-runtime steps.
set -euo pipefail

APP="${APP:-/usr/lib/vacti-engine}"
STATE_DIR="${ENGINE_STATE_DIR:-/var/lib/vacti-engine}"
STATE_ENV="${STATE_DIR}/engine.env"

# Container-start timestamp for the HEALTHCHECK grace window (see distro/Dockerfile).
# Re-written on every (re)start: the entrypoint is PID 1 and re-execs on each start,
# so this always reflects THIS boot. The healthcheck compares (now - this) against
# VACTI_HEALTHCHECK_START_PERIOD to stay "starting" while a THIN image provisions
# longer than the baked --start-period (THIN install + browser/Caido self-heal). On
# /run (a per-run tmpfs) so it never carries a stale value across a restart.
printf '%s\n' "$(date +%s 2>/dev/null || echo 0)" > /run/vacti-engine.boot-ts 2>/dev/null || true

log() { echo "[vacti-docker] $*"; }
die() { echo "[vacti-docker][FATAL] $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# i18n (EN/ID). Self-contained string table - no gettext, no new deps. Default
# is Indonesian. In a container the language is chosen via the VACTI_LANG env var
# (e.g. `docker run -e VACTI_LANG=en`), else the inherited $LANG locale. No --lang
# flag here: this entrypoint's positional args are the container command to exec.
# Operator-facing enrollment/token/network errors are translated; deep apt /
# signature plumbing diagnostics stay in English for searchability. A key missing
# in the chosen language falls back to EN. Strings use "{}" as a placeholder.
# ---------------------------------------------------------------------------
_resolve_uilang() {
  local v="${VACTI_LANG:-}"
  if [[ -z "$v" ]]; then
    if   [[ "${LANG:-}" == id* || "${LC_ALL:-}" == id* ]]; then v="id"
    elif [[ -n "${LANG:-}${LC_ALL:-}" ]]; then v="en"; fi
  fi
  v="${v,,}"; v="${v//[[:space:]]/}"
  case "$v" in en) echo en ;; id) echo id ;; *) echo id ;; esac
}
VACTI_UILANG="$(_resolve_uilang)"

declare -A VT_EN=(
  [err_need_url]="set VACTI_URL=https://<control-plane> (or CP_URL)"
  [err_pairing_helper]="pairing-code support helper missing (/usr/local/lib/vacti/pairing-exchange.sh); supply a full VACTI_ENROLL_TOKEN instead"
  [err_url_for_code]="VACTI_CP_URL required when VACTI_ENROLL_TOKEN is a short code (the pairing code is control-plane-scoped)"
  [err_pairing_failed]="pairing-code exchange failed: {}"
  [err_pairing_empty]="pairing-code exchange returned an empty token"
  [err_no_token_pull]="engine not baked and no token to pull it: supply VACTI_ENROLL_TOKEN (single-use mint) or VACTI_TOKEN (producer)"
  [err_enroll_http]="enroll failed (HTTP {}). The token may be expired or used (single-use, 3h TTL). Re-mint and retry. Response: {}"
  [err_no_engine_token]="no engine token available: supply VACTI_TOKEN (producer) or VACTI_ENROLL_TOKEN (single-use mint)"
)
declare -A VT_ID=(
  [err_need_url]="atur VACTI_URL=https://<control-plane> (atau CP_URL)"
  [err_pairing_helper]="helper pendukung kode pairing tidak ada (/usr/local/lib/vacti/pairing-exchange.sh); pakai VACTI_ENROLL_TOKEN lengkap sebagai gantinya"
  [err_url_for_code]="VACTI_CP_URL wajib diisi bila VACTI_ENROLL_TOKEN berupa kode pendek (kode pairing terikat ke control-plane)"
  [err_pairing_failed]="penukaran kode pairing gagal: {}"
  [err_pairing_empty]="penukaran kode pairing mengembalikan token kosong"
  [err_no_token_pull]="engine belum ter-bake dan tidak ada token untuk menariknya: pakai VACTI_ENROLL_TOKEN (mint sekali pakai) atau VACTI_TOKEN (producer)"
  [err_enroll_http]="enroll gagal (HTTP {}). Token mungkin kedaluwarsa atau sudah dipakai (sekali pakai, TTL 3 jam). Mint ulang lalu coba lagi. Respons: {}"
  [err_no_engine_token]="tidak ada token engine: pakai VACTI_TOKEN (producer) atau VACTI_ENROLL_TOKEN (mint sekali pakai)"
)

_lookup() { # key
  local key="$1" val=""
  if [[ "$VACTI_UILANG" == "en" ]]; then
    val="${VT_EN[$key]-}"
  else
    val="${VT_ID[$key]-}"
    if [[ -z "$val" && -n "${VT_EN[$key]-}" ]]; then
      echo "[vacti-docker] i18n key '$key' missing for id; using en" >&2
      val="${VT_EN[$key]}"
    fi
  fi
  if [[ -z "$val" ]]; then
    [[ -z "${VT_EN[$key]-}" ]] && echo "[vacti-docker] missing i18n key: $key" >&2
    val="${VT_EN[$key]-$key}"
  fi
  printf '%s' "$val"
}

# _t KEY [ARG...] -> the translated string with each "{}" replaced by an ARG.
_t() {
  local key="$1"; shift || true
  local val; val="$(_lookup "$key")"
  local a
  for a in "$@"; do val="${val/"{}"/$a}"; done
  printf '%s' "$val"
}

# apt-pool signing keyring, BAKED into the image (see distro/Dockerfile). Present
# => pin the engine apt source to signed-by=.
APT_KEYRING="/usr/share/keyrings/vacti-apt.gpg"

# vacti_apt_keyring_valid PATH -> 0 if PATH is a non-empty, parseable OpenPGP
# keyring. apt's own gpgv enforces the actual signature at `apt-get update`; this
# is the pre-flight probe that decides signed-by vs the fail-closed refusal.
vacti_apt_keyring_valid() {
  local kr="$1"
  [[ -s "$kr" ]] || return 1
  if command -v gpg >/dev/null 2>&1; then
    gpg --no-default-keyring --keyring "$kr" --list-keys >/dev/null 2>&1 || return 1
  fi
  return 0
}

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

[[ -n "${VACTI_URL:-}" ]] || die "$(_t err_need_url)"

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
    || die "$(_t err_pairing_helper)"
  [[ -n "${VACTI_URL:-}" ]] \
    || die "$(_t err_url_for_code)"
  log "pairing code detected - exchanging for the full enrollment token at ${BASE}/api/pentest/enroll/exchange (code not logged)"
  if _tok="$(vacti_pairing_exchange "$BASE" "$PAIRING_CODE")"; then
    ENROLL_TOKEN="$_tok"
  else
    _xrc=$?
    if [[ "$VACTI_UILANG" == "en" ]]; then
      die "$(_t err_pairing_failed "$(vacti_pairing_error_en "$_xrc")")"
    else
      die "$(_t err_pairing_failed "$(vacti_pairing_error_id "$_xrc")")"
    fi
  fi
  [[ -n "$ENROLL_TOKEN" ]] || die "$(_t err_pairing_empty)"
fi

# FAT image (FAT_IMAGE=1, the build default): the engine is already baked at
# ${APP}/dist/runner/cli.js, so the marker check below returns early ("engine
# already present") and NO apt pull happens; the enroll POST handshake further
# down still runs. THIN image (FAT_IMAGE=0): the engine package is NOT baked (no
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
    die "$(_t err_no_token_pull)"
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
  # --- apt source line: verify the repo SIGNATURE via the baked keyring --------
  # The image bakes the public apt-pool keyring at $APT_KEYRING (ed25519 OpenPGP,
  # fp 1240992D7986141C461AEC4B1F971D5D47DBFA8F). Pin the source to signed-by= so
  # apt verifies the repo InRelease before it installs the engine .deb as root -
  # closing a TLS-intercepting proxy that serves a forged .deb.
  #   - VACTI_APT_SIGNED=0 : operator escape hatch -> legacy [trusted=yes] + loud warn
  #   - keyring present+valid: [signed-by=$APT_KEYRING]
  #   - keyring MISSING/invalid (no kill-switch): FAIL-CLOSED (die). On an appliance a
  #     baked keyring is either present or the image was tampered/corrupted, so refusing
  #     to install an unverified root package is correct (Jev fail_closed p=1.0).
  local src="/etc/apt/sources.list.d/vacti-engine.list"
  if [[ "${VACTI_APT_SIGNED:-1}" == "0" ]]; then
    log "WARNING: VACTI_APT_SIGNED=0 - apt signature verification DISABLED by operator; writing legacy [trusted=yes] for ${BASE}/apt"
    printf '# WARNING: signature verification disabled via VACTI_APT_SIGNED=0.\ndeb [trusted=yes] %s/apt ./\n' "${BASE}" > "$src"
  elif vacti_apt_keyring_valid "$APT_KEYRING"; then
    printf '# Repo signature verified by apt against the baked keyring.\ndeb [signed-by=%s] %s/apt ./\n' "$APT_KEYRING" "${BASE}" > "$src"
    log "apt source wired with signed-by=${APT_KEYRING} for ${BASE}/apt"
  else
    die "apt signing keyring ${APT_KEYRING} is missing or invalid - the image is tampered or corrupted. Refusing to install ${VACTI_ENGINE_PKG:-vacti-engine} from an unverified apt source. To override on a trusted network, set VACTI_APT_SIGNED=0."
  fi
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
    die "$(_t err_enroll_http "${http_code}" "${body:-none}")"
  fi
  install -d -m0755 "$STATE_DIR"
  umask 077
  # VACTI_ENGINE_SHARED_SECRET (parity with distro/enroll/firstboot/vacti-firstboot):
  # Caddy at the public edge 401s every engine writeback - heartbeat, jobs/next,
  # engine-config - unless the request carries X-Engine-Auth == this secret. Only the
  # Bearer-exempt /enroll* subtree is reachable without it, so WITHOUT this line a
  # container ENROLLS fine but its first heartbeat AND its engine-config fetch are 401'd.
  # The engine-config fetch is what delivers tailscale.auth_key/login_server and the
  # caido email/password, so a missing secret also leaves the tailnet un-joined and Caido
  # un-logged-in. Emit ONLY when the CP returned a non-empty value, so an unset CP field
  # yields a byte-identical engine.env to the pre-fix behaviour.
  {
    echo "VACTI_URL=${BASE}"
    if command -v jq >/dev/null 2>&1; then
      jq -r '
        "VACTI_TOKEN=\(.producer_token // .producer // "")",
        "VACTI_VERIFIER_TOKEN=\(.verifier_token // .verifier // "")",
        "VACTI_GATEKEEPER_TOKEN=\(.gatekeeper_token // .gatekeeper // "")"
      ' /tmp/vacti-enroll.out
      secret="$(jq -r '.engineSharedSecret // .engine_shared_secret // empty' /tmp/vacti-enroll.out 2>/dev/null || true)"
      [[ -n "$secret" ]] && printf 'VACTI_ENGINE_SHARED_SECRET=%s\n' "$secret"
      unset secret
      bound_id="$(jq -r '.engine_id // empty' /tmp/vacti-enroll.out 2>/dev/null || true)"
    elif command -v node >/dev/null 2>&1; then
      # node fallback (node ships in the image): parse + emit only non-empty values.
      node -e '
        const fs = require("fs");
        const j = JSON.parse(fs.readFileSync("/tmp/vacti-enroll.out", "utf8"));
        const w = (k, v) => { if (v) process.stdout.write(k + "=" + v + "\n"); };
        w("VACTI_TOKEN", j.producer_token || j.producer);
        w("VACTI_VERIFIER_TOKEN", j.verifier_token || j.verifier);
        w("VACTI_GATEKEEPER_TOKEN", j.gatekeeper_token || j.gatekeeper);
        w("VACTI_ENGINE_SHARED_SECRET", j.engineSharedSecret || j.engine_shared_secret);
      ' 2>/dev/null || true
      bound_id="$(node -e 'try{process.stdout.write(String(JSON.parse(require("fs").readFileSync("/tmp/vacti-enroll.out","utf8")).engine_id||""))}catch{}' 2>/dev/null || true)"
    fi
    # ENGINE_ID (parity with vacti-firstboot + bootstrap-apt.sh): persist the CP-bound
    # engine id (the name reserved when the token/pairing code was minted). The engine
    # reads ENGINE_ID from its environment; without it every container ran as the
    # schema default kali-engine-01 and joined the tailnet as kali-engine-01-N.
    bound_id="${bound_id:-}"; bound_id="${bound_id//[^A-Za-z0-9._-]/}"; bound_id="${bound_id:0:60}"
    if [[ -z "$bound_id" ]]; then bound_id="${ENGINE_ID//[^A-Za-z0-9._-]/}"; bound_id="${bound_id:0:60}"; fi
    if [[ -n "$bound_id" ]]; then printf 'ENGINE_ID=%s\n' "$bound_id"; fi
  } > "$STATE_ENV"
  chmod 0600 "$STATE_ENV"
  umask 022
  # VD-4 tailnet AUTO-JOIN: capture the FRESH single-use Headscale preauth key + login server the CP returned
  # on THIS enroll response, BEFORE the response file is wiped. Both are OPTIONAL (absent on an unconfigured CP
  # or an old deployment) - we just stash them for the `tailscale up` below. The key is never written to disk or
  # logged: it lives only in these shell vars and is consumed by `tailscale up`.
  HS_PREAUTH_KEY=""; HS_LOGIN_SERVER=""
  if command -v jq >/dev/null 2>&1; then
    HS_PREAUTH_KEY="$(jq -r '.headscale_preauth_key // empty' /tmp/vacti-enroll.out 2>/dev/null || true)"
    HS_LOGIN_SERVER="$(jq -r '.headscale_login_server // empty' /tmp/vacti-enroll.out 2>/dev/null || true)"
  elif command -v node >/dev/null 2>&1; then
    HS_PREAUTH_KEY="$(node -e 'try{process.stdout.write(JSON.parse(require("fs").readFileSync("/tmp/vacti-enroll.out","utf8")).headscale_preauth_key||"")}catch{}' 2>/dev/null || true)"
    HS_LOGIN_SERVER="$(node -e 'try{process.stdout.write(JSON.parse(require("fs").readFileSync("/tmp/vacti-enroll.out","utf8")).headscale_login_server||"")}catch{}' 2>/dev/null || true)"
  fi
  rm -f /tmp/vacti-enroll.out
  set -a
  # shellcheck source=/dev/null
  . "$STATE_ENV"
  set +a
fi

export VACTI_URL="${BASE}"
[[ -n "${VACTI_TOKEN:-}" ]] || die "$(_t err_no_engine_token)"
export VACTI_TOKEN
[[ -n "${VACTI_VERIFIER_TOKEN:-}" ]] && export VACTI_VERIFIER_TOKEN
[[ -n "${VACTI_GATEKEEPER_TOKEN:-}" ]] && export VACTI_GATEKEEPER_TOKEN
# X-Engine-Auth edge secret: from engine.env (enroll / persisted) or a `docker run -e`.
# Must be in the engine's env BEFORE exec - the engine reads it once at module load.
[[ -n "${VACTI_ENGINE_SHARED_SECRET:-}" ]] && export VACTI_ENGINE_SHARED_SECRET
# Engine identity: from engine.env (enroll / persisted), a `docker run -e ENGINE_ID`, or
# the hostname fallback above. Exported so the engine never falls back to its
# kali-engine-01 schema default (tailnet hostname collisions across containers).
export ENGINE_ID

# Optional pre-start of a virtual display. OFF by default (VACTI_XVFB_PRESTART unset):
# the engine orchestrator spawns and owns its own Xvfb per headful capture, so a
# pre-started :0 here is redundant and just holds a process + a display lock for the
# container's whole life. Set VACTI_XVFB_PRESTART=1 to restore the eager pre-start
# (e.g. a workload that attaches to :0 before the engine's first capture).
if [[ "${VACTI_XVFB_PRESTART:-0}" =~ ^(1|true|on|yes)$ ]]; then
  if command -v Xvfb >/dev/null 2>&1 && ! xdpyinfo -display :0 >/dev/null 2>&1; then
    Xvfb :0 -screen 0 1920x1080x24 -nolisten tcp >/tmp/xvfb.log 2>&1 &
    log "xvfb: pre-started on :0 (VACTI_XVFB_PRESTART enabled)"
  fi
fi

# Best-effort pinned-Chromium self-heal (the .deb postinst/ExecStartPre do this
# under systemd; here the first run heals it). Non-fatal: the runner self-heals too.
if [[ -x "${APP}/bin/ensure-browser.sh" ]]; then
  "${APP}/bin/ensure-browser.sh" || log "ensure-browser best-effort (runtime self-heal covers it)"
fi

# Best-effort Caido CLI self-heal. The OVA/golden image bakes caido-cli via
# install-engine-extras.sh step_caido (into the engine user's home); the THIN Docker
# image bakes NOTHING engine-side, so the first container start heals it here - the
# container twin of that bake. The engine resolves caido-cli at $HOME/caido/caido-cli
# (start-arsenal.sh: CAIDO_BIN="${CAIDO_BIN:-$HOME/caido/caido-cli}"; preflight-heal.ts:
# join(homedir(),'caido','caido-cli')) - both prefer $HOME - and this entrypoint execs
# the engine with the SAME uid/$HOME below, so we install into that exact $HOME. Pinned
# version + URL + arch mapping mirror install-engine-extras.sh. Fail-OPEN: a missing
# Caido only degrades evidence to the Playwright render (same contract as
# ensure-browser.sh above); it must never block container start.
# NOTE: $HOME (/root) is NOT the persisted state volume, so this re-fetches on each
# fresh container; it is idempotent within a container's lifetime (restart reuses it).
# Caido version resolution (D7). Precedence: an explicit VACTI_CAIDO_VERSION wins;
# otherwise read the single source of truth - the engine's installed arsenal manifest
# (packaging/arsenal-manifest.json -> pins.caido_cli), which the .deb ships and the
# OVA bake also reads - so the container never drifts from the version the engine was
# built against. The hardcoded value is only the last-resort fallback if the manifest
# is unreadable (very early first boot before the engine tree lands).
resolve_caido_version() {
  local v="${VACTI_CAIDO_VERSION:-}"
  if [[ -z "$v" ]]; then
    local manifest="${APP}/packaging/arsenal-manifest.json"
    if [[ -r "$manifest" ]]; then
      v="$(sed -n 's/.*"caido_cli"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$manifest" 2>/dev/null | head -1 || true)"
      [[ -n "$v" ]] && log "caido: version ${v} sourced from arsenal manifest (${manifest})"
    fi
  fi
  [[ -n "$v" ]] || v="v0.57.0"
  printf '%s' "$v"
}
CAIDO_VERSION="$(resolve_caido_version)"
heal_caido() {
  # Resolve the engine's effective home exactly as the engine will at exec time:
  # $HOME when set (node os.homedir() + the shell both prefer it), else the passwd entry.
  local home="${HOME:-}"
  if [[ -z "$home" ]]; then
    home="$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6 || true)"
    [[ -n "$home" ]] || home="/root"
  fi
  local caido_dir="${home}/caido"
  local caido_bin="${caido_dir}/caido-cli"
  [[ -x "$caido_bin" ]] && { log "caido self-heal: already present (${caido_bin})"; return 0; }

  local arch caido_arch
  arch="$(uname -m 2>/dev/null || echo unknown)"
  case "$arch" in
    x86_64|amd64)   caido_arch="x86_64" ;;
    aarch64|arm64)  caido_arch="aarch64" ;;
    *)              caido_arch="x86_64"; log "caido self-heal: unknown arch ${arch}, trying x86_64" ;;
  esac

  # D3: cache the extracted binary on the PERSISTED state volume, keyed by
  # version+arch, so a fresh container sharing the same ${STATE_DIR} volume restores
  # caido-cli with a file copy instead of re-downloading ~tens of MB from
  # caido.download on every `docker run`. $HOME (/root) is NOT persisted; the state
  # volume is. A copy (not a symlink) so the engine's $HOME path resolves even if the
  # volume is later detached mid-life.
  local cache_dir="${STATE_DIR}/cache/caido/${CAIDO_VERSION}-${caido_arch}"
  local cache_bin="${cache_dir}/caido-cli"
  if [[ -x "$cache_bin" ]]; then
    mkdir -p "$caido_dir" 2>/dev/null || true
    if cp -f "$cache_bin" "$caido_bin" 2>/dev/null; then
      chmod +x "$caido_bin" 2>/dev/null || true
      log "caido self-heal: restored ${CAIDO_VERSION} (${caido_arch}) from volume cache (${cache_bin}); no download"
      return 0
    fi
    log "caido self-heal: volume cache present but copy failed; falling through to download"
  fi

  command -v curl >/dev/null 2>&1 || { log "caido self-heal: curl unavailable, skipping (evidence degrades to the render)"; return 0; }

  local url="https://caido.download/releases/${CAIDO_VERSION}/caido-cli-${CAIDO_VERSION}-linux-${caido_arch}.tar.gz"

  local tmp
  tmp="$(mktemp -d 2>/dev/null || true)"
  [[ -n "$tmp" && -d "$tmp" ]] || { log "caido self-heal: mktemp failed, continuing with degraded capability"; return 0; }

  log "caido self-heal: downloading ${CAIDO_VERSION} (${caido_arch}) from ${url}"
  local http
  http="$(curl -sL -o "${tmp}/caido-cli.tar.gz" -w '%{http_code}' --connect-timeout 10 -m 180 "$url" 2>/dev/null || echo 000)"
  if [[ "$http" != "200" || ! -s "${tmp}/caido-cli.tar.gz" ]]; then
    log "caido self-heal: failed (fetched URL=${url}, http=${http}), continuing with degraded capability"
    rm -rf "$tmp" 2>/dev/null || true
    return 0
  fi

  # Best-effort checksum: verify ONLY if caido.download publishes a .sha256 sidecar.
  # A 404 (or no sha256sum) means skip-but-log, never fail the heal.
  local sha_url="${url}.sha256" sha_http
  sha_http="$(curl -sL -o "${tmp}/caido-cli.tar.gz.sha256" -w '%{http_code}' --connect-timeout 10 -m 30 "$sha_url" 2>/dev/null || echo 000)"
  if [[ "$sha_http" == "200" && -s "${tmp}/caido-cli.tar.gz.sha256" ]] && command -v sha256sum >/dev/null 2>&1; then
    local want got
    want="$(awk '{print $1}' "${tmp}/caido-cli.tar.gz.sha256" 2>/dev/null | head -1 || true)"
    got="$(sha256sum "${tmp}/caido-cli.tar.gz" 2>/dev/null | awk '{print $1}' || true)"
    if [[ -n "$want" && -n "$got" && "$want" != "$got" ]]; then
      log "caido self-heal: checksum MISMATCH (want=${want} got=${got}); refusing the tarball, continuing with degraded capability"
      rm -rf "$tmp" 2>/dev/null || true
      return 0
    fi
    log "caido self-heal: checksum verified"
  else
    log "caido self-heal: no checksum sidecar (http=${sha_http}); skipping checksum verification"
  fi

  mkdir -p "$caido_dir" 2>/dev/null || true
  if tar xzf "${tmp}/caido-cli.tar.gz" -C "$caido_dir" 2>/dev/null && [[ -e "$caido_bin" ]]; then
    chmod +x "$caido_bin" 2>/dev/null || true
    rm -rf "$tmp" 2>/dev/null || true
    # D3: seed the persisted volume cache so the next fresh container skips the download.
    if mkdir -p "$cache_dir" 2>/dev/null && cp -f "$caido_bin" "$cache_bin" 2>/dev/null; then
      chmod +x "$cache_bin" 2>/dev/null || true
      log "caido self-heal: cached ${CAIDO_VERSION} (${caido_arch}) on the state volume (${cache_bin})"
    fi
    log "caido self-heal: ready (${caido_bin})"
    return 0
  fi
  log "caido self-heal: extraction failed (fetched URL=${url}, http=${http}), continuing with degraded capability"
  rm -rf "$tmp" 2>/dev/null || true
  return 0
}
heal_caido

# tailscaled daemon - the container twin of the golden image's `systemctl enable
# tailscaled` (build-golden.sh). Like the OVA, NO auth key is used here and this does
# NOT run `tailscale up`: the engine itself joins at runtime (runner healTailscaleOnce:
# `sudo -n tailscale up --authkey=... [--login-server=<headscale>]`) once its
# engine-config fetch - authenticated by the X-Engine-Auth secret above - delivers
# tailscale.auth_key/login_server, and its periodic heal keeps it joined. A container
# has no systemd, so the daemon is started here. Kernel TUN mode when the container
# was given `--cap-add=NET_ADMIN --device=/dev/net/tun`; otherwise (or if kernel mode
# exits) userspace networking, which needs no extra caps. Node state lives on the
# state volume so the tailnet identity survives a container restart. Fail-OPEN: a
# missing/failed tailscaled only means no tailnet; it never blocks engine start.
# VACTI_TAILSCALED=0 skips it (operator-managed tailscale, or no tailnet wanted).
TAILSCALED_STATE="skipped"
start_tailscaled() {
  if [[ "${VACTI_TAILSCALED:-1}" =~ ^(0|false|off|no)$ ]]; then
    TAILSCALED_STATE="disabled"; log "tailscaled: disabled by VACTI_TAILSCALED=${VACTI_TAILSCALED}"; return 0
  fi
  if ! command -v tailscaled >/dev/null 2>&1 || ! command -v tailscale >/dev/null 2>&1; then
    TAILSCALED_STATE="absent"; log "tailscaled: not installed in this image; tailnet join unavailable (engine runs normally)"; return 0
  fi
  if pgrep -x tailscaled >/dev/null 2>&1; then
    TAILSCALED_STATE="already-running"; log "tailscaled: already running"; return 0
  fi
  local ts_dir="${STATE_DIR}/tailscale" mode pid
  install -d -m0700 "$ts_dir" 2>/dev/null || true
  install -d -m0755 /var/run/tailscale 2>/dev/null || true
  for mode in kernel userspace; do
    [[ "$mode" == "kernel" && ! -c /dev/net/tun ]] && continue
    local tun_arg=()
    [[ "$mode" == "userspace" ]] && tun_arg=(--tun=userspace-networking)
    tailscaled --state="${ts_dir}/tailscaled.state" --statedir="${ts_dir}" \
      ${tun_arg[@]+"${tun_arg[@]}"} >>/tmp/tailscaled.log 2>&1 &
    pid=$!
    # Kernel mode without NET_ADMIN exits within a second or two; a live pid after
    # the settle window means the daemon is up and the engine's `tailscale up` can join.
    for _ in 1 2 3 4 5 6; do
      sleep 0.5
      kill -0 "$pid" 2>/dev/null || break
    done
    if kill -0 "$pid" 2>/dev/null; then
      TAILSCALED_STATE="started-${mode}"
      log "tailscaled: started (${mode} mode, pid ${pid}, state ${ts_dir}); the engine joins the tailnet from engine-config"
      return 0
    fi
    log "tailscaled: ${mode} mode exited (see /tmp/tailscaled.log)$([[ "$mode" == "kernel" ]] && echo '; falling back to userspace networking')"
  done
  TAILSCALED_STATE="failed"
  log "tailscaled: could not start; tailnet join unavailable (engine runs normally)"
  return 0
}
start_tailscaled

# VD-4 Headscale AUTO-JOIN at enrollment. The CP enroll response delivered a FRESH, single-use per-engine
# preauth key + the login server URL (captured into HS_PREAUTH_KEY / HS_LOGIN_SERVER above). Run `tailscale up`
# here so the engine joins the operator tailnet IMMEDIATELY at first boot, instead of only later when the runner
# fetches engine-config and heals. FAIL-OPEN at every step: missing fields, no tailscale CLI, an already-joined
# node, or a non-zero `tailscale up` exit are logged and ignored - the engine still reaches the CP over public
# HTTPS and the runtime tailscale-heal re-joins from engine-config. The single-use key is consumed by this call
# and is NOT persisted; its VALUE is never logged.
headscale_autojoin() {
  local key="${HS_PREAUTH_KEY:-}" server="${HS_LOGIN_SERVER:-}"
  if [[ -z "$key" || -z "$server" ]]; then
    log "headscale: no preauth key/login server in enroll response; tailnet join deferred to engine-config heal"
    return 0
  fi
  if ! command -v tailscale >/dev/null 2>&1; then
    log "headscale: tailscale CLI absent; skipping enrollment auto-join (engine runs normally)"
    return 0
  fi
  if tailscale status --json 2>/dev/null | grep -q '"BackendState"[[:space:]]*:[[:space:]]*"Running"'; then
    log "headscale: node already joined (BackendState Running); skipping enrollment auto-join"
    return 0
  fi
  log "headscale: joining tailnet via enroll preauth key (login-server=${server}, hostname=${ENGINE_ID}, key not logged)"
  # Group so the redirect is owned by the invoking shell, not sudo (shellcheck SC2024):
  # the subshell owns /tmp/tailscale-up.log fd and both attempts' output flows into it.
  # --reset: a persisted tailscaled state on the volume may carry earlier non-default prefs, which makes a
  # plain `up` refuse ("requires mentioning all non-default flags"). --timeout bounds the wait for Running.
  if { tailscale up --reset --login-server="$server" --authkey="$key" --hostname="$ENGINE_ID" --accept-dns=false --accept-routes=false --timeout=60s \
       || sudo -n tailscale up --reset --login-server="$server" --authkey="$key" --hostname="$ENGINE_ID" --accept-dns=false --accept-routes=false --timeout=60s; } >>/tmp/tailscale-up.log 2>&1; then
    log "headscale: tailscale up succeeded; the engine should appear in 'headscale nodes list'"
  else
    log "headscale: tailscale up failed (see /tmp/tailscale-up.log); engine continues over public HTTPS, runtime heal will retry"
  fi
}
headscale_autojoin
unset HS_PREAUTH_KEY HS_LOGIN_SERVER

# Provisioning-readiness breadcrumb: ONE line naming what this first boot staged, so an
# operator sees OVA parity at a glance (the OVA's equivalent is the firstboot progress
# log). States only - the secret VALUE is never logged.
provision_summary() {
  local secret_state="unset" caido_state="absent" home="${HOME:-}"
  [[ -n "${VACTI_ENGINE_SHARED_SECRET:-}" ]] && secret_state="enabled"
  [[ -n "$home" ]] || home="$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6 || true)"
  [[ -x "${home:-/root}/caido/caido-cli" ]] && caido_state="present"
  log "provisioning: engine-shared-secret=${secret_state} tailscaled=${TAILSCALED_STATE} caido-cli=${caido_state} (tailnet join + Caido login run inside the engine from engine-config)"
  if [[ "$secret_state" == "unset" ]]; then
    log "provisioning: WARNING no engine-shared-secret - if this control plane gates engine traffic at the edge, heartbeat/config will 401. An engine.env persisted before this fix lacks it: re-enroll with a fresh VACTI_ENROLL_TOKEN on an empty state volume, or pass -e VACTI_ENGINE_SHARED_SECRET."
  fi
}
provision_summary

# If the caller passed an explicit command, honour it; otherwise run the engine
# the same way the systemd unit does (node dist/runner/cli.js from WorkingDirectory).
cd "$APP"
if [[ "$#" -gt 0 ]]; then
  exec "$@"
fi
log "starting vacti-engine runner"
exec /usr/bin/node "${APP}/dist/runner/cli.js"
