#!/usr/bin/env bash
#
# install-connector.test.sh - prove connector/scripts/install-connector.sh installs,
# re-installs idempotently, and uninstalls cleanly, on both the Linux (systemd) and
# macOS (launchd) layouts, without touching the real system.
#
# It drives the installer in sandbox mode (VACTI_CONNECTOR_PREFIX points every path
# at a temp tree; service activation and the root check are skipped) with a STUB
# binary that simulates enrollment by writing state.json. The macOS layout is
# exercised by shimming `uname` so the same host can assert the launchd plist.
#
# Run: bash connector/scripts/install-connector.test.sh
set -euo pipefail

MOD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${MOD_ROOT}/scripts/install-connector.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: missing $SCRIPT"; exit 1; }

PASS=0
ok()  { echo "  ok: $*"; PASS=$((PASS + 1)); }
die() { echo "FAIL: $*" >&2; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# --- a stub connector that "enrols" by writing state.json then idles ------------
STUB="${WORK}/vacti-connector-stub"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
dir="${VACTI_CONNECTOR_STATE:?stub: VACTI_CONNECTOR_STATE unset}"
mkdir -p "$dir"
cat > "${dir}/state.json" <<J
{"connectorId":"test-id","token":"test-token","relayUrl":"wss://relay.example/","grantKey":"AAAA","install":"deadbeef"}
J
# Mimic the real connector staying up after enrollment; the installer stops us.
sleep 30
EOF
chmod +x "$STUB"

run_install() { # run_install <prefix> [extra uname-shim dir] <args...>
  local prefix="$1"; shift
  local shim="$1"; shift
  local path="$PATH"
  [ -n "$shim" ] && path="${shim}:${PATH}"
  VACTI_CONNECTOR_PREFIX="$prefix" PATH="$path" \
    bash "$SCRIPT" --binary "$STUB" "$@"
}

# ============================================================================= #
# 0. static checks
# ============================================================================= #
bash -n "$SCRIPT" || die "install-connector.sh has a syntax error"
ok "bash -n install-connector.sh"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x -S warning "$SCRIPT" "$0" || die "shellcheck reported issues"
  ok "shellcheck clean"
else
  echo "  note: shellcheck not installed; skipping lint"
fi

# ============================================================================= #
# 1. Linux (systemd) install
# ============================================================================= #
LPREFIX="${WORK}/linux"; mkdir -p "$LPREFIX"
run_install "$LPREFIX" "" \
  --token test-token --api-url https://cp.example --cidrs 10.0.0.0/24 >/dev/null \
  || die "linux install returned non-zero"

BIN="${LPREFIX}/usr/local/bin/vacti-connector"
UNIT="${LPREFIX}/etc/systemd/system/vacti-connector.service"
STATE="${LPREFIX}/var/lib/connector/state.json"

[ -x "$BIN" ]    || die "linux: binary not installed at $BIN"
[ -f "$UNIT" ]   || die "linux: systemd unit not written at $UNIT"
[ -f "$STATE" ]  || die "linux: enrollment did not write state.json"
ok "linux: binary, unit and state.json present"

grep -q "^ExecStart=${LPREFIX}/usr/local/bin/vacti-connector\$" "$UNIT" \
  || die "linux: unit ExecStart wrong"
grep -q '^Environment=VACTI_CONNECTOR_STATE=/var/lib/connector$' "$UNIT" \
  || die "linux: unit missing state env"
grep -q '^Restart=always$' "$UNIT"          || die "linux: unit missing Restart=always"
grep -q '^NoNewPrivileges=true$' "$UNIT"     || die "linux: unit missing hardening"
grep -q '^WantedBy=multi-user.target$' "$UNIT" || die "linux: unit missing [Install] target"
ok "linux: systemd unit content correct"

# ============================================================================= #
# 2. idempotent re-run (enrollment must be skipped, files stable)
# ============================================================================= #
UNIT_BEFORE="$(cat "$UNIT")"
STATE_BEFORE="$(cat "$STATE")"
out="$(run_install "$LPREFIX" "" --token test-token --api-url https://cp.example 2>&1)" \
  || die "linux: idempotent re-run returned non-zero"
echo "$out" | grep -qi "skipping enrollment" \
  || die "linux: re-run should skip enrollment when identity exists"
[ "$(cat "$UNIT")"  = "$UNIT_BEFORE" ]  || die "linux: unit changed on re-run"
[ "$(cat "$STATE")" = "$STATE_BEFORE" ] || die "linux: state.json changed on re-run"
[ -x "$BIN" ] || die "linux: binary missing after re-run"
ok "linux: re-run is idempotent and skips enrollment"

# ============================================================================= #
# 3. uninstall removes everything
# ============================================================================= #
run_install "$LPREFIX" "" --uninstall >/dev/null || die "linux: uninstall returned non-zero"
[ ! -e "$BIN" ]  || die "linux: binary survived uninstall"
[ ! -e "$UNIT" ] || die "linux: unit survived uninstall"
[ ! -e "${LPREFIX}/var/lib/connector" ] || die "linux: state dir survived uninstall"
ok "linux: uninstall removed binary, unit and state"
# uninstall again must not error (idempotent)
run_install "$LPREFIX" "" --uninstall >/dev/null || die "linux: second uninstall errored"
ok "linux: repeat uninstall is a no-op"

# ============================================================================= #
# 4. macOS (launchd) install via a uname shim
# ============================================================================= #
SHIM="${WORK}/shim-darwin"; mkdir -p "$SHIM"
cat > "${SHIM}/uname" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -s) echo Darwin ;;
  -m) echo arm64 ;;
  *)  echo Darwin ;;
