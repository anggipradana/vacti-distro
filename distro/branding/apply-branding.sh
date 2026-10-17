#!/usr/bin/env bash
# apply-branding.sh - the branding hook body SHARED by both drivers:
#   - golden image: run inside the guest via virt-customize --run
#   - ISO: invoked from config/hooks/normal/0100-branding.hook.chroot
#
# It assumes the branding assets have already been copied into the rootfs under
# /usr/share/vacti/branding/ (build-golden.sh --copy-in; live-build
# includes.chroot). It is idempotent and best-effort: a missing optional asset
# (a GUI-only piece on a headless image, a renderer, a display manager) is a
# warning, never a failure. Everything it installs is the REAL vacti brand
# (radar-shield logomark + Plus Jakarta wordmark + the product navy palette).
set -euo pipefail

SRC="/usr/share/vacti/branding"
log() { echo "[branding] $*"; }

# ---------------------------------------------------------------------------
# 1. identity text: os-release / issue / issue.net / motd / disclaimer
# ---------------------------------------------------------------------------
[[ -f "${SRC}/os-release" ]] && install -m0644 "${SRC}/os-release" /etc/os-release && log "os-release applied"
[[ -f "${SRC}/issue" ]]      && install -m0644 "${SRC}/issue"      /etc/issue      && log "issue applied"
[[ -f "${SRC}/issue.net" ]]  && install -m0644 "${SRC}/issue.net"  /etc/issue.net  && log "issue.net applied"
[[ -f "${SRC}/motd" ]]       && install -m0644 "${SRC}/motd"       /etc/motd       && log "motd (static fallback) applied"
[[ -f "${SRC}/disclaimer.txt" ]] && install -m0644 "${SRC}/disclaimer.txt" /etc/vacti-non-affiliation.txt

# ---------------------------------------------------------------------------
# 2. logo icon into the hicolor theme + pixmaps (whisker menu, os-release LOGO)
# ---------------------------------------------------------------------------
if [[ -f "${SRC}/logo/svg/vacti-icon.svg" ]]; then
  install -D -m0644 "${SRC}/logo/svg/vacti-icon.svg" /usr/share/icons/hicolor/scalable/apps/vacti.svg
  install -D -m0644 "${SRC}/logo/svg/vacti-icon.svg" /usr/share/pixmaps/vacti.svg
  for px in 16 32 48 64 128 256; do
    [[ -f "${SRC}/logo/png/vacti-icon-${px}.png" ]] && \
      install -D -m0644 "${SRC}/logo/png/vacti-icon-${px}.png" "/usr/share/icons/hicolor/${px}x${px}/apps/vacti.png"
  done
  command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -f /usr/share/icons/hicolor 2>/dev/null || true
  log "vacti icon installed into hicolor + pixmaps"
fi

# ---------------------------------------------------------------------------
# 3. dynamic console MOTD (generator + boot service) + static populate
# ---------------------------------------------------------------------------
if [[ -f "${SRC}/console/vacti-motd" ]]; then
  install -D -m0755 "${SRC}/console/vacti-motd" /usr/local/sbin/vacti-motd
  [[ -f "${SRC}/console/vacti-motd.service" ]] && install -D -m0644 "${SRC}/console/vacti-motd.service" /etc/systemd/system/vacti-motd.service
  systemctl enable vacti-motd.service 2>/dev/null || true
  # Populate /etc/motd now so the first login already shows the brand banner
  # (host/IP/enrollment fill in once the box boots and the service re-runs).
  /usr/local/sbin/vacti-motd > /etc/motd 2>/dev/null || true
  log "dynamic MOTD installed (vacti-motd + service)"
fi

# ---------------------------------------------------------------------------
# 4. fastfetch config (per-user skel + root): branded `fastfetch` over SSH
# ---------------------------------------------------------------------------
if [[ -f "${SRC}/fastfetch/config.jsonc" ]]; then
  for home in /etc/skel /root; do
    install -D -m0644 "${SRC}/fastfetch/config.jsonc" "${home}/.config/fastfetch/config.jsonc"
  done
  log "fastfetch config installed (skel + root)"
fi

# ---------------------------------------------------------------------------
# 5. subtle brand PS1 for interactive login shells
# ---------------------------------------------------------------------------
[[ -f "${SRC}/profile.d/vacti-ps1.sh" ]] && install -D -m0644 "${SRC}/profile.d/vacti-ps1.sh" /etc/profile.d/vacti-ps1.sh && log "PS1 profile.d installed"

