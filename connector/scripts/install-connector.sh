#!/usr/bin/env bash
#
# install-connector.sh - install (or remove) the vacti connector on Linux/macOS.
#
# The connector is the only vacti component that runs inside a customer network
# (see ../cmd/connector/main.go). This script fetches the signed release binary
# for the host, enrols it once with the dashboard-issued token, and registers it
# as a managed service (systemd on Linux, a launchd LaunchDaemon on macOS) so it
# reconnects on boot. Re-running it is safe: it converges the install instead of
# duplicating it.
#
# USAGE
#   install-connector.sh --token <install-id> --api-url <https://cp.example>
#                        [--cidrs <a.b.c.0/24,...>] [--version X.Y.Z]
#                        [--repo owner/name]
#   install-connector.sh --uninstall
#
#   Typical one-liner (needs root for the service + /usr/local/bin):
#     curl -fsSL <release>/install-connector.sh | sudo bash -s -- \
#       --token <install-id> --api-url https://cp.example
#
# FLAGS
#   --token    <id>     dashboard enrollment id (a single-use install token).
#   --api-url  <url>    control-plane base URL the connector enrols against.
#   --cidrs    <list>   comma-separated CIDRs this connector is expected to reach;
#                       recorded for the operator. The authoritative reach is the
#                       per-session grant the control plane signs, not this value.
#   --version  <ver>    connector release to install (default: latest connector-v*).
#   --repo     <o/n>    GitHub repo to fetch releases from (default below).
#   --binary   <path>   install this local binary instead of downloading one
#                       (air-gapped installs; also used by the test harness).
#   --dry-run           print what would happen; touch nothing.
#   --uninstall         stop + remove the service, binary and state, then exit.
#   -h | --help         this help.
#
# ENVIRONMENT (advanced / testing seams)
#   VACTI_CONNECTOR_PREFIX        path prefix for every install location (sandbox
#                                 install: skips root + service activation, still
#                                 writes files and enrols with the given binary).
#   VACTI_CONNECTOR_BINARY        same as --binary.
#   VACTI_CONNECTOR_RELEASE_BASE  override the release asset base URL.
#
# Exit status: 0 success, non-zero on any failure (set -euo pipefail throughout).

# This is a bash script. Piped into plain `sh` (dash on Debian/Ubuntu) it would
# die on `set -o pipefail` with a cryptic message, so say what to do instead.
if [ -z "${BASH_VERSION:-}" ]; then
  echo "error: install-connector.sh needs bash; pipe it into 'sudo bash -s --' (not 'sh')" >&2
  exit 2
fi

set -euo pipefail

# ---------------------------------------------------------------------------- #
# constants + globals
# ---------------------------------------------------------------------------- #

readonly SERVICE_NAME="vacti-connector"
readonly LAUNCHD_LABEL="id.vacti.connector"
readonly BIN_NAME="vacti-connector"
readonly DEFAULT_REPO="anggipradana/vacti-distro"

PREFIX="${VACTI_CONNECTOR_PREFIX:-}"
TOKEN=""
API_URL=""
CIDRS=""
VERSION=""
REPO="$DEFAULT_REPO"
LOCAL_BINARY="${VACTI_CONNECTOR_BINARY:-}"
RELEASE_BASE="${VACTI_CONNECTOR_RELEASE_BASE:-}"
DO_UNINSTALL=0
DRY_RUN=0

# Set once platform is detected.
OS=""          # linux | darwin
ARCH=""        # amd64 | arm64
BIN_DIR=""
STATE_DIR=""
UNIT_PATH=""   # systemd unit (linux) or launchd plist (darwin)
LOG_PATH=""    # darwin only

# SANDBOX is on when a prefix is set: redirect paths, skip root + service control.
SANDBOX=0
[ -n "$PREFIX" ] && SANDBOX=1

# ---------------------------------------------------------------------------- #
# small helpers
# ---------------------------------------------------------------------------- #

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# run_priv executes a privileged command, or just prints it in sandbox/dry-run.
run_priv() {
  if [ "$SANDBOX" -eq 1 ] || [ "$DRY_RUN" -eq 1 ]; then
    printf '    [skip] %s\n' "$*"
    return 0
  fi
  "$@"
}

