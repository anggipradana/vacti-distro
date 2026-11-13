#!/bin/bash
# apply.sh - idempotent install wrapper for vacti-appliance-skin.
#
# Called by postinst (configure) and safe to re-run by hand. It:
#   1. stages the shipped branding tree to /usr/share/vacti/branding (only when the
#      upstream one is absent, i.e. a retrofit host; a native appliance image keeps its own),
#   2. CLAIMS every path apply-branding.sh can write (dpkg-divert --rename for originals,
#      write-ahead `created` records otherwise; see skin-lib.sh for the reversal contract),
#      and pre-masks the lockdown units so the masks apply-branding creates are tracked,
#   3. runs the UNCHANGED shared distro/branding/apply-branding.sh (one code path with the
#      golden image + ISO; no fork). apply-branding.sh owns BOTH the brand AND the B3 GREEN
#      lockdown subset (section 11: polkit power rule, ctrl-alt-del mask + burst=none,
#      sysrq=0, getty/autovt tty2-6 masks, serial per SKU) - the skin never re-implements
#      them, it only makes them reversible.
#
# It NEVER stops/restarts vacti-engine, lightdm, logind or sshd, never touches SSH config,
# users, sudoers, tailscale or apt. Boot-time artifacts (plymouth/GRUB) render at the next
# natural reboot. All claims happen BEFORE any write, and a failed claim aborts before
# apply-branding.sh runs, so a host is never left with an unprotected overwrite.
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=skin-lib.sh
. "${HERE}/skin-lib.sh"

skin_require_root
skin_lock
skin_assert_arch_neutral

# ---------------------------------------------------------------------------
# branding layer
# ---------------------------------------------------------------------------
stage_upstream_branding() {
  [ -d "${SKIN_SHARE}/branding" ] || { skin_log "ERROR: ${SKIN_SHARE}/branding missing"; return 1; }
  skin_claim_dir "$SKIN_UPSTREAM_BRANDING" || return 1
  # ours (created) -> refresh it from the package copy on every apply/upgrade
  rm -rf "$SKIN_UPSTREAM_BRANDING" || return 1
  install -d -m 0755 "$(dirname "$SKIN_UPSTREAM_BRANDING")" || return 1
  cp -a "${SKIN_SHARE}/branding" "$SKIN_UPSTREAM_BRANDING" || return 1
  skin_log "branding staged to ${SKIN_UPSTREAM_BRANDING}"
}

claim_branding_targets() {
  local p cur
  for p in "${SKIN_BRANDING_FILES[@]}"; do skin_claim_file "$p" || return 1; done
  for p in "${SKIN_BRANDING_DIRS[@]}"; do skin_claim_dir "$p" || return 1; done
  # parent dirs apply-branding creates with install -d even when no file lands in them
  skin_record_missing_parents /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/.keep || return 1
  skin_record_missing_parents /etc/skel/.config/autostart/.keep || return 1

  # apply-branding enables vacti-motd.service; disable it on remove only if the skin created the unit
  if skin_manifest_has created /etc/systemd/system/vacti-motd.service; then
    skin_manifest_add enabled vacti-motd.service || return 1
  fi
  # hostname: apply-branding renames ONLY a still-generic host to "vacti"; back up so remove restores it
  cur="$(tr -d '[:space:]' < /etc/hostname 2>/dev/null || true)"
  case "$cur" in
    "" | localhost | debian | localhost.localdomain)
      if ! skin_manifest_has hostname-backup /etc/hostname; then
        install -d -m 0700 "$SKIN_BACKUP" || return 1
        if [ -f /etc/hostname ]; then cp -p /etc/hostname "$(skin_backup_path /etc/hostname)" || return 1; fi
        if [ -f /etc/hosts ]; then cp -p /etc/hosts "$(skin_backup_path /etc/hosts)" || return 1; fi
        skin_manifest_add hostname-backup /etc/hostname || return 1
      fi
      ;;
  esac
  # boot-artifact regeneration flags for remove.sh
  if command -v plymouth-set-default-theme >/dev/null 2>&1; then
    if [ -z "$(skin_manifest_first plymouth-prior)" ]; then
      skin_manifest_add plymouth-prior "$(plymouth-set-default-theme 2>/dev/null || echo unknown)" || return 1
    fi
    skin_manifest_add regen initramfs || return 1
  fi
  if command -v update-grub >/dev/null 2>&1; then skin_manifest_add regen grub || return 1; fi
  if command -v gtk-update-icon-cache >/dev/null 2>&1; then skin_manifest_add regen icon-cache || return 1; fi
  # L3: record the prior runtime sysrq before apply-branding.sh live-applies kernel.sysrq=0
  if [ -r /proc/sys/kernel/sysrq ] && [ -z "$(skin_manifest_first sysrq-prior)" ]; then
    local sq
    sq="$(cat /proc/sys/kernel/sysrq 2>/dev/null || true)"
    [ -n "$sq" ] && { skin_manifest_add sysrq-prior "$sq" || return 1; }
  fi
  return 0
}

