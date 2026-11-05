#!/usr/bin/env bash
# enroll-boot-contracts.sh - static contract test for the pre-enrollment boot chain.
#
# Guarantees the operator ALWAYS sees the activation kiosk again after any reboot
# that happens before enrollment completes (before /etc/vacti-engine/engine.env
# exists AND is populated). It lints the unit conditions + ordering and exercises
# the engine.env write/read predicates WITHOUT needing systemd or a running box, so
# it is safe in `ci/lint.sh` and as `bash distro/test/enroll-boot-contracts.sh`.
#
# Covers the audited reboot-mid-enrollment cases:
#   1 clean first boot            -> kiosk unit condition + LightDM gate
#   2 staged token, POST failed   -> firstboot re-runs while engine.env absent
#   4 kiosk crash budget          -> StartLimit* present + OnFailure fallback
#   5 partial engine.env write    -> atomic publish + content-aware predicates
#   8 firstboot failed            -> kiosk unit is independent of firstboot
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
ENR="${ROOT}/distro/enroll"
ACTIVATE_UNIT="${ENR}/activate/vacti-activate.service"
FALLBACK_UNIT="${ENR}/activate/vacti-activate-fallback.service"
ACTIVATE_SH="${ENR}/activate/vacti-activate"
FIRSTBOOT_UNIT="${ENR}/firstboot/vacti-firstboot.service"
FIRSTRUN_UNIT="${ROOT}/distro/live-build-config/config/includes.chroot/etc/systemd/system/vacti-firstrun.service"
FIRSTBOOT_SH="${ENR}/firstboot/vacti-firstboot"
GATE="${ROOT}/distro/branding/greeter/lightdm.service.d/10-vacti-gate.conf"

ENVPATH='/etc/vacti-engine/engine.env'
pass=0; fail=0
ok()   { printf 'PASS  %s\n' "$1"; pass=$((pass+1)); }
no()   { printf 'FAIL  %s\n' "$1"; fail=$((fail+1)); }
check(){ # description  test-command...
  local desc="$1"; shift
  if "$@"; then ok "$desc"; else no "$desc"; fi
}
# grep helper: file contains a line matching the ERE (ignoring leading whitespace).
has() { grep -Eq "$2" "$1" 2>/dev/null; }

echo "== files present =="
for f in "$ACTIVATE_UNIT" "$FALLBACK_UNIT" "$ACTIVATE_SH" "$FIRSTBOOT_UNIT" \
         "$FIRSTRUN_UNIT" "$FIRSTBOOT_SH" "$GATE"; do
  check "exists: ${f#$ROOT/}" test -f "$f"
done

echo "== case 1/2/8: both enroll service units are gated on engine.env absence =="
check "vacti-activate.service ConditionPathExists=!engine.env" \
  has "$ACTIVATE_UNIT" '^ConditionPathExists=!/etc/vacti-engine/engine\.env$'
check "vacti-firstboot.service ConditionPathExists=!engine.env" \
  has "$FIRSTBOOT_UNIT" '^ConditionPathExists=!/etc/vacti-engine/engine\.env$'
check "vacti-firstrun.service  ConditionPathExists=!engine.env" \
  has "$FIRSTRUN_UNIT" '^ConditionPathExists=!/etc/vacti-engine/engine\.env$'

echo "== case 1/4: kiosk owns tty1 before the greeter + fails open to a getty =="
check "vacti-activate.service Before=lightdm.service" \
  has "$ACTIVATE_UNIT" '^Before=lightdm\.service$'
check "vacti-activate.service Conflicts= or Before= getty@tty1" \
  has "$ACTIVATE_UNIT" '^(Conflicts|Before)=.*getty@tty1\.service'
check "vacti-activate.service OnFailure=fallback" \
  has "$ACTIVATE_UNIT" '^OnFailure=vacti-activate-fallback\.service$'
check "vacti-activate.service StartLimitBurst set (crash budget)" \
  has "$ACTIVATE_UNIT" '^StartLimitBurst=[0-9]+$'
check "vacti-activate.service StartLimitIntervalSec set" \
  has "$ACTIVATE_UNIT" '^StartLimitIntervalSec=[0-9]+$'
check "fallback getty only while unenrolled (ConditionPathExists=!engine.env)" \
  has "$FALLBACK_UNIT" '^ConditionPathExists=!/etc/vacti-engine/engine\.env$'