usage() {
  # When piped (curl ... | bash -s -- --help) $0 is "bash", not this file, so the
  # header comment cannot be re-read; print a compact usage instead.
  if [ -f "$0" ] && grep -q 'install-connector.sh' "$0" 2>/dev/null; then
    sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; s/^#$//' | sed '$d'
  else
    cat <<'EOF'
install-connector.sh --token <install-id> --api-url <https://cp.example>
                     [--cidrs <list>] [--version X.Y.Z] [--repo owner/name]
                     [--binary <path>] [--dry-run]
install-connector.sh --uninstall
Env: VACTI_CONNECTOR_RELEASE_BASE (mirror base URL), VACTI_CONNECTOR_BINARY.
EOF
  fi
}

# ---------------------------------------------------------------------------- #
# argument parsing
# ---------------------------------------------------------------------------- #

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --token)     TOKEN="${2:?--token needs a value}"; shift 2 ;;
      --token=*)   TOKEN="${1#*=}"; shift ;;
      --api-url)   API_URL="${2:?--api-url needs a value}"; shift 2 ;;
      --api-url=*) API_URL="${1#*=}"; shift ;;
      --cidrs)     CIDRS="${2:?--cidrs needs a value}"; shift 2 ;;
      --cidrs=*)   CIDRS="${1#*=}"; shift ;;
      --version)   VERSION="${2:?--version needs a value}"; shift 2 ;;
      --version=*) VERSION="${1#*=}"; shift ;;
      --repo)      REPO="${2:?--repo needs a value}"; shift 2 ;;
      --repo=*)    REPO="${1#*=}"; shift ;;
      --binary)    LOCAL_BINARY="${2:?--binary needs a value}"; shift 2 ;;
      --binary=*)  LOCAL_BINARY="${1#*=}"; shift ;;
      --dry-run)   DRY_RUN=1; shift ;;
      --uninstall) DO_UNINSTALL=1; shift ;;
      -h|--help)   usage; exit 0 ;;
      *)           die "unknown argument: $1 (try --help)" ;;
    esac
  done
}

# ---------------------------------------------------------------------------- #
# platform detection + path layout
# ---------------------------------------------------------------------------- #

detect_platform() {
  local s m
  s="$(uname -s)"
  m="$(uname -m)"
  case "$s" in
    Linux)  OS="linux" ;;
    Darwin) OS="darwin" ;;
    *)      die "unsupported operating system: $s (supported: Linux, macOS)" ;;
  esac
  case "$m" in
    x86_64|amd64)        ARCH="amd64" ;;
    aarch64|arm64)       ARCH="arm64" ;;
    *) die "unsupported CPU architecture: $m (supported: x86_64/amd64, aarch64/arm64)" ;;
  esac
}

compute_paths() {
  BIN_DIR="${PREFIX}/usr/local/bin"
  if [ "$OS" = "linux" ]; then
    STATE_DIR="${PREFIX}/var/lib/connector"
    UNIT_PATH="${PREFIX}/etc/systemd/system/${SERVICE_NAME}.service"
  else
    STATE_DIR="${PREFIX}/Library/Application Support/vacti-connector"
    UNIT_PATH="${PREFIX}/Library/LaunchDaemons/${LAUNCHD_LABEL}.plist"
    LOG_PATH="${PREFIX}/var/log/vacti-connector.log"
  fi
}

require_root_if_needed() {
  if [ "$SANDBOX" -eq 1 ] || [ "$DRY_RUN" -eq 1 ]; then
    return 0
  fi
  if [ "$(id -u)" -ne 0 ]; then
    die "must run as root (installs to ${BIN_DIR} and registers a system service); re-run with sudo"
  fi
}

# require_service_manager runs BEFORE enrollment: the install token is single-use,
# so failing on a missing systemd/launchd only after enrolling would burn it.
require_service_manager() {
  if [ "$SANDBOX" -eq 1 ] || [ "$DRY_RUN" -eq 1 ]; then
    return 0
  fi
  if [ "$OS" = "linux" ]; then
    if ! command -v systemctl >/dev/null 2>&1 || [ ! -d /run/systemd/system ]; then
      die "systemd is not running on this host (plain container, WSL without systemd, Alpine/OpenRC...). Use the Docker image or run the binary manually; see the connector README. Your install token was NOT used."
    fi
  else
    command -v launchctl >/dev/null 2>&1 || die "launchctl not found; cannot register the LaunchDaemon"
  fi
}

# ---------------------------------------------------------------------------- #
# download + verify
# ---------------------------------------------------------------------------- #

have() { command -v "$1" >/dev/null 2>&1; }

fetch() {
  # fetch <url> <dest>
  local url="$1" dest="$2"
  if have curl; then
    curl -fsSL --retry 3 -o "$dest" "$url"
  elif have wget; then
    wget -q -O "$dest" "$url"
  else
    die "need curl or wget to download the connector"
  fi
}