esac
EOF
chmod +x "${SHIM}/uname"

MPREFIX="${WORK}/darwin"; mkdir -p "$MPREFIX"
run_install "$MPREFIX" "$SHIM" \
  --token test-token --api-url https://cp.example >/dev/null \
  || die "macOS install returned non-zero"

PLIST="${MPREFIX}/Library/LaunchDaemons/id.vacti.connector.plist"
MBIN="${MPREFIX}/usr/local/bin/vacti-connector"
MSTATE="${MPREFIX}/Library/Application Support/vacti-connector/state.json"

[ -x "$MBIN" ]   || die "macOS: binary not installed"
[ -f "$PLIST" ]  || die "macOS: launchd plist not written"
[ -f "$MSTATE" ] || die "macOS: enrollment did not write state.json"
grep -q '<string>id.vacti.connector</string>' "$PLIST" || die "macOS: plist label wrong"
grep -q "<string>${MPREFIX}/usr/local/bin/vacti-connector</string>" "$PLIST" \
  || die "macOS: plist ProgramArguments wrong"
grep -q '<key>RunAtLoad</key>' "$PLIST"  || die "macOS: plist missing RunAtLoad"
grep -q '<key>KeepAlive</key>' "$PLIST"  || die "macOS: plist missing KeepAlive"
ok "macOS: plist, binary and state.json correct"

run_install "$MPREFIX" "$SHIM" --uninstall >/dev/null || die "macOS: uninstall returned non-zero"
[ ! -e "$PLIST" ] || die "macOS: plist survived uninstall"
ok "macOS: uninstall removed the LaunchDaemon"

# ============================================================================= #
# 5. unsupported platform is rejected
# ============================================================================= #
SHIM_BAD="${WORK}/shim-bad"; mkdir -p "$SHIM_BAD"
cat > "${SHIM_BAD}/uname" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -s) echo Plan9 ;;
  -m) echo sparc ;;
  *)  echo Plan9 ;;
esac
EOF
chmod +x "${SHIM_BAD}/uname"
if run_install "${WORK}/bad" "$SHIM_BAD" --token t --api-url https://cp.example >/dev/null 2>&1; then
  die "unsupported OS should have been rejected"
fi
ok "unsupported platform is rejected"

# ============================================================================= #
# 6. control-plane preflight (initial-enrollment reachability check)
# ============================================================================= #
# A curl shim lets us simulate a reachable vs unreachable control-plane without a
# network. The preflight runs via the __preflight_only test seam (no root/service).
CURL_OK="${WORK}/curl-ok"; mkdir -p "$CURL_OK"
cat > "${CURL_OK}/curl" <<'EOF'
#!/usr/bin/env bash
# Reachable: succeed on the health probe, pass through anything else.
exit 0
EOF
chmod +x "${CURL_OK}/curl"

CURL_BAD="${WORK}/curl-bad"; mkdir -p "$CURL_BAD"
cat > "${CURL_BAD}/curl" <<'EOF'
#!/usr/bin/env bash
# Unreachable: fail like curl -f against a dead host / 404.
exit 22
EOF
chmod +x "${CURL_BAD}/curl"

# Reachable CP -> preflight reports reachable and exits 0.
out="$(PATH="${CURL_OK}:${PATH}" bash "$SCRIPT" __preflight_only \
  --api-url https://cp.example </dev/null 2>&1)" \
  || die "preflight: reachable CP should exit 0"
echo "$out" | grep -qi "control-plane reachable" \
  || die "preflight: reachable CP should log reachability"
ok "preflight: reachable control-plane passes"

# Unreachable CP, no TTY (piped-install case) -> warns about the unreachable CP and
# continues (so an automated install is not wedged), surfacing the cause.
out="$(PATH="${CURL_BAD}:${PATH}" bash "$SCRIPT" __preflight_only \
  --api-url https://cp.example </dev/null 2>&1)" \
  || die "preflight: unreachable CP without a TTY should continue (exit 0)"
echo "$out" | grep -qi "cannot reach the control-plane" \
  || die "preflight: unreachable CP must surface the reachability warning"
ok "preflight: unreachable control-plane is caught and surfaced"

# No --api-url -> preflight is a no-op (nothing to probe).
PATH="${CURL_BAD}:${PATH}" bash "$SCRIPT" __preflight_only </dev/null >/dev/null 2>&1 \
  || die "preflight: no --api-url should be a no-op (exit 0)"
ok "preflight: no --api-url is a no-op"

echo "PASS: install-connector.test.sh (${PASS} assertions)"