echo "== case 1/7: LightDM greeter is withheld until engine.env exists =="
check "10-vacti-gate.conf ConditionPathExists=engine.env" \
  has "$GATE" '^ConditionPathExists=/etc/vacti-engine/engine\.env$'
check "gate keys on the SAME engine.env path as the units" \
  has "$GATE" "ConditionPathExists=${ENVPATH}$"

echo "== case 8: firstboot failure cannot block the kiosk (no hard dep) =="
# vacti-activate.service must not Require/BindsTo/After the firstboot unit, so a
# permanently-failing firstboot still leaves the kiosk free to take a NEW token.
check "vacti-activate.service has no Requires=/BindsTo= on firstboot" \
  bash -c '! grep -Eq "^(Requires|BindsTo|Requisite)=.*vacti-first(boot|run)" "'"$ACTIVATE_UNIT"'"'

echo "== case 5: engine.env write is atomic (temp + rename), never partial =="
check "firstboot inline writer targets a temp file" \
  has "$FIRSTBOOT_SH" '\}[[:space:]]*>[[:space:]]*"\$ENV_TMP"'
check "firstboot publishes engine.env via atomic rename (mv -f)" \
  has "$FIRSTBOOT_SH" '^[[:space:]]*mv -f "\$ENV_TMP" "\$CFG_ENV"'
check "firstboot validates producer token before publishing (as VACTI_TOKEN)" \
  has "$FIRSTBOOT_SH" 'VACTI_TOKEN=\.\+'
# Regression-pin: the firstboot writer MUST emit the key name the engine's
# Zod schema reads (VACTI_TOKEN). The earlier VACTI_PRODUCER_TOKEN variant
# made the engine crash on startup under Type=notify so the appliance
# never heartbeated. Keep in lockstep with bootstrap-apt.sh.
check "firstboot writes VACTI_TOKEN (engine Zod key), not VACTI_PRODUCER_TOKEN" \
  bash -c '! grep -Eq "\"VACTI_PRODUCER_TOKEN\"|VACTI_PRODUCER_TOKEN=" "'"$FIRSTBOOT_SH"'"'
check "firstboot zero-byte backstop removes a partial engine.env" \
  has "$FIRSTBOOT_SH" 'if \[\[ ! -s "\$CFG_ENV" \]\]; then'
check "firstboot no longer writes the live engine.env path directly" \
  bash -c '! grep -Eq "\}[[:space:]]*>[[:space:]]*\"\\\$CFG_ENV\"" "'"$FIRSTBOOT_SH"'"'

echo "== case 5: content-aware enrolled predicate in both scripts =="
check "firstboot defines engine_env_ready()" \
  has "$FIRSTBOOT_SH" '^engine_env_ready\(\)'
check "vacti-activate defines engine_env_ready()" \
  has "$ACTIVATE_SH" '^engine_env_ready\(\)'
check "firstboot early-exit uses engine_env_ready (not bare -f)" \
  has "$FIRSTBOOT_SH" 'if engine_env_ready; then'
check "vacti-activate early-exit uses engine_env_ready (not bare -f)" \
  has "$ACTIVATE_SH" 'if engine_env_ready; then'

echo "== post-enroll reboot: firstboot enables the engine unit so it auto-starts =="
# On the second boot the firstboot/firstrun/install units are all
# ConditionPathExists=!engine.env (and firstboot is disabled on success), so the ONLY
# thing that can start vacti-engine.service is its own enablement symlink. firstboot must
# ENABLE the engine unit (live system, every channel) before it starts it, so the symlink
# is guaranteed on the enrolled image regardless of the .deb postinst build-chroot enable.
check "firstboot enables vacti-engine.service" \
  has "$FIRSTBOOT_SH" '^systemctl enable vacti-engine\.service'
check "firstboot enables the engine BEFORE disabling itself" \
  bash -c 'awk "/^systemctl enable vacti-engine\.service/{e=NR} /systemctl disable/{d=NR} END{exit !(e&&d&&e<d)}" "'"$FIRSTBOOT_SH"'"'