sha256_of() {
  # prints the hex digest of a file, portably
  if have sha256sum; then
    sha256sum "$1" | awk '{print $1}'
  elif have shasum; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    die "need sha256sum or shasum to verify the download"
  fi
}

resolve_version() {
  # Resolve the latest connector-v* tag when no --version was given.
  [ -n "$VERSION" ] && return 0
  [ -n "$LOCAL_BINARY" ] && { VERSION="local"; return 0; }
  log "resolving latest connector release from ${REPO}"
  # per_page=100: frequent images-v* releases push connector-v* off the default
  # 30-entry first page, after which no connector release would be found.
  local api="https://api.github.com/repos/${REPO}/releases?per_page=100"
  local tmp; tmp="$(mktemp)"
  fetch "$api" "$tmp" || die "could not query GitHub releases for ${REPO}"
  # First tag_name that starts with connector-v, newest first.
  VERSION="$(grep -o '"tag_name"[ ]*:[ ]*"connector-v[^"]*"' "$tmp" \
    | head -n1 | sed -E 's/.*"connector-v([^"]*)".*/\1/')"
  rm -f "$tmp"
  [ -n "$VERSION" ] || die "no connector-v* release found in ${REPO}"
  log "latest connector release is ${VERSION}"
}

# acquire_binary leaves the connector binary at $1 (executable).
acquire_binary() {
  local dest="$1"

  # Dry run must never touch an existing install (it used to truncate the live
  # binary to 0 bytes via `: > $dest`).
  if [ "$DRY_RUN" -eq 1 ]; then
    if [ -n "$LOCAL_BINARY" ]; then
      log "[dry-run] would install local binary ${LOCAL_BINARY} to ${dest}"
    else
      log "[dry-run] would download vacti-connector ${VERSION} for ${OS}/${ARCH} to ${dest}"
    fi
    return 0
  fi

  if [ -n "$LOCAL_BINARY" ]; then
    [ -f "$LOCAL_BINARY" ] || die "--binary ${LOCAL_BINARY} does not exist"
    log "using local binary ${LOCAL_BINARY}"
    place_binary "$LOCAL_BINARY" "$dest"
    return 0
  fi

  local base asset work
  base="${RELEASE_BASE:-https://github.com/${REPO}/releases/download/connector-v${VERSION}}"
  asset="vacti-connector_${VERSION}_${OS}_${ARCH}.tar.gz"
  work="$(mktemp -d)"
  log "downloading ${asset}"
  fetch "${base}/${asset}" "${work}/${asset}"
  log "downloading SHA256SUMS"
  fetch "${base}/SHA256SUMS" "${work}/SHA256SUMS"

  local want got
  want="$(grep -E "[ *]${asset}\$" "${work}/SHA256SUMS" | awk '{print $1}' | head -n1)"
  [ -n "$want" ] || die "SHA256SUMS has no entry for ${asset}"
  got="$(sha256_of "${work}/${asset}")"
  [ "$want" = "$got" ] || die "checksum mismatch for ${asset} (want ${want}, got ${got})"
  log "checksum verified"

  tar -C "$work" -xzf "${work}/${asset}"
  [ -f "${work}/${BIN_NAME}" ] || die "archive did not contain ${BIN_NAME}"
  place_binary "${work}/${BIN_NAME}" "$dest"
  rm -rf "$work"
}

# place_binary copies $1 next to $2 then renames it into place. A rename works
# even while the old binary is running (a plain cp onto it fails with "Text file
# busy"), so re-running the installer on a live host upgrades in place.
place_binary() {
  local src="$1" dest="$2"
  cp "$src" "${dest}.new"
  chmod 0755 "${dest}.new"
  mv -f "${dest}.new" "$dest"
}

# ---------------------------------------------------------------------------- #
# service unit rendering
# ---------------------------------------------------------------------------- #

render_systemd_unit() {
  # Written to $UNIT_PATH. The running service needs only the state dir: the
  # token and relay URL live inside state.json after enrollment.
  cat <<EOF
[Unit]
Description=Vacti connector (outbound-only in-network agent)
Documentation=https://github.com/${REPO}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN_DIR}/${BIN_NAME}
Environment=VACTI_CONNECTOR_STATE=/var/lib/connector
Restart=always
RestartSec=5
# Hardening: the connector makes only outbound connections and persists state to
# one directory; it never needs to write elsewhere or gain privileges.
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/var/lib/connector

[Install]
WantedBy=multi-user.target
EOF
}

