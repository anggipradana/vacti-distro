#!/usr/bin/env bash
# undo-tty-mask.sh -> /usr/local/sbin/vacti-undo-tty-mask (+ alias vacti-lockdown-undo)
#
# Operator revert for the console/power lockdown that apply-branding.sh (section
# 11) lays down. Each reverted layer also gets an opt-out latch, so a later
# apply-branding.sh re-run (retrofit, rebuild-in-place) does NOT re-apply it.
#
#   tty    (DEFAULT) L6 getty@/autovt@ tty2..6 masks + L7 serial-getty masks
#   power  L1 polkit rule removed + ~power put back in the LightDM greeter
#   cad    L2 ctrl-alt-del.target unmasked + CtrlAltDelBurstAction drop-in removed
#   sysrq  L3 sysctl drop-in removed + kernel.sysrq reset from the remaining config
#   all    every layer above
#
# Only these files and unit masks are touched. tty1, the kiosk, LightDM, the
# engine and SSH are left alone. Nothing is started, stopped or restarted live.
# Unmasked VTs spawn a getty on the next VT switch or boot. The greeter and CAD
# changes apply at the next LightDM start or boot.
#
# Usage: sudo vacti-undo-tty-mask [tty|power|cad|sysrq|all]...
#        sudo vacti-undo-tty-mask --relock [tty|power|cad|sysrq|all]...
#             (removes the opt-out latch(es); the next apply-branding run re-applies)
set -euo pipefail

LATCH_DIR="/etc/vacti-lockdown"
SERIAL_PORTS="${VACTI_SERIAL_GETTY_PORTS:-ttyS0 ttyAMA0}"
GREETER_CONF="/etc/lightdm/lightdm-gtk-greeter.conf"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "vacti-undo-tty-mask: must run as root (sudo)" >&2
  exit 1
fi

latch_file() { # layer
  case "$1" in
    tty)   echo "${LATCH_DIR}/tty-mask.optout" ;;
    power) echo "${LATCH_DIR}/l1-power.optout" ;;
    cad)   echo "${LATCH_DIR}/l2-cad.optout" ;;
    sysrq) echo "${LATCH_DIR}/l3-sysrq.optout" ;;
  esac
}
latch() { install -d -m0755 "$LATCH_DIR"; : > "$(latch_file "$1")"; }

unmask_unit() { # unit
  if command -v systemctl >/dev/null 2>&1; then
    systemctl unmask "$1" >/dev/null 2>&1 && return 0
  fi
  # offline fallback: drop only an /etc mask symlink that points at /dev/null
  local p="/etc/systemd/system/$1"
  if [[ -L "$p" && "$(readlink "$p")" == "/dev/null" ]]; then rm -f "$p"; fi
}

undo_tty() {
  local i port
  for i in 2 3 4 5 6; do
    unmask_unit "getty@tty${i}.service"
    unmask_unit "autovt@tty${i}.service"
  done
  for port in $SERIAL_PORTS; do
    [[ "$port" =~ ^[A-Za-z0-9]+$ ]] || continue
    unmask_unit "serial-getty@${port}.service"
  done
  latch tty
  echo "vacti-undo-tty-mask: [tty] tty2..6 + serial getty masks removed"
}

undo_power() {
  rm -f /etc/polkit-1/rules.d/10-vacti-lockdown.rules
  if [[ -f "$GREETER_CONF" ]] && grep -qE '^indicators *=' "$GREETER_CONF" \
     && ! grep -qE '^indicators *=.*~power' "$GREETER_CONF"; then
    sed -i -E 's/^(indicators *=.*[^;[:space:]])[;[:space:]]*$/\1;~power/' "$GREETER_CONF"
  fi
  latch power
  echo "vacti-undo-tty-mask: [power] polkit power rule removed; greeter ~power restored (next LightDM start)"
}

undo_cad() {
  unmask_unit ctrl-alt-del.target
  rm -f /etc/systemd/system.conf.d/10-vacti-cad.conf
  latch cad
  echo "vacti-undo-tty-mask: [cad] ctrl-alt-del.target unmasked; burst drop-in removed (next boot / daemon-reexec)"
}

undo_sysrq() {
  rm -f /etc/sysctl.d/90-vacti-sysrq.conf
  local s
  for s in /usr/lib/systemd/systemd-sysctl /lib/systemd/systemd-sysctl; do
    if [[ -x "$s" ]]; then "$s" --prefix=kernel.sysrq >/dev/null 2>&1 || true; break; fi
  done
  latch sysrq
  echo "vacti-undo-tty-mask: [sysrq] drop-in removed; kernel.sysrq now $(cat /proc/sys/kernel/sysrq 2>/dev/null || echo '?') (distro default after reboot)"
}

expand() { # layers... -> canonical list (default tty)
  local l out=()
  [[ $# -eq 0 ]] && set -- tty
  for l in "$@"; do
    case "$l" in
      all) out+=(tty power cad sysrq) ;;
      tty|power|cad|sysrq) out+=("$l") ;;
      *) echo "vacti-undo-tty-mask: unknown layer '$l' (expected tty|power|cad|sysrq|all)" >&2; exit 2 ;;
    esac
  done
  printf '%s\n' "${out[@]}"
}

relock=0
if [[ "${1:-}" == "--relock" ]]; then relock=1; shift; fi
layers="$(expand "$@")" || exit 2

for l in $layers; do
  if [[ "$relock" -eq 1 ]]; then
    rm -f "$(latch_file "$l")"
    echo "vacti-undo-tty-mask: [${l}] opt-out latch removed; the next apply-branding.sh run re-applies it"
  else
    "undo_${l}"
  fi
done
[[ "$relock" -eq 1 ]] && exit 0
echo "vacti-undo-tty-mask: opt-out latch(es) under ${LATCH_DIR}"
