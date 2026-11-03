#!/usr/bin/env bash
# s2-ova-headless-shortcode.sh - amd64/arm64 HEADLESS OVA + whiptail netsetup +
# short code, driven over the serial console with expect.
#
# Checkpoints (fail on first miss):
#   c1 headless OVA downloaded from HF
#   c2 OVA -> qcow2 converted
#   c3 VM boots (qemu up, serial PTY attached)
#   c4 netsetup whiptail prompt reached on the serial console
#   c5 CP URL + short code entered over serial
#   c6 mock CP received the exchange POST (200)
#   c7 mock CP served the engine .deb over apt with the EXCHANGED token
#   c8 mock CP received the enroll POST
#
# The engine install is additionally cross-checked from inside the guest journal
# when E2E_SSH_HOST is exported (optional; the CP-side assertions are primary).
set -euo pipefail
E2E_SCENARIO="s2"
# shellcheck source=test/e2e/lib/assert.sh
. "${E2E_LIB}/assert.sh"
# shellcheck source=test/e2e/lib/inject-input.sh disable=SC1091
. "${E2E_LIB}/inject-input.sh"

require_cmd curl qemu-img tar expect
VNC_PORT="${S2_VNC_PORT:-5902}"
PIDFILE="${E2E_WORK}/s2-qemu.pid"
PTY_LINK="${E2E_WORK}/s2-serial.pty"
SESSION_LOG="${E2E_WORK}/s2-serial-session.log"
EVID="${E2E_EVIDENCE}/scenario2"
mkdir -p "$EVID" "$E2E_WORK"
: >"$SESSION_LOG"

cleanup() {
  [[ -f "$PIDFILE" ]] && kill "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null || true
  rm -f "$PIDFILE" "$PTY_LINK"
}
trap cleanup EXIT

# c1: download headless OVA
ova="$(E2E_RELEASE="${E2E_RELEASE:-0.1.0}" E2E_ARCH="${E2E_ARCH:-amd64}" \
       bash "${E2E_LIB}/download-ova.sh" headless "${E2E_WORK}/ova")" || cp_fail "c1-download"
cp_pass "c1 headless OVA downloaded ($(basename "$ova"))"

# c2: convert
qcow2="${E2E_WORK}/s2-headless.qcow2"
bash "${E2E_LIB}/boot-vm.sh" convert "$ova" "$qcow2"
cp_pass "c2 qcow2 ready"

# c3: boot
bash "${E2E_LIB}/boot-vm.sh" boot "$qcow2" "$VNC_PORT" "$PTY_LINK" "$PIDFILE"
sleep 2
[[ -L "$PTY_LINK" || -e "$PTY_LINK" ]] || cp_fail "c3-boot" "no serial PTY attached"
cp_pass "c3 VM booting with serial PTY"

# c4+c5: drive whiptail over serial. mint the code first.
mock_mint "$PAIRING_CODE" 600
# expect_netsetup blocks until it has walked the prompts or times out.
if expect_netsetup "$PTY_LINK" "${GUEST_CP_URL_VM}" "$PAIRING_CODE" "$SESSION_LOG"; then
  cp_pass "c5 CP URL + short code entered over serial"
else
  cp_fail "c5-input" "expect could not drive the netsetup prompts (see ${SESSION_LOG})"
fi
assert_file_contains "$SESSION_LOG" "ontrol-plane" "c4 netsetup prompt reached on serial"

# give the guest time to exchange -> apt pull -> enroll
e2e_log "waiting for guest exchange/apt/enroll (up to 180s)"
state=""
for _ in $(seq 1 18); do
  sleep 10
  state="$(mock_state)"
  echo "$state" | grep -q '"kind": "enroll"' && break
done

assert_contains "$state" '"kind": "exchange"' "c6 exchange POST received by CP"
assert_contains "$state" '"result": 200'     "c6b exchange returned 200"
assert_contains "$state" '"is_deb": true'    "c7 engine .deb pulled over apt"
assert_contains "$state" '"kind": "enroll"'  "c8 enroll POST received by CP"

# optional in-guest journal cross-check
if [[ -n "${E2E_SSH_HOST:-}" ]] && command -v ssh >/dev/null 2>&1; then
  if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$E2E_SSH_HOST" \
       'journalctl -u vacti-engine-install.service --no-pager 2>/dev/null | tail -20' \
       >"${E2E_WORK}/s2-journal.txt" 2>/dev/null; then
    e2e_ok "captured in-guest install journal -> ${E2E_WORK}/s2-journal.txt"
  else
    e2e_warn "optional in-guest journal cross-check unavailable"
  fi
fi

e2e_ok "scenario 2 PASS"
