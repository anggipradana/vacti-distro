#!/bin/bash
# remove.sh - idempotent full reversal of vacti-appliance-skin (branding + lockdown +
# diverts + units). Called by prerm (remove) and by the auto-revert fallback; safe to
# re-run. Best-effort: every step is attempted, failures are logged and make the exit
# status non-zero, and the manifest is KEPT on failure so a re-run can finish the job.
#
# Order matters:
#   1. units: disable what the skin enabled, unmask only the masks the skin created
#   2. delete what the skin created (never a path an installed package now owns)
#   3. un-divert: delete the skin copy FIRST, then `dpkg-divert --remove --rename` puts
#      the original back (with the skin copy still present the rename would be refused)
#   4. restore backed-up directories + hostname, restore runtime sysrq
#   5. regenerate boot artifacts (initramfs, grub) and the icon cache from restored state
#   6. remove now-empty parent dirs the skin created, daemon-reload
#
# NOT reversed here (by design): the operator-invoked kali->arparp migration
# (migrate-user.sh). It has its own rollback-a / rollback-b.
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=skin-lib.sh
. "${HERE}/skin-lib.sh"

skin_require_root
skin_lock || exit 1

rc=0
warn() { skin_log "WARN: $*"; rc=1; }

# 1. units ---------------------------------------------------------------------
while IFS= read -r u; do
  [ -n "$u" ] || continue
  systemctl disable "$u" >/dev/null 2>&1 || true
  # offline-safe: drop any enablement symlink even when systemd is not running
  find /etc/systemd/system -type l -name "$u" -delete 2>/dev/null || true
done < <(skin_manifest_values enabled)

while IFS= read -r u; do
  [ -n "$u" ] || continue
  p="/etc/systemd/system/${u}"
  if [ -L "$p" ] && [ "$(readlink "$p")" = /dev/null ]; then
    rm -f "$p" || warn "could not unmask ${u}"
  fi
done < <(skin_manifest_values mask)

# 2. created paths (reverse order) ------------------------------------------------
while IFS= read -r p; do
  [ -n "$p" ] || continue
  if [ ! -e "$p" ] && [ ! -L "$p" ]; then continue; fi
  if skin_dpkg_owned "$p"; then
    skin_log "keep ${p}: now owned by an installed package"
    continue
  fi
  if [ -d "$p" ] && [ ! -L "$p" ]; then
    rm -rf "$p" || warn "could not remove ${p}"
  else
    rm -f "$p" || warn "could not remove ${p}"
  fi
done < <(skin_manifest_values created | tac)

# 3. diversions (dpkg database is the source of truth) ----------------------------
while IFS=$'\t' read -r p to; do
  [ -n "$p" ] || continue
  if [ -d "$p" ] && [ ! -L "$p" ]; then
    warn "${p} is a directory; leaving diversion for manual review"
    continue
  fi
  rm -f "$p" || { warn "could not remove skin copy ${p}"; continue; }
  dpkg-divert --package "$SKIN_PKG" --remove --rename --divert "$to" "$p" >/dev/null ||
    warn "dpkg-divert --remove failed for ${p} (original still at ${to})"
done < <(skin_our_diversions)

# 4. directory backups, hostname, sysrq ------------------------------------------
while IFS= read -r p; do
  [ -n "$p" ] || continue
  tb="$(skin_backup_path "$p").tar.gz"
  if [ -f "$tb" ]; then
    rm -rf "$p" && tar -C / -xzf "$tb" || warn "could not restore ${p} from ${tb}"
  else
    warn "backup ${tb} missing for ${p}"
  fi
done < <(skin_manifest_values dirbackup)

if skin_manifest_has hostname-backup /etc/hostname; then
  if [ "$(tr -d '[:space:]' < /etc/hostname 2>/dev/null)" = "vacti" ]; then
    hb="$(skin_backup_path /etc/hostname)"
    hh="$(skin_backup_path /etc/hosts)"
    if [ -f "$hb" ]; then cp -p "$hb" /etc/hostname || warn "could not restore /etc/hostname"; else rm -f /etc/hostname; fi
    if [ -f "$hh" ]; then cp -p "$hh" /etc/hosts || warn "could not restore /etc/hosts"; fi
    hostname "$(tr -d '[:space:]' < /etc/hostname 2>/dev/null || echo localhost)" 2>/dev/null || true
  else
    skin_log "hostname changed since apply; not restoring the pre-skin hostname"
  fi
fi

prior_sysrq="$(skin_manifest_first sysrq-prior)"
if [ -n "$prior_sysrq" ]; then
  sysctl -q -w "kernel.sysrq=${prior_sysrq}" >/dev/null 2>&1 || true
fi

# 5. boot artifacts + caches --------------------------------------------------------
if skin_manifest_has regen initramfs; then
  cur_theme="$(plymouth-set-default-theme 2>/dev/null || true)"
  prior_theme="$(skin_manifest_first plymouth-prior)"
  if [ "$cur_theme" = "vacti" ]; then
    # plymouthd.conf was diverted and is restored above; this is the belt-and-braces path
    # for setups that select the theme elsewhere (e.g. an alternatives link).
    if [ -n "$prior_theme" ] && [ "$prior_theme" != "unknown" ] && [ "$prior_theme" != "vacti" ]; then
      plymouth-set-default-theme "$prior_theme" 2>/dev/null || warn "could not restore plymouth theme ${prior_theme}"
    else
      plymouth-set-default-theme --reset 2>/dev/null || warn "could not reset plymouth theme"
    fi
  fi
  if command -v update-initramfs >/dev/null 2>&1; then
    update-initramfs -u >/dev/null 2>&1 || warn "update-initramfs failed"
  fi
fi
if skin_manifest_has regen grub && command -v update-grub >/dev/null 2>&1; then
  update-grub >/dev/null 2>&1 || warn "update-grub failed"
fi
if skin_manifest_has regen icon-cache && command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f /usr/share/icons/hicolor >/dev/null 2>&1 || true
fi

# 6. empty parent dirs (deepest first), systemd ----------------------------------------
while IFS= read -r d; do
  [ -n "$d" ] || continue
  [ -d "$d" ] && rmdir --ignore-fail-on-non-empty "$d" 2>/dev/null
done < <(skin_manifest_values createddir | awk -F/ '{print NF "\t" $0}' | sort -rn | cut -f2-)

systemctl daemon-reload >/dev/null 2>&1 || true

if [ "$rc" -eq 0 ]; then
  rm -f "$SKIN_MANIFEST" "$SKIN_MARKER"
  rm -rf "$SKIN_BACKUP"
  skin_log "skin reverted (branding + lockdown + diverts + units)"
else
  skin_log "skin reversal INCOMPLETE; manifest kept at ${SKIN_MANIFEST}; re-run ${SKIN_LIBEXEC}/remove.sh"
fi
exit "$rc"
