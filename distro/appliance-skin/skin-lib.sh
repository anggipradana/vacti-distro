#!/bin/bash
# skin-lib.sh - shared constants + helpers for vacti-appliance-skin.
#
# Sourced (never executed) by apply.sh, remove.sh, auto-revert.sh, ctl.sh and the
# postinst/prerm maintainer scripts. postrm does NOT source it (on remove the file
# is already gone by the time postrm runs).
#
# THE REVERSAL CONTRACT (what makes `apt remove` a full revert of the skin):
#   * a target file that PRE-EXISTS is moved aside with
#       dpkg-divert --package vacti-appliance-skin --add --rename --divert <p>.vacti-orig <p>
#     BEFORE anything writes it; remove.sh deletes the skin copy and runs
#     `dpkg-divert --remove --rename`, restoring the original byte-for-byte.
#   * a target file/dir that is ABSENT is recorded as `created` in the manifest
#     (write-ahead, before it is written) and deleted on remove.
#   * a pre-existing target DIRECTORY is tar-backed-up and restored on remove.
#   * parent directories the skin had to create are recorded as `createddir`.
#   * systemd masks are only created where no unit file/override existed, and
#     only those masks are removed again.
#   * runtime side effects record their prior value (sysrq) or a regen flag
#     (initramfs, grub) so remove.sh can put them back.
# The manifest is cumulative across upgrades, so a path the skin created in an
# earlier version is never mistaken for a pre-existing original.
#
# Scope: branding + lockdown + diverts + units ONLY. The kali->arparp user
# migration (migrate-user.sh) is operator-invoked, separate, and NOT reversed here.
# shellcheck shell=bash

SKIN_PKG=vacti-appliance-skin
SKIN_SHARE="${SKIN_SHARE:-/usr/share/vacti-appliance-skin}"
SKIN_LIBEXEC="${SKIN_LIBEXEC:-/usr/libexec/vacti-appliance-skin}"
SKIN_ETC=/etc/vacti-appliance-skin
SKIN_STATE=/var/lib/vacti-appliance-skin
SKIN_MANIFEST="${SKIN_STATE}/manifest"
SKIN_BACKUP="${SKIN_STATE}/backup"
SKIN_MARKER="${SKIN_ETC}/applied-version"
SKIN_ACK="${SKIN_STATE}/ack"
SKIN_DEADLINE="${SKIN_STATE}/revert-deadline"
SKIN_TIMER=vacti-appliance-skin-auto-revert.timer
SKIN_UPSTREAM_BRANDING=/usr/share/vacti/branding
SKIN_DIVERT_SUFFIX=.vacti-orig
SKIN_REVERT_WINDOW_SEC="${SKIN_REVERT_WINDOW_SEC:-86400}"