render_launchd_plist() {
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LAUNCHD_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${BIN_DIR}/${BIN_NAME}</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>VACTI_CONNECTOR_STATE</key>
        <string>/Library/Application Support/vacti-connector</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/var/log/vacti-connector.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/vacti-connector.log</string>
</dict>
</plist>
EOF
}

write_unit() {
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] would write service definition ${UNIT_PATH}"
    return 0
  fi
  mkdir -p "$(dirname "$UNIT_PATH")"
  if [ "$OS" = "linux" ]; then
    render_systemd_unit > "$UNIT_PATH"
  else
    render_launchd_plist > "$UNIT_PATH"
    mkdir -p "$(dirname "$LOG_PATH")"
  fi
  log "wrote service definition ${UNIT_PATH}"
}

# ---------------------------------------------------------------------------- #
# enrollment
# ---------------------------------------------------------------------------- #

# preflight_cp_reachable fails fast on the single most common initial-enrollment
# problem: the host cannot reach the control-plane API at all (wrong URL, DNS,
# firewall, no egress). A liveness probe of ${API_URL}/api/health is unauthenticated
# and cheap. On an interactive run we let the operator override after the warning;
# piped into `sudo bash` (no TTY) we warn loudly and continue so an automated
# install is not wedged, but the cause is now on screen instead of buried in logs.
preflight_cp_reachable() {
  [ -n "$API_URL" ] || return 0
  if [ "$SANDBOX" -eq 1 ] || [ "$DRY_RUN" -eq 1 ]; then
    return 0
  fi
  have curl || return 0  # fetch() falls back to wget; skip the probe rather than block.
  local health="${API_URL%/}/api/health"
  if curl -sfI --max-time 5 "$health" >/dev/null 2>&1; then
    log "control-plane reachable at ${health}"
    return 0
  fi
  warn "cannot reach the control-plane at ${health}. Check network / DNS / firewall / the --api-url value."
  if [ -t 0 ]; then
    printf 'Proceed anyway? [y/N] ' >&2
    local ans=""
    read -r ans || ans=""
    case "$ans" in
      y|Y|yes|YES) log "proceeding despite unreachable control-plane (operator override)" ;;
      *)           die "aborted: control-plane unreachable at ${health}" ;;
    esac
  else
    warn "no TTY to confirm; continuing, but enrollment will fail if ${API_URL} stays unreachable."
  fi
}

enroll_once() {
  # Runs the connector once with the install token so it bootstraps state.json,
  # then stops it. Skipped when an identity already exists (the single-use token
  # would be rejected on a second use) or in a dry run.
  local bin="${BIN_DIR}/${BIN_NAME}"
  local state_json="${STATE_DIR}/state.json"

  if [ -f "$state_json" ]; then
    log "existing identity found at ${state_json}; skipping enrollment"
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] would enrol with the supplied token against ${API_URL}"
    return 0
  fi
  [ -n "$TOKEN" ]   || die "no identity yet and --token was not supplied"
  [ -n "$API_URL" ] || die "no identity yet and --api-url was not supplied"

  mkdir -p "$STATE_DIR"
  log "enrolling connector (one-time) against ${API_URL}"

  # Enrollment writes state.json then the process stays up talking to the relay;
  # we wait for state.json then stop it. A bad token makes it exit early with no
  # state file, which we detect as a failure.
  local pid rc=1 enroll_log
  enroll_log="$(mktemp)"
  VACTI_INSTALL_ID="$TOKEN" \
  VACTI_API_URL="$API_URL" \
  VACTI_CONNECTOR_STATE="$STATE_DIR" \
  VACTI_CONNECTOR_CIDRS="$CIDRS" \
    "$bin" >"$enroll_log" 2>&1 &
  pid=$!

  local waited=0
  while [ "$waited" -lt 60 ]; do
    if [ -f "$state_json" ]; then rc=0; break; fi
    if ! kill -0 "$pid" 2>/dev/null; then break; fi
    sleep 1
    waited=$((waited + 1))
  done

  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi

  if [ "$rc" -ne 0 ]; then
    # Surface the connector's own reason (e.g. "bootstrap rejected (HTTP 404)",
    # "invalid format") instead of a generic message.
    warn "connector output:"
    sed 's/^/    /' "$enroll_log" >&2 || true
    rm -f "$enroll_log"
    die "enrollment failed: no identity was written (check the token and --api-url)"
  fi
  rm -f "$enroll_log"
  log "enrollment succeeded"
}

# ---------------------------------------------------------------------------- #
# service activation + status
# ---------------------------------------------------------------------------- #