# ---------------------------------------------------------------------------
# 6. Plymouth boot splash (graphical boot only; headless skips cleanly)
# ---------------------------------------------------------------------------
if command -v plymouth-set-default-theme >/dev/null 2>&1 && [[ -d "${SRC}/plymouth/vacti" ]]; then
  install -d /usr/share/plymouth/themes/vacti
  cp -a "${SRC}/plymouth/vacti/." /usr/share/plymouth/themes/vacti/
  # keep only runtime assets in the theme dir (drop the .svg sources)
  rm -f /usr/share/plymouth/themes/vacti/*.svg 2>/dev/null || true
  plymouth-set-default-theme vacti 2>/dev/null && log "plymouth theme=vacti" || log "plymouth set skipped"
  update-initramfs -u 2>/dev/null || log "update-initramfs skipped (no initramfs tooling)"
else
  log "plymouth skipped (headless or theme absent)"
fi

# ---------------------------------------------------------------------------
# 7. GRUB splash + theme + brand menu colours
# ---------------------------------------------------------------------------
if [[ -f "${SRC}/grub/splash.png" ]]; then
  install -D -m0644 "${SRC}/grub/splash.png" /boot/grub/splash.png
  if [[ -d "${SRC}/grub/theme" ]]; then
    install -d /boot/grub/themes/vacti
    cp -a "${SRC}/grub/theme/." /boot/grub/themes/vacti/
    set_grub() { # key value
      if grep -q "^$1=" /etc/default/grub 2>/dev/null; then
        sed -i "s#^$1=.*#$1=$2#" /etc/default/grub
      else
        echo "$1=$2" >> /etc/default/grub
      fi
    }
    set_grub GRUB_THEME "/boot/grub/themes/vacti/theme.txt"
    grep -q '^GRUB_GFXMODE=' /etc/default/grub 2>/dev/null || echo 'GRUB_GFXMODE=auto' >> /etc/default/grub
    grep -q '^GRUB_TIMEOUT_STYLE=' /etc/default/grub 2>/dev/null || echo 'GRUB_TIMEOUT_STYLE=menu' >> /etc/default/grub
  fi
  command -v update-grub >/dev/null 2>&1 && update-grub 2>/dev/null && log "grub updated" || log "update-grub skipped"
fi

# ---------------------------------------------------------------------------
# 8. desktop wallpaper + LightDM greeter (GUI SKU only)
# ---------------------------------------------------------------------------
if [[ -d "${SRC}/wallpaper" ]]; then
  install -d /usr/share/backgrounds/vacti
  cp -a "${SRC}/wallpaper/." /usr/share/backgrounds/vacti/ 2>/dev/null || true
  [[ -d "${SRC}/greeter" ]] && cp -a "${SRC}/greeter/." /usr/share/backgrounds/vacti/ 2>/dev/null || true
  rm -f /usr/share/backgrounds/vacti/*.svg /usr/share/backgrounds/vacti/*.conf 2>/dev/null || true
  log "wallpaper staged to /usr/share/backgrounds/vacti"
fi

# LightDM greeter theme: only when LightDM is present (GUI SKU)
if [[ -f "${SRC}/greeter/lightdm-gtk-greeter.conf" ]] && { [[ -d /etc/lightdm ]] || command -v lightdm >/dev/null 2>&1; }; then
  install -D -m0644 "${SRC}/greeter/lightdm-gtk-greeter.conf" /etc/lightdm/lightdm-gtk-greeter.conf
  log "lightdm greeter theme installed"
fi

# PRE-LOGIN GATE drop-in: withhold the desktop login until the box is enrolled
# (LightDM starts only once /etc/vacti-engine/engine.env exists). Installed ONLY
# when LightDM is present (GUI SKU); harmless/absent on headless. Co-located with
# the greeter theme so the gate + theme ship together, in BOTH the golden guest
# (virt-customize) and the ISO chroot (and thus the Calamares-installed system).
if [[ -f "${SRC}/greeter/lightdm.service.d/10-vacti-gate.conf" ]] && { [[ -d /etc/lightdm ]] || command -v lightdm >/dev/null 2>&1; }; then
  install -D -m0644 "${SRC}/greeter/lightdm.service.d/10-vacti-gate.conf" \
    /etc/systemd/system/lightdm.service.d/10-vacti-gate.conf
  log "lightdm pre-login gate drop-in installed (no desktop login until enrolled)"
fi

# ---------------------------------------------------------------------------
# 9. XFCE defaults (skel): wallpaper setter, dark theme, whisker panel
# ---------------------------------------------------------------------------
if [[ -d "${SRC}/xfce" ]]; then
  SKEL_XFCONF="/etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml"
  install -d "${SKEL_XFCONF}" /etc/skel/.config/autostart
  [[ -f "${SRC}/xfce/xfce4-panel.xml" ]] && install -m0644 "${SRC}/xfce/xfce4-panel.xml" "${SKEL_XFCONF}/xfce4-panel.xml"
  [[ -f "${SRC}/xfce/xsettings.xml" ]]   && install -m0644 "${SRC}/xfce/xsettings.xml"   "${SKEL_XFCONF}/xsettings.xml"
  [[ -f "${SRC}/xfce/autostart/vacti-wallpaper.desktop" ]] && install -m0644 "${SRC}/xfce/autostart/vacti-wallpaper.desktop" /etc/skel/.config/autostart/vacti-wallpaper.desktop
  [[ -f "${SRC}/xfce/vacti-set-wallpaper" ]] && install -D -m0755 "${SRC}/xfce/vacti-set-wallpaper" /usr/local/bin/vacti-set-wallpaper
  log "xfce skel defaults installed"
fi

# ---------------------------------------------------------------------------
# 10. a sensible default hostname (only if still the generic base default)
# ---------------------------------------------------------------------------
cur_host="$(cat /etc/hostname 2>/dev/null | tr -d '[:space:]')"
case "$cur_host" in
  ""|localhost|debian|localhost.localdomain)
    echo "vacti" > /etc/hostname
    if grep -qE '^127\.0\.1\.1' /etc/hosts 2>/dev/null; then
      sed -i -E "s/^127\.0\.1\.1.*/127.0.1.1\tvacti/" /etc/hosts
    else
      printf '127.0.1.1\tvacti\n' >> /etc/hosts
    fi
    log "default hostname set to vacti"
    ;;
  *) log "hostname kept (${cur_host})" ;;
esac

log "branding complete"