# Files apply-branding.sh (distro/branding/apply-branding.sh) may write. Keep in
# sync with that script: every path it installs MUST be listed here or in
# SKIN_BRANDING_DIRS, otherwise remove.sh cannot reverse it. The CI smoke test
# (test/smoke.sh) asserts a byte-identical /etc + /usr/local + /boot + /root after
# install -> remove, so a missed path fails the release.
# shellcheck disable=SC2034  # consumed by apply.sh/remove.sh which source this file
SKIN_BRANDING_FILES=(
  /etc/os-release
  /etc/issue
  /etc/issue.net
  /etc/motd
  /etc/vacti-non-affiliation.txt
  /usr/share/icons/hicolor/scalable/apps/vacti.svg
  /usr/share/pixmaps/vacti.svg
  /usr/share/icons/hicolor/16x16/apps/vacti.png
  /usr/share/icons/hicolor/32x32/apps/vacti.png
  /usr/share/icons/hicolor/48x48/apps/vacti.png
  /usr/share/icons/hicolor/64x64/apps/vacti.png
  /usr/share/icons/hicolor/128x128/apps/vacti.png
  /usr/share/icons/hicolor/256x256/apps/vacti.png
  /usr/local/sbin/vacti-motd
  /etc/systemd/system/vacti-motd.service
  /etc/skel/.config/fastfetch/config.jsonc
  /root/.config/fastfetch/config.jsonc
  /etc/profile.d/vacti-ps1.sh
  /etc/plymouth/plymouthd.conf
  /etc/systemd/system/plymouth-quit-wait.service.d/10-vacti-timeout.conf
  /boot/grub/splash.png
  /etc/default/grub
  /etc/lightdm/lightdm-gtk-greeter.conf
  /etc/systemd/system/lightdm.service.d/10-vacti-gate.conf
  /etc/systemd/system/lightdm.service.d/15-vacti-netpanel.conf
  /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml
  /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml
  /etc/skel/.config/autostart/vacti-wallpaper.desktop
  /usr/local/bin/vacti-set-wallpaper
  /usr/local/share/vacti-kiosk/vacti-kiosk.css
  /etc/polkit-1/rules.d/10-vacti-lockdown.rules
  /etc/systemd/system.conf.d/10-vacti-cad.conf
  /etc/sysctl.d/90-vacti-sysrq.conf
  /usr/local/sbin/vacti-undo-tty-mask
  /usr/local/sbin/vacti-lockdown-undo
)
# shellcheck disable=SC2034  # consumed by apply.sh/remove.sh which source this file
SKIN_BRANDING_DIRS=(
  /usr/share/plymouth/themes/vacti
  /boot/grub/themes/vacti
  /usr/share/backgrounds/vacti
)

# B3 GREEN lockdown is applied by apply-branding.sh (section 11: L1 polkit power, L2
# ctrl-alt-del, L3 sysrq, L6 getty tty2-6, L7 serial per SKU) - the skin does NOT ship a
# second copy. The skin's job is reversibility: it pre-claims the lockdown FILES (in
# SKIN_BRANDING_FILES above) and pre-masks the lockdown UNITS below so remove.sh can
# restore them. tty1 (getty@tty1 / autovt@tty1) and the getty@.service template are NEVER
# masked: they are the local console break-glass path. L7 serial masks are added at apply
# time only when the serial knob requests them (default keep = none).
# shellcheck disable=SC2034  # consumed by apply.sh which sources this file
SKIN_LOCKDOWN_MASKS=(
  ctrl-alt-del.target
  getty@tty2.service getty@tty3.service getty@tty4.service getty@tty5.service getty@tty6.service
  autovt@tty2.service autovt@tty3.service autovt@tty4.service autovt@tty5.service autovt@tty6.service
)

skin_log() {
  echo "[${SKIN_PKG}] $*"
  if command -v logger >/dev/null 2>&1; then logger -t "$SKIN_PKG" -- "$*" 2>/dev/null || true; fi
  return 0
}

skin_require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "[${SKIN_PKG}] must run as root" >&2
    exit 1
  fi
}

skin_version() {
  if [ -s "${SKIN_SHARE}/VERSION" ]; then
    head -n1 "${SKIN_SHARE}/VERSION"
  else
    # shellcheck disable=SC2016  # ${Version} is a dpkg-query format field, not a shell expansion
    dpkg-query -W -f='${Version}' "$SKIN_PKG" 2>/dev/null || echo unknown
  fi
}

skin_applied_version() { head -n1 "$SKIN_MARKER" 2>/dev/null || true; }
skin_acked_version() { awk 'NR==1{print $1}' "$SKIN_ACK" 2>/dev/null || true; }

# --- manifest: one "kind<TAB>value" per line --------------------------------
skin_manifest_has() { [ -f "$SKIN_MANIFEST" ] && grep -qxF -- "${1}"$'\t'"${2}" "$SKIN_MANIFEST"; }
skin_manifest_add() {
  install -d -m 0755 "$SKIN_STATE" || return 1
  skin_manifest_has "$1" "$2" && return 0
  printf '%s\t%s\n' "$1" "$2" >> "$SKIN_MANIFEST" || return 1
}
# all values of one kind, in recorded order
skin_manifest_values() {
  [ -f "$SKIN_MANIFEST" ] || return 0
  awk -F '\t' -v k="$1" '$1==k {print $2}' "$SKIN_MANIFEST"
}
skin_manifest_first() { skin_manifest_values "$1" | head -n1; }