# Pre-mask the lockdown units apply-branding.sh will mask, so each mask is recorded in the
# skin manifest (skin_mask_unit only records+masks where no unit/override exists; an
# operator-managed mask is left untouched and NOT recorded). apply-branding's own mask_unit
# is then a no-op on these, and remove.sh unmasks exactly what the skin created. L7 serial
# masks are added here only when the serial knob asks for them (mirrors apply-branding L7).
mask_lockdown_units() {
  local u mode ports port
  install -d -m 0755 /etc/systemd/system || return 1
  for u in "${SKIN_LOCKDOWN_MASKS[@]}"; do skin_mask_unit "$u" || return 1; done
  mode="${VACTI_SERIAL_GETTY:-}"
  if [ -z "$mode" ] && [ -f "${SKIN_UPSTREAM_BRANDING}/lockdown.env" ]; then
    mode="$(sed -n 's/^VACTI_SERIAL_GETTY=//p' "${SKIN_UPSTREAM_BRANDING}/lockdown.env" | tail -1 | tr -d "\"' ")"
  fi
  mode="${mode:-keep}"
  if [ "$mode" = mask ] || { [ "$mode" = auto ] && command -v systemd-detect-virt >/dev/null 2>&1 &&
    [ "$(systemd-detect-virt --vm 2>/dev/null || true)" = none ]; }; then
    ports="${VACTI_SERIAL_GETTY_PORTS:-ttyS0 ttyAMA0}"
    for port in $ports; do
      [[ "$port" =~ ^[A-Za-z0-9]+$ ]] || continue
      skin_mask_unit "serial-getty@${port}.service" || return 1
    done
  fi
}

prune_gate_without_kiosk() {
  # The pre-login gate (LightDM waits for engine.env) only makes sense where the activation
  # kiosk exists to perform enrollment. A retrofit host has no vacti-activate.service: if its
  # engine.env were ever removed, the gate would withhold the desktop with nothing to enroll
  # through. So the skin keeps the gate only when the kiosk is installed.
  local gate=/etc/systemd/system/lightdm.service.d/10-vacti-gate.conf
  if ! skin_unit_installed vacti-activate.service && skin_manifest_has created "$gate"; then
    rm -f "$gate"
    skin_log "pre-login gate drop-in not kept (no vacti-activate kiosk on this host)"
  fi
}

apply_branding_layer() {
  if skin_native_appliance; then
    skin_log "native appliance (upstream branding present, not skin-staged): branding layer skipped, lockdown only"
    return 0
  fi
  stage_upstream_branding || return 1
  claim_branding_targets || return 1
  mask_lockdown_units || return 1
  # one code path with the golden image + ISO: this installs the brand AND the B3 GREEN
  # lockdown subset (apply-branding.sh section 11), reading the lockdown knobs from the env
  bash "${SKIN_UPSTREAM_BRANDING}/apply-branding.sh" || return 1
  prune_gate_without_kiosk
  skin_log "branding + lockdown applied via ${SKIN_UPSTREAM_BRANDING}/apply-branding.sh"
}

apply_branding_layer
skin_log "apply complete ($(skin_version))"
