#!/usr/bin/env bash
# apply-branding.sh - the branding hook body SHARED by both drivers:
#   - golden image: run inside the guest via virt-customize --run
#   - ISO: invoked from config/hooks/normal/0100-branding.hook.chroot
#
# It assumes the branding assets have already been copied into the rootfs under
# /usr/share/vacti/branding/ (build-golden.sh --copy-in; live-build
# includes.chroot). It is idempotent and best-effort: a missing optional asset
# (plymouth/grub theme) is a warning, never a failure.
set -euo pipefail

SRC="/usr/share/vacti/branding"
log() { echo "[branding] $*"; }

# 1. /etc/os-release, /etc/issue, /etc/motd
[[ -f "${SRC}/os-release" ]] && install -m0644 "${SRC}/os-release" /etc/os-release && log "os-release applied"
[[ -f "${SRC}/issue" ]]      && install -m0644 "${SRC}/issue"      /etc/issue      && log "issue applied"
[[ -f "${SRC}/motd" ]]       && install -m0644 "${SRC}/motd"       /etc/motd       && log "motd applied"
[[ -f "${SRC}/disclaimer.txt" ]] && install -m0644 "${SRC}/disclaimer.txt" /etc/vacti-non-affiliation.txt

# 2. Plymouth boot splash (GUI/graphical boot only; headless has no plymouth)
if command -v plymouth-set-default-theme >/dev/null 2>&1 && [[ -d "${SRC}/plymouth/vacti" ]]; then
  install -d /usr/share/plymouth/themes/vacti
  cp -a "${SRC}/plymouth/vacti/." /usr/share/plymouth/themes/vacti/
  plymouth-set-default-theme vacti 2>/dev/null && log "plymouth theme=vacti" || log "plymouth set skipped"
  update-initramfs -u 2>/dev/null || log "update-initramfs skipped (no initramfs tooling)"
else
  log "plymouth skipped (headless or theme absent)"
fi

# 3. GRUB splash + theme
if [[ -f "${SRC}/grub/splash.png" ]]; then
  install -d /boot/grub
  install -m0644 "${SRC}/grub/splash.png" /boot/grub/splash.png
  if [[ -d "${SRC}/grub/theme" ]]; then
    install -d /boot/grub/themes/vacti
    cp -a "${SRC}/grub/theme/." /boot/grub/themes/vacti/
    grep -q '^GRUB_THEME=' /etc/default/grub 2>/dev/null \
      && sed -i 's#^GRUB_THEME=.*#GRUB_THEME=/boot/grub/themes/vacti/theme.txt#' /etc/default/grub \
      || echo 'GRUB_THEME=/boot/grub/themes/vacti/theme.txt' >> /etc/default/grub
  fi
  command -v update-grub >/dev/null 2>&1 && update-grub 2>/dev/null && log "grub updated" || log "update-grub skipped"
fi

# 4. Desktop wallpaper (GUI SKU only)
if [[ -d "${SRC}/wallpaper" ]]; then
  install -d /usr/share/backgrounds/vacti
  cp -a "${SRC}/wallpaper/." /usr/share/backgrounds/vacti/ 2>/dev/null || true
  log "wallpaper staged to /usr/share/backgrounds/vacti"
fi

log "branding complete"