echo "== kiosk-stuck: enroll handoff is non-blocking + poll is content-aware =="
# Root cause (fat-OVA kiosk stuck on "Enrolling device..." after ENV_WRITTEN):
# stage_token_and_enroll used a BLOCKING `systemctl start` on the Type=oneshot
# firstboot unit, so it could not reach its engine.env poll until firstboot fully
# exited (past the engine.env write, into the slow `systemctl start vacti-engine`).
# The fix fires the unit with --no-block and polls the content-aware predicate.
check "stage_token_and_enroll starts firstboot with --no-block (non-blocking handoff)" \
  has "$ACTIVATE_SH" '^[[:space:]]*systemctl start --no-block "\$fb_unit"'
check "no BLOCKING plain 'systemctl start \"\$fb_unit\"' remains" \
  bash -c '! grep -Eq "systemctl start \"\\\$fb_unit\"" "'"$ACTIVATE_SH"'"'
check "enroll poll loop uses engine_env_ready, not bare -f" \
  has "$ACTIVATE_SH" '^[[:space:]]*engine_env_ready && break'
check "no bare -f \"\$CFG_ENV\" enrollment-complete check survives in the kiosk" \
  bash -c '! grep -Eq "\[\[ !? ?-f \"\\\$CFG_ENV\" \]\]" "'"$ACTIVATE_SH"'"'
# Consistency: the shell poll ceiling (150*2s=300s) must stay <= the Python kiosk
# subprocess timeout (360s) so the shell loop, not the subprocess timeout, decides.
check "shell poll ceiling (seq 1 150, sleep 2 = 300s) is present" \
  has "$ACTIVATE_SH" '^[[:space:]]*for _ in \$\(seq 1 150\); do'
check "kiosk subprocess __enroll timeout is 360s (>= shell 300s ceiling, with margin)" \
  has "${ENR}/activate/vacti-kiosk" 'timeout=360'

echo "== case 5: predicate behaviour (functional, the real engine_env_ready) =="
# Source the exact engine_env_ready() shipped in vacti-activate and exercise it
# against crafted engine.env files, so the test tracks the real predicate.
TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
CFG_ENV="${TMPD}/engine.env"
# Pull the function definition (def line through its closing brace) out of the script.
eval "$(sed -n '/^engine_env_ready() {$/,/^}$/p' "$ACTIVATE_SH")"

rm -f "$CFG_ENV"
if ! engine_env_ready; then ok "absent engine.env -> not ready"; else no "absent engine.env -> not ready"; fi
: > "$CFG_ENV"
if ! engine_env_ready; then ok "zero-byte engine.env -> not ready"; else no "zero-byte engine.env -> not ready"; fi
printf '\n   \n' > "$CFG_ENV"
if ! engine_env_ready; then ok "whitespace-only engine.env -> not ready"; else no "whitespace-only engine.env -> not ready"; fi
printf 'VACTI_URL=https://cp.example\nVACTI_TOKEN=abc123\n' > "$CFG_ENV"
if engine_env_ready; then ok "populated engine.env -> ready"; else no "populated engine.env -> ready"; fi

echo "== post-enroll handoff: land on a NETWORK panel, not the desktop login =="
# After enrollment the console must land on a NetworkManager settings surface
# (vacti-netpanel.service) BEFORE the LightDM desktop login, with a fall-through to
# the desktop and without weakening the engine.env gate.
NETPANEL_UNIT="${ENR}/activate/vacti-netpanel.service"
NETPANEL_HEADLESS_UNIT="${ENR}/activate/vacti-netpanel-headless.service"
NETPANEL_SH="${ENR}/activate/vacti-netpanel"
NETPANEL_DROPIN="${ROOT}/distro/branding/greeter/lightdm.service.d/15-vacti-netpanel.conf"

check "exists: ${NETPANEL_UNIT#$ROOT/}"          test -f "$NETPANEL_UNIT"
check "exists: ${NETPANEL_HEADLESS_UNIT#$ROOT/}" test -f "$NETPANEL_HEADLESS_UNIT"
check "exists: ${NETPANEL_SH#$ROOT/}"            test -f "$NETPANEL_SH"
check "exists: ${NETPANEL_DROPIN#$ROOT/}"        test -f "$NETPANEL_DROPIN"

echo "== netpanel unit owns tty1 post-enroll, before lightdm, fail-open to lightdm =="
# Opposite polarity to the pre-enroll kiosk: runs only AFTER engine.env exists.
check "vacti-netpanel.service runs only when enrolled (ConditionPathExists=engine.env, NOT negated)" \
  has "$NETPANEL_UNIT" '^ConditionPathExists=/etc/vacti-engine/engine\.env$'