activate_service() {
  if [ "$OS" = "linux" ]; then
    run_priv systemctl daemon-reload
    run_priv systemctl enable "${SERVICE_NAME}.service"
    # restart (not just --now) so a re-run actually picks up the new binary/unit.
    run_priv systemctl restart "${SERVICE_NAME}.service"
  else
    # bootout first so a re-run reloads a changed plist (ignore "not loaded").
    if [ "$SANDBOX" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
      launchctl bootout "system/${LAUNCHD_LABEL}" 2>/dev/null || true
    fi
    run_priv launchctl bootstrap system "$UNIT_PATH"
    run_priv launchctl enable "system/${LAUNCHD_LABEL}"
  fi
}

print_status() {
  if [ "$SANDBOX" -eq 1 ] || [ "$DRY_RUN" -eq 1 ]; then
    log "sandbox/dry-run: skipping live status check"
    return 0
  fi
  if [ "$OS" = "linux" ]; then
    # Give a slow-starting unit a moment before judging it, so a healthy-but-slow boot is not reported as a failure.
    sleep 10
    if systemctl is-active --quiet "${SERVICE_NAME}.service"; then
      log "connector service is ACTIVE"
    else
      warn "connector service failed to start. Debug with: sudo journalctl -u ${SERVICE_NAME}.service -n 50"
      warn "recent logs:"
      journalctl -u "${SERVICE_NAME}.service" -n 15 --no-pager 2>/dev/null || true
    fi
  else
    if launchctl print "system/${LAUNCHD_LABEL}" >/dev/null 2>&1; then
      log "connector LaunchDaemon is LOADED"
    else
      warn "connector LaunchDaemon did not load; check ${LOG_PATH}"
    fi
  fi
}

# ---------------------------------------------------------------------------- #
# uninstall
# ---------------------------------------------------------------------------- #

do_uninstall() {
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] would stop the service and remove ${UNIT_PATH}, ${BIN_DIR}/${BIN_NAME} and ${STATE_DIR}"
    return 0
  fi
  log "uninstalling vacti connector"
  if [ "$OS" = "linux" ]; then
    if [ "$SANDBOX" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
      systemctl disable --now "${SERVICE_NAME}.service" 2>/dev/null || true
    else
      printf '    [skip] systemctl disable --now %s.service\n' "$SERVICE_NAME"
    fi
    rm -f "$UNIT_PATH"
    run_priv systemctl daemon-reload
  else
    if [ "$SANDBOX" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
      launchctl bootout "system/${LAUNCHD_LABEL}" 2>/dev/null || true
    else
      printf '    [skip] launchctl bootout system/%s\n' "$LAUNCHD_LABEL"
    fi
    rm -f "$UNIT_PATH"
  fi
  rm -f "${BIN_DIR}/${BIN_NAME}"
  rm -rf "$STATE_DIR"
  log "removed service, binary and state"
}

# ---------------------------------------------------------------------------- #
# main
# ---------------------------------------------------------------------------- #

main() {
  parse_args "$@"
  detect_platform
  compute_paths

  if [ "$DO_UNINSTALL" -eq 1 ]; then
    require_root_if_needed
    do_uninstall
    return 0
  fi

  # An install needs either a token to enrol with or an existing identity.
  if [ ! -f "${STATE_DIR}/state.json" ] && [ -z "$TOKEN" ] && [ "$DRY_RUN" -eq 0 ]; then
    die "--token is required for a first install (or pass --uninstall)"
  fi

  require_root_if_needed
  require_service_manager

  log "installing vacti connector ${VERSION:-latest} for ${OS}/${ARCH}"
  [ -n "$CIDRS" ] && log "declared reach (informational): ${CIDRS}"

  resolve_version
  [ "$DRY_RUN" -eq 1 ] || mkdir -p "$BIN_DIR"
  acquire_binary "${BIN_DIR}/${BIN_NAME}"
  [ "$DRY_RUN" -eq 1 ] || log "installed binary at ${BIN_DIR}/${BIN_NAME}"

  [ "$DRY_RUN" -eq 1 ] || mkdir -p "$STATE_DIR"
  preflight_cp_reachable
  enroll_once
  write_unit
  activate_service
  print_status

  log "done"
}

# Test-only seam: run just the control-plane preflight and exit, with no root,
# platform detection, download or service control. Used by install-connector.test.sh
# to exercise reachability detection deterministically (with a stubbed curl). Not
# part of the public CLI.
if [ "${1:-}" = "__preflight_only" ]; then
  shift
  parse_args "$@"
  preflight_cp_reachable
  exit 0
fi

main "$@"