# backup location for a path (e.g. /etc/hosts -> backup/etc_hosts)
skin_backup_path() { printf '%s/%s' "$SKIN_BACKUP" "$(printf '%s' "${1#/}" | tr '/' '_')"; }

# --- dpkg helpers ------------------------------------------------------------
skin_diverted_by_us() { [ "$(dpkg-divert --listpackage "$1" 2>/dev/null)" = "$SKIN_PKG" ]; }

# "path<TAB>divert-to" for every diversion this package holds (source of truth for remove.sh)
skin_our_diversions() {
  LC_ALL=C dpkg-divert --list 2>/dev/null |
    sed -n "s/^diversion of \(.*\) to \(.*\) by ${SKIN_PKG}\$/\1\t\2/p"
}

# true when an installed package (other than a diversion record) owns exactly this path
skin_dpkg_owned() {
  LC_ALL=C dpkg-query -S "$1" 2>/dev/null |
    awk -v p="$1" 'index($0, "diversion by ") != 1 { i = index($0, ": "); if (i && substr($0, i + 2) == p) f = 1 } END { exit !f }'
}

skin_record_missing_parents() {
  local d
  d="$(dirname "$1")"
  while [ "$d" != "/" ] && [ ! -e "$d" ]; do
    skin_manifest_add createddir "$d" || return 1
    d="$(dirname "$d")"
  done
}

# Claim a target FILE before anything writes it. Callers use `|| return 1`, so every
# failure path below returns explicitly (set -e does not apply inside `f || ...`).
skin_claim_file() {
  local p="$1" orig="$1${SKIN_DIVERT_SUFFIX}"
  skin_manifest_has created "$p" && return 0
  skin_diverted_by_us "$p" && return 0
  skin_record_missing_parents "$p" || return 1
  if [ -e "$p" ] || [ -L "$p" ]; then
    if [ -d "$p" ] && [ ! -L "$p" ]; then
      skin_log "ERROR: ${p} is a directory, refusing to divert it"
      return 1
    fi
    if [ -e "$orig" ] || [ -L "$orig" ]; then
      skin_log "ERROR: stale ${orig} exists; refusing to clobber it (inspect and remove it by hand)"
      return 1
    fi
    if [ -n "$(dpkg-divert --listpackage "$p" 2>/dev/null)" ]; then
      skin_log "ERROR: ${p} is already diverted by $(dpkg-divert --listpackage "$p"); refusing to stack a diversion"
      return 1
    fi
    dpkg-divert --package "$SKIN_PKG" --add --rename --divert "$orig" "$p" >/dev/null || return 1
    # Seed the real path with the original CONTENT (dereferenced, as a regular file) so
    # in-place editors (apply-branding's set_grub on /etc/default/grub) start from stock
    # content and an optional step that is skipped leaves stock content in place. A
    # symlinked original (/etc/os-release -> ../usr/lib/os-release) is seeded as a copy,
    # so a later `install` onto the real path can never write through to the link target.
    cp -pL "$orig" "$p" 2>/dev/null || true
  else
    skin_manifest_add created "$p" || return 1
  fi
}

# Claim a target DIRECTORY (pre-existing -> tar backup; absent -> created).
skin_claim_dir() {
  local p="$1" tb
  skin_manifest_has created "$p" && return 0
  skin_manifest_has dirbackup "$p" && return 0
  skin_record_missing_parents "$p" || return 1
  if [ -d "$p" ] && [ ! -L "$p" ]; then
    install -d -m 0700 "$SKIN_BACKUP" || return 1
    tb="$(skin_backup_path "$p").tar.gz"
    tar -C / -czf "$tb" "${p#/}" || return 1
    skin_manifest_add dirbackup "$p" || return 1
  elif [ -e "$p" ] || [ -L "$p" ]; then
    skin_log "ERROR: ${p} exists but is not a directory"
    return 1
  else
    skin_manifest_add created "$p" || return 1
  fi
}

# Mask a unit only when NO unit file/override already exists at /etc/systemd/system/<u>
# (an operator-managed unit or mask is left alone and not recorded). Plain symlink to
# /dev/null == `systemctl mask`, but works offline (chroot/CI) too.
skin_mask_unit() {
  local u="$1" p="/etc/systemd/system/$1"
  if skin_manifest_has mask "$u"; then
    [ -L "$p" ] || ln -s /dev/null "$p" || return 1
    return 0
  fi
  if [ -e "$p" ] || [ -L "$p" ]; then
    skin_log "mask ${u}: ${p} already exists (operator-managed), left untouched"
    return 0
  fi
  skin_manifest_add mask "$u" || return 1
  ln -s /dev/null "$p" || return 1
}

skin_unit_installed() {
  local d
  for d in /etc/systemd/system /usr/lib/systemd/system /lib/systemd/system; do
    [ -e "${d}/$1" ] && return 0
  done
  return 1
}

# Native appliance = upstream branding already present and NOT staged by the skin (a
# golden-image / ISO install). The image already carries the brand; the skin then
# applies only the lockdown layer and never touches the image's branding files.
skin_native_appliance() {
  [ -d "$SKIN_UPSTREAM_BRANDING" ] && ! skin_manifest_has created "$SKIN_UPSTREAM_BRANDING"
}

# The package is Architecture: all. Refuse to apply if a native binary ever sneaks
# into the payload while running on a non-x86_64 host (guard; none ship today).
skin_assert_arch_neutral() {
  local f magic
  [ "$(uname -m)" = "x86_64" ] && return 0
  while IFS= read -r -d '' f; do
    magic="$(head -c 4 "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n')"
    if [ "$magic" = "7f454c46" ]; then
      skin_log "ERROR: arch-specific (ELF) asset ${f} on $(uname -m); refusing to apply"
      return 1
    fi
  done < <(find "$SKIN_SHARE" "$SKIN_LIBEXEC" -type f -print0 2>/dev/null)
  return 0
}

# Arm the 24h auto-revert. The window is a WALL-CLOCK deadline written here (so a
# reboot neither resets nor skips it); the timer only polls. An ack recorded for THIS
# version disarms; a new version starts a new probation window.
skin_arm_auto_revert() {
  local ver="$1" now
  if [ "$(skin_acked_version)" = "$ver" ]; then
    skin_log "version ${ver} already acknowledged; auto-revert not armed"
    return 0
  fi
  if [ -f "$SKIN_ACK" ]; then mv -f "$SKIN_ACK" "${SKIN_ACK}.prev" 2>/dev/null || true; fi
  now="$(date +%s)"
  install -d -m 0755 "$SKIN_STATE" || return 1
  printf '%s %s\n' "$((now + SKIN_REVERT_WINDOW_SEC))" "$ver" > "$SKIN_DEADLINE" || return 1
  systemctl enable --now "$SKIN_TIMER" >/dev/null 2>&1 || systemctl enable "$SKIN_TIMER" >/dev/null 2>&1 || true
  skin_log "auto-revert armed: skin is removed at $(date -d "@$((now + SKIN_REVERT_WINDOW_SEC))" '+%F %T %Z' 2>/dev/null || echo "+${SKIN_REVERT_WINDOW_SEC}s") unless acknowledged with: vacti-appliance-skin --ack"
}

# Serialise apply/remove/auto-revert against each other.
skin_lock() {
  install -d -m 0755 "$SKIN_STATE" || return 1
  exec 9> "${SKIN_STATE}/.lock" || return 1
  if command -v flock >/dev/null 2>&1; then
    flock -w 600 9 || { skin_log "ERROR: could not take ${SKIN_STATE}/.lock"; return 1; }
  fi
}