check "vacti-netpanel.service is GUI-only (ConditionPathExists=/etc/lightdm)" \
  has "$NETPANEL_UNIT" '^ConditionPathExists=/etc/lightdm$'
check "vacti-netpanel.service honours the operator opt-out latch (!netpanel-optout)" \
  has "$NETPANEL_UNIT" '^ConditionPathExists=!/var/lib/vacti/netpanel-optout$'
check "vacti-netpanel.service Before=lightdm.service (owns tty1 first)" \
  has "$NETPANEL_UNIT" '^Before=lightdm\.service$'
check "vacti-netpanel.service Conflicts= or Before= getty@tty1" \
  has "$NETPANEL_UNIT" '^(Conflicts|Before)=.*getty@tty1\.service'
check "vacti-netpanel.service fails OPEN to the desktop login (OnFailure=lightdm.service)" \
  has "$NETPANEL_UNIT" '^OnFailure=lightdm\.service$'
check "vacti-netpanel.service drops the defer flag before lightdm checks it (ExecStartPre)" \
  has "$NETPANEL_UNIT" 'ExecStartPre=.*/run/vacti-netpanel\.active'
check "vacti-netpanel.service clears the defer flag on stop/crash (ExecStopPost)" \
  has "$NETPANEL_UNIT" '^ExecStopPost=.*rm -f /run/vacti-netpanel\.active'

echo "== lightdm defer drop-in is ADDITIVE and does NOT weaken the engine.env gate =="
check "15-vacti-netpanel.conf defers lightdm while the panel holds tty1 (!/run/vacti-netpanel.active)" \
  has "$NETPANEL_DROPIN" '^ConditionPathExists=!/run/vacti-netpanel\.active$'
check "15-vacti-netpanel.conf orders lightdm After=vacti-netpanel.service (race-free)" \
  has "$NETPANEL_DROPIN" '^After=vacti-netpanel\.service$'
# The defer drop-in must be a SEPARATE file; it must NOT contain the engine.env gate
# condition (that lives only in 10-vacti-gate.conf, which stays untouched).
check "15-vacti-netpanel.conf does NOT carry the engine.env gate condition (gate not duplicated/weakened)" \
  bash -c '! grep -Eq "ConditionPathExists=/etc/vacti-engine/engine\.env" "'"$NETPANEL_DROPIN"'"'
check "10-vacti-gate.conf still keys on engine.env (gate intact)" \
  has "$GATE" '^ConditionPathExists=/etc/vacti-engine/engine\.env$'

echo "== vacti-activate post-enroll handoff targets the network panel, with a lightdm fall-through =="
check "vacti-activate defines start_post_enroll_console()" \
  has "$ACTIVATE_SH" '^start_post_enroll_console\(\)'
check "start_post_enroll_console starts vacti-netpanel.service (--no-block)" \
  has "$ACTIVATE_SH" 'systemctl start --no-block vacti-netpanel\.service'
check "start_post_enroll_console keeps a lightdm fall-through (--no-block)" \
  has "$ACTIVATE_SH" 'systemctl start --no-block lightdm\.service'
check "vacti-activate no longer jumps straight to a bare 'systemctl start lightdm.service' post-enroll" \
  bash -c '! grep -Eq "^[[:space:]]*systemctl start lightdm\.service" "'"$ACTIVATE_SH"'"'
check "pre-enroll kiosk marker 'VACTI_ACTIVATE_KIOSK=start' is unchanged (Enrolling... path intact)" \
  has "$ACTIVATE_SH" 'VACTI_ACTIVATE_KIOSK=start'

echo "== headless SKU degrades to nmtui on the console (not nothing) =="
check "vacti-netpanel-headless.service runs only when enrolled (engine.env)" \
  has "$NETPANEL_HEADLESS_UNIT" '^ConditionPathExists=/etc/vacti-engine/engine\.env$'
check "vacti-netpanel-headless.service is headless-only (!/etc/lightdm)" \
  has "$NETPANEL_HEADLESS_UNIT" '^ConditionPathExists=!/etc/lightdm$'
check "vacti-netpanel-headless.service fails OPEN to a getty (OnFailure=getty@tty1)" \
  has "$NETPANEL_HEADLESS_UNIT" '^OnFailure=getty@tty1\.service$'
check "vacti-netpanel --headless path drives nmtui" \
  has "$NETPANEL_SH" 'nmtui'

