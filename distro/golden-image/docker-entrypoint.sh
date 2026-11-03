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
[[ -n "${VACTI_TOKEN:-}" ]] || die "$(_t err_no_engine_token)"
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
CAIDO_VERSION="${VACTI_CAIDO_VERSION:-v0.57.0}"
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
  command -v curl >/dev/null 2>&1 || { log "caido self-heal: curl unavailable, skipping (evidence degrades to the render)"; return 0; }

  local arch caido_arch
  arch="$(uname -m 2>/dev/null || echo unknown)"
  case "$arch" in
    x86_64|amd64)   caido_arch="x86_64" ;;
    aarch64|arm64)  caido_arch="aarch64" ;;
    *)              caido_arch="x86_64"; log "caido self-heal: unknown arch ${arch}, trying x86_64" ;;
  esac
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
    log "caido self-heal: ready (${caido_bin})"
    return 0
  fi
  log "caido self-heal: extraction failed (fetched URL=${url}, http=${http}), continuing with degraded capability"
  rm -rf "$tmp" 2>/dev/null || true
  return 0
}
heal_caido

# If the caller passed an explicit command, honour it; otherwise run the engine
# the same way the systemd unit does (node dist/runner/cli.js from WorkingDirectory).
cd "$APP"
if [[ "$#" -gt 0 ]]; then
  exec "$@"
fi
log "starting vacti-engine runner"
exec /usr/bin/node "${APP}/dist/runner/cli.js"
