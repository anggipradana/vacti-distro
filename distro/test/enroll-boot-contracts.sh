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
check "firstboot validates producer token before publishing" \
  has "$FIRSTBOOT_SH" 'VACTI_PRODUCER_TOKEN=\.\+'
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
printf 'VACTI_URL=https://cp.example\nVACTI_PRODUCER_TOKEN=abc123\n' > "$CFG_ENV"
if engine_env_ready; then ok "populated engine.env -> ready"; else no "populated engine.env -> ready"; fi

echo
echo "== summary: ${pass} passed, ${fail} failed =="
[[ $fail -eq 0 ]]