echo "== GUI panel uses the premium vacti-kiosk shell in --mode=network, not a bare GTK popup =="
check "vacti-netpanel launches vacti-kiosk in --mode=network as the preferred GUI" \
  has "$NETPANEL_SH" '\--mode=network'
check "vacti-netpanel keeps nm-connection-editor only as a yad-menu fallback" \
  has "$NETPANEL_SH" 'nm-connection-editor'
check "vacti-netpanel maps kiosk exit 0 -> desktop login (one-shot)" \
  bash -c 'grep -Eq "0\\)[[:space:]]+return 2 ;;.*#.*desktop" "'"$NETPANEL_SH"'"'
check "vacti-netpanel maps kiosk exit 10 -> opt-out latch" \
  bash -c 'grep -Eq "10\\)[[:space:]]*return 3 ;;" "'"$NETPANEL_SH"'"'

echo "== vacti-kiosk --mode=network reuses the libadwaita shell with hidden enroll/opt tabs =="
KIOSK_SH="${ENR}/activate/vacti-kiosk"
check "vacti-kiosk parses --mode flag" \
  has "$KIOSK_SH" 'def _flag_mode'
# Both the MODE check and the hide calls must exist in the kiosk source. Multi-line
# proximity matching is brittle in portable grep, so pin both substrings separately.
check "vacti-kiosk network-mode hides the enroll tab" \
  has "$KIOSK_SH" 'p_enr\.set_visible\(False\)'
check "vacti-kiosk network-mode hides the optional tab" \
  has "$KIOSK_SH" 'p_opt\.set_visible\(False\)'
check "vacti-kiosk gates the tab-hide on MODE == \"network\"" \
  has "$KIOSK_SH" 'MODE == "network":'
check "vacti-kiosk network-mode primary button is net_mode_done (not activate)" \
  has "$KIOSK_SH" 'net_mode_done'
check "vacti-kiosk network-mode on-done handler exits cleanly (EXIT_CODE=0)" \
  has "$KIOSK_SH" 'def on_net_mode_done'

echo "== install/enable wiring ships the panel on both build drivers =="
BG="${ROOT}/distro/golden-image/build-golden.sh"
BISO="${ROOT}/distro/live-build-config/build-iso.sh"
APPLY="${ROOT}/distro/branding/apply-branding.sh"
HOOK="${ROOT}/distro/live-build-config/config/hooks/normal/0100-branding.hook.chroot"
check "build-golden stages vacti-netpanel script" \
  has "$BG" 'activate/vacti-netpanel"'
check "build-golden enables vacti-netpanel.service (GUI)" \
  has "$BG" 'systemctl enable vacti-netpanel\.service'
check "build-golden enables the headless nmtui panel under VACTI_HEADLESS_NM" \
  has "$BG" 'systemctl enable vacti-netpanel-headless\.service'
check "apply-branding installs the 15-vacti-netpanel.conf defer drop-in" \
  has "$APPLY" '15-vacti-netpanel\.conf'
check "build-iso stages vacti-netpanel into includes.chroot" \
  has "$BISO" 'activate/vacti-netpanel"'
check "ISO branding hook enables vacti-netpanel.service (GUI)" \
  has "$HOOK" 'systemctl enable vacti-netpanel\.service'

echo "== functional: netpanel engine_env_ready predicate matches the activate one =="
# Source the engine_env_ready() shipped in vacti-netpanel and exercise it, so the
# post-enroll predicate tracks the same content-aware semantics as the kiosk.
CFG_ENV="${TMPD}/netpanel-engine.env"
eval "$(sed -n '/^engine_env_ready() {$/,/^}$/p' "$NETPANEL_SH")"
rm -f "$CFG_ENV"
if ! engine_env_ready; then ok "netpanel: absent engine.env -> not ready"; else no "netpanel: absent engine.env -> not ready"; fi
: > "$CFG_ENV"
if ! engine_env_ready; then ok "netpanel: zero-byte engine.env -> not ready"; else no "netpanel: zero-byte engine.env -> not ready"; fi
printf 'VACTI_URL=https://cp.example\n' > "$CFG_ENV"
if engine_env_ready; then ok "netpanel: populated engine.env -> ready"; else no "netpanel: populated engine.env -> ready"; fi

echo
echo "== summary: ${pass} passed, ${fail} failed =="
[[ $fail -eq 0 ]]
