#!/usr/bin/env bash
# s1-ova-gui-shortcode.sh - amd64/arm64 GUI OVA + GTK4 kiosk + short code.
#
# Checkpoints (fail on first miss):
#   c1 OVA downloaded from HF
#   c2 OVA -> qcow2 converted
#   c3 VM boots (qemu up, VNC reachable)
#   c4 GUI kiosk window appears (VNC capture succeeds within 300s)
#   c5 CP URL + short code typed into the kiosk and submitted
#   c6 mock CP received the exchange POST (short code -> full token)
#   c7 mock CP served the engine .deb over apt with the EXCHANGED token
#   c8 mock CP received the enroll POST (engine handshake)
#
# Reuses run-e2e.sh exports: E2E_LIB, E2E_WORK, E2E_EVIDENCE, MOCK_* , PAIRING_CODE,
# GUEST_CP_URL_VM. Idempotent: reuses a cached OVA/qcow2 and always tears the VM down.
set -euo pipefail
E2E_SCENARIO="s1"
# shellcheck source=test/e2e/lib/assert.sh
. "${E2E_LIB}/assert.sh"
# shellcheck source=test/e2e/lib/download-ova.sh disable=SC1091
# shellcheck source=test/e2e/lib/boot-vm.sh disable=SC1091
# shellcheck source=test/e2e/lib/inject-input.sh disable=SC1091
. "${E2E_LIB}/inject-input.sh"

require_cmd curl qemu-img tar
VNC_PORT="${S1_VNC_PORT:-5901}"
PIDFILE="${E2E_WORK}/s1-qemu.pid"
PTY_LINK="${E2E_WORK}/s1-serial.pty"
EVID="${E2E_EVIDENCE}/scenario1"
mkdir -p "$EVID" "$E2E_WORK"

cleanup() {
  [[ -f "$PIDFILE" ]] && kill "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null || true
  rm -f "$PIDFILE" "$PTY_LINK"
}
trap cleanup EXIT

# c1: download
ova="$(E2E_RELEASE="${E2E_RELEASE:-0.1.0}" E2E_ARCH="${E2E_ARCH:-amd64}" \
       bash "${E2E_LIB}/download-ova.sh" gui "${E2E_WORK}/ova")" || cp_fail "c1-download"
cp_pass "c1 OVA downloaded ($(basename "$ova"))"

# c2: convert
qcow2="${E2E_WORK}/s1-gui.qcow2"
bash "${E2E_LIB}/boot-vm.sh" convert "$ova" "$qcow2"
cp_pass "c2 qcow2 ready"

# c3: boot
bash "${E2E_LIB}/boot-vm.sh" boot "$qcow2" "$VNC_PORT" "$PTY_LINK" "$PIDFILE"
sleep 2
[[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null \
  && cp_pass "c3 VM booting (qemu pid $(cat "$PIDFILE"))" \
  || cp_fail "c3-boot" "qemu not running"

# c4: GUI appears (poll screenshots up to 300s)
if vnc_wait_for_display "127.0.0.1::${VNC_PORT}" "$EVID" "scenario1-boot" 300; then
  cp_pass "c4 GUI kiosk display reachable over VNC"
else
  cp_fail "c4-gui" "no GUI display within 300s (see ${EVID})"
fi

# mint the short code the harness will type
mock_mint "$PAIRING_CODE" 600

# c5: type URL + code into the kiosk
vnc_type_kiosk "127.0.0.1::${VNC_PORT}" "${GUEST_CP_URL_VM}" "$PAIRING_CODE"
vnc_shot "127.0.0.1::${VNC_PORT}" "${EVID}/scenario1-after-submit.png"
cp_pass "c5 kiosk input submitted"

# give the guest time to exchange -> apt pull -> enroll
e2e_log "waiting for guest exchange/apt/enroll (up to 180s)"
state=""
for _ in $(seq 1 18); do
  sleep 10
  state="$(mock_state)"
  echo "$state" | grep -q '"kind": "enroll"' && break
done

# c6: exchange POST seen
assert_contains "$state" '"kind": "exchange"' "c6 exchange POST received by CP"
assert_contains "$state" '"result": 200'     "c6b exchange returned 200"

# c7: apt pull with exchanged token
assert_contains "$state" '"is_deb": true' "c7 engine .deb pulled over apt"

# c8: enroll POST seen
assert_contains "$state" '"kind": "enroll"' "c8 enroll POST received by CP"

e2e_ok "scenario 1 PASS"
