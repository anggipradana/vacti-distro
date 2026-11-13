#!/bin/bash
# auto-revert.sh - dead-man for vacti-appliance-skin. Run hourly by
# vacti-appliance-skin-auto-revert.timer.
#
# If the applied skin version has NOT been acknowledged (`vacti-appliance-skin --ack`)
# by the wall-clock deadline written at install time (install + 24h), the skin is
# removed: `apt-get -y remove vacti-appliance-skin` (prerm -> remove.sh). If apt/dpkg
# cannot run (lock held, broken deps elsewhere), it falls back to `dpkg --remove`, then
# to running remove.sh directly (package stays installed, applied state reversed). A
# failed attempt leaves the marker in place, so the next hourly tick retries.
#
# Fail-safe direction: every uncertain case either waits (a fresh window) or reverts;
# nothing here can make the skin permanent without an explicit operator ack.
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=skin-lib.sh
. "${HERE}/skin-lib.sh"

skin_require_root

ver="$(skin_applied_version)"
if [ -z "$ver" ]; then
  skin_log "auto-revert: no applied skin version; nothing to do, disarming timer"
  systemctl disable --now "$SKIN_TIMER" >/dev/null 2>&1 || true
  exit 0
fi

if [ "$(skin_acked_version)" = "$ver" ]; then
  skin_log "auto-revert: version ${ver} acknowledged; disarming timer"
  systemctl disable --now "$SKIN_TIMER" >/dev/null 2>&1 || true
  exit 0
fi

now="$(date +%s)"
deadline="$(awk 'NR==1{print $1}' "$SKIN_DEADLINE" 2>/dev/null || true)"
case "$deadline" in
  '' | *[!0-9]*)
    # missing/corrupt deadline: start a fresh window rather than guess (never "permanent")
    install -d -m 0755 "$SKIN_STATE"
    printf '%s %s\n' "$((now + SKIN_REVERT_WINDOW_SEC))" "$ver" > "$SKIN_DEADLINE"
    skin_log "auto-revert: deadline missing; new window ends in ${SKIN_REVERT_WINDOW_SEC}s"
    exit 0
    ;;
esac

if [ "$now" -lt "$deadline" ]; then
  skin_log "auto-revert: ${ver} not acknowledged yet; reverting in $(((deadline - now) / 60)) min unless: vacti-appliance-skin --ack"
  exit 0
fi

skin_log "auto-revert: ${ver} NOT acknowledged by the deadline; reverting the skin"
date -u '+%FT%TZ' > "${SKIN_STATE}/auto-reverted" 2>/dev/null || true

export DEBIAN_FRONTEND=noninteractive
if apt-get -y -o DPkg::Lock::Timeout=900 remove "$SKIN_PKG"; then
  skin_log "auto-revert: package removed"
  exit 0
fi
skin_log "auto-revert: apt-get remove failed; trying dpkg --remove"
if dpkg --remove "$SKIN_PKG"; then
  skin_log "auto-revert: package removed (dpkg)"
  exit 0
fi
skin_log "auto-revert: dpkg --remove failed; reverting the applied state directly (package stays installed)"
if "${SKIN_LIBEXEC}/remove.sh"; then
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl disable --now "$SKIN_TIMER" >/dev/null 2>&1 || true
  skin_log "auto-revert: state reverted; re-apply later with: dpkg-reconfigure ${SKIN_PKG}"
  exit 0
fi
skin_log "auto-revert: reversal incomplete; will retry on the next tick"
exit 1
