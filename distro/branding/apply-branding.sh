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

# plymouth-quit-wait hang guard (GUI pre-login gate). On a normal GUI boot the
# display manager quits plymouth; the vacti gate WITHHOLDS LightDM until the box
# is enrolled, so nothing quits plymouth and plymouth-quit-wait.service waits
# "no limit" -> graphical.target is never reached -> the activation kiosk never
# starts (and its fail-open fallback never runs). Bound that wait so the splash
# can NEVER hang the boot (works-everywhere; a display-less / broken-GPU box must
# still progress). On a normal post-enrollment boot LightDM quits plymouth well
# under this cap, so the timeout is inert. Installed only where plymouth exists.
if command -v plymouth >/dev/null 2>&1 || [[ -d /usr/share/plymouth ]]; then
  install -d /etc/systemd/system/plymouth-quit-wait.service.d
  cat > /etc/systemd/system/plymouth-quit-wait.service.d/10-vacti-timeout.conf <<'EOF'
# vacti: never let the boot splash wait block graphical.target forever. The
# pre-login gate withholds the display manager (which normally quits plymouth),
# so cap the wait; on timeout the boot proceeds and the activation kiosk starts.
[Service]
TimeoutStartSec=45
EOF
  log "plymouth-quit-wait timeout guard installed (pre-login gate)"
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
  # the greeter dir also carries the L1 polkit rule source; it belongs only in
  # /etc/polkit-1/rules.d (section 11), never in the wallpaper dir
  rm -rf /usr/share/backgrounds/vacti/polkit 2>/dev/null || true
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
  # Additive POST-ENROLL defer drop-in: once enrolled, vacti-netpanel.service owns
  # tty1 first and LightDM defers while the panel holds /run/vacti-netpanel.active.
  # SEPARATE file from 10-vacti-gate.conf; does NOT touch/weaken the engine.env gate.
  if [[ -f "${SRC}/greeter/lightdm.service.d/15-vacti-netpanel.conf" ]]; then
    install -D -m0644 "${SRC}/greeter/lightdm.service.d/15-vacti-netpanel.conf" \
      /etc/systemd/system/lightdm.service.d/15-vacti-netpanel.conf
    log "lightdm post-enroll network-panel defer drop-in installed (falls through to the desktop login)"
  fi
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
# 9b. premium activation kiosk brand skin (GUI SKU). The GTK4 + libadwaita kiosk
#     app itself is installed by build-golden under /usr/local/share/vacti-kiosk;
#     here we install its brand CSS beside it. Fail-soft: the kiosk renders the
#     stock dark theme if this is absent, and a headless image simply never runs it.
# ---------------------------------------------------------------------------
if [[ -f "${SRC}/kiosk/vacti-kiosk.css" ]]; then
  install -D -m0644 "${SRC}/kiosk/vacti-kiosk.css" /usr/local/share/vacti-kiosk/vacti-kiosk.css
  log "kiosk brand CSS installed"
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

# ---------------------------------------------------------------------------
# 11. console / power lockdown (B3 GREEN subset): L1 polkit power rule, L2
#     Ctrl-Alt-Del, L3 SysRq, L6 getty tty2-6, L7 serial-getty per SKU.
#     Same file for the golden guest, the ISO chroot (and so the Calamares
#     install), and a retrofit re-run on a live host.
#     IDEMPOTENT: install -D rewrites identical bytes; masking a masked unit is a
#     no-op; nothing gets appended. BREAK-GLASS PRESERVED: tty1 is never touched
#     (getty@tty1 is the kiosk/netpanel fail-open target), and neither is the
#     getty@.service template. SSH and the engine's root `sudo -n` path don't use
#     polkit/VTs. The hypervisor serial console stays up by default
#     (VACTI_SERIAL_GETTY=keep). NEVER restarts logind/lightdm/getty live:
#     manager/VT changes take effect at the next boot (R2d rule A1).
# ---------------------------------------------------------------------------
# true when this run is NOT the booted system (live-build chroot, virt-customize
# guest chroot) or is a container. Then live kernel/systemd changes are skipped:
# a chroot's /proc belongs to the BUILD HOST, so `sysctl -p` would change the
# CI runner, not the image.
not_live_host() {
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    systemd-detect-virt --chroot -q 2>/dev/null && return 0
    systemd-detect-virt --container -q 2>/dev/null && return 0
    return 1
  fi
  [[ "$(stat -c %d:%i / 2>/dev/null)" != "$(stat -c %d:%i /proc/1/root/. 2>/dev/null)" ]]
}
# mask a unit: systemctl when present (works offline in a chroot), else the
# equivalent /etc symlink to /dev/null. Never fails the branding run.
mask_unit() { # unit
  systemctl mask "$1" >/dev/null 2>&1 && return 0
  install -d /etc/systemd/system 2>/dev/null && ln -sfn /dev/null "/etc/systemd/system/$1" 2>/dev/null || true
}
# a lockdown knob: env var first, else the build-time value that build-golden.sh /
# build-iso.sh record in ${SRC}/lockdown.env (parsed, never sourced).
lockdown_knob() { # name default
  local v="${!1:-}"
  if [[ -z "$v" && -f "${SRC}/lockdown.env" ]]; then
    v="$(sed -n "s/^$1=//p" "${SRC}/lockdown.env" | tail -n1 | tr -d "\"'" \
         | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  fi
  printf '%s' "${v:-$2}"
}

# Opt-out latches. The operator revert tool (vacti-undo-tty-mask / vacti-lockdown-undo,
# installed below) writes /etc/vacti-lockdown/<layer>.optout, so a re-run does not
# re-apply a layer the operator deliberately reverted.
LATCH_DIR="/etc/vacti-lockdown"

# L1: polkit admin-auth for logind power actions from non-admin local subjects.
# Installed on BOTH SKUs: headless also has a tty1 console seat. The ~power drop
# itself lives in the greeter template above (section 8).
if [[ -f "${LATCH_DIR}/l1-power.optout" ]]; then
  # operator reverted L1: keep the rule off and put ~power back after section 8
  # reinstalled the template (same edit the revert tool makes)
  if [[ -f /etc/lightdm/lightdm-gtk-greeter.conf ]] \
     && ! grep -qE '^indicators *=.*~power' /etc/lightdm/lightdm-gtk-greeter.conf; then
    sed -i -E 's/^(indicators *=.*[^;[:space:]])[;[:space:]]*$/\1;~power/' /etc/lightdm/lightdm-gtk-greeter.conf || true
  fi
  log "L1 skipped (operator opt-out latch present; greeter ~power kept)"
elif [[ -f "${SRC}/greeter/polkit/10-vacti-lockdown.rules" ]]; then
  install -D -m0644 "${SRC}/greeter/polkit/10-vacti-lockdown.rules" /etc/polkit-1/rules.d/10-vacti-lockdown.rules
  log "L1 polkit power lockdown rule installed (non-admin seats need admin auth to power off/reboot)"
fi

# L2: Ctrl-Alt-Del -> nothing (target masked + 7-press burst disabled).
if [[ -f "${LATCH_DIR}/l2-cad.optout" ]]; then
  log "L2 skipped (operator opt-out latch present)"
elif [[ -f "${SRC}/console/ctrl-alt-del.conf" ]]; then
  install -D -m0644 "${SRC}/console/ctrl-alt-del.conf" /etc/systemd/system.conf.d/10-vacti-cad.conf
  mask_unit ctrl-alt-del.target
  log "L2 ctrl-alt-del.target masked + CtrlAltDelBurstAction=none (manager drop-in active at next boot)"
fi

# L3: SysRq off. Live-apply ONLY this one file, ONLY on a booted host (never in a
# build chroot). Every other sysctl.d file is left alone, so no `sysctl --system`.
if [[ -f "${LATCH_DIR}/l3-sysrq.optout" ]]; then
  log "L3 skipped (operator opt-out latch present)"
elif [[ -f "${SRC}/console/90-vacti-sysrq.conf" ]]; then
  install -D -m0644 "${SRC}/console/90-vacti-sysrq.conf" /etc/sysctl.d/90-vacti-sysrq.conf
  if ! not_live_host; then
    sysctl -q -p /etc/sysctl.d/90-vacti-sysrq.conf >/dev/null 2>&1 || true
  fi
  log "L3 kernel.sysrq=0 installed"
fi

# L6: blank VTs on Ctrl-Alt-F2..F6. Mask getty@ + autovt@ tty2..6 (autovt is what
# logind spawns on a VT switch). NOT tty1, NOT the template. A running getty is
# not stopped (an operator may be logged in on it); the mask applies on the next
# spawn or boot. Opt-out latch: vacti-undo-tty-mask (L6/L7 revert) writes
# /etc/vacti-lockdown/tty-mask.optout so a re-run does not re-mask.
if [[ -f "${LATCH_DIR}/tty-mask.optout" ]]; then
  log "L6 tty2-6 mask skipped (operator opt-out latch present)"
else
  for i in 2 3 4 5 6; do
    mask_unit "getty@tty${i}.service"
    mask_unit "autovt@tty${i}.service"
  done
  log "L6 getty/autovt tty2-6 masked (tty1 + getty@.service template untouched)"
fi

# L7: serial-getty per SKU. keep (DEFAULT) = no change: the hypervisor serial
# console stays a break-glass login and CI smoke-boot keeps its ttyS0 prompt.
# mask = force-mask (physical appliance). auto = mask only when this run is on
# a booted bare-metal host (systemd-detect-virt --vm == none). In a build chroot
# the SKU can't be detected, so auto resolves to keep there.
serial_mode="$(lockdown_knob VACTI_SERIAL_GETTY keep)"
serial_ports="$(lockdown_knob VACTI_SERIAL_GETTY_PORTS 'ttyS0 ttyAMA0')"
serial_do_mask=0
case "$serial_mode" in
  keep) log "L7 serial-getty kept (VACTI_SERIAL_GETTY=keep; hypervisor break-glass preserved)" ;;
  mask) serial_do_mask=1 ;;
  auto)
    if ! not_live_host && command -v systemd-detect-virt >/dev/null 2>&1 \
       && [[ "$(systemd-detect-virt --vm 2>/dev/null || true)" == "none" ]]; then
      serial_do_mask=1
    else
      log "L7 serial-getty kept (VACTI_SERIAL_GETTY=auto: VM, container or build chroot)"
    fi
    ;;
  *) log "L7 serial-getty kept (unknown VACTI_SERIAL_GETTY='${serial_mode}'; expected keep|mask|auto)" ;;
esac
if [[ "$serial_do_mask" -eq 1 ]]; then
  if [[ -f "${LATCH_DIR}/tty-mask.optout" ]]; then
    log "L7 serial-getty mask skipped (operator opt-out latch present)"
  else
    for port in $serial_ports; do
      [[ "$port" =~ ^[A-Za-z0-9]+$ ]] || continue
      mask_unit "serial-getty@${port}.service"
    done
    log "L7 serial-getty masked on: ${serial_ports} (VACTI_SERIAL_GETTY=${serial_mode})"
  fi
fi

# Operator revert tool for the layers above: default = L6/L7 VT/serial masks;
# `power|cad|sysrq|all` revert L1/L2/L3 as well. Every revert latches an opt-out.
if [[ -f "${SRC}/scripts/undo-tty-mask.sh" ]]; then
  install -D -m0755 "${SRC}/scripts/undo-tty-mask.sh" /usr/local/sbin/vacti-undo-tty-mask
  ln -sfn vacti-undo-tty-mask /usr/local/sbin/vacti-lockdown-undo
  log "vacti-undo-tty-mask (+ vacti-lockdown-undo) installed (per-layer revert + opt-out latch)"
fi

log "branding complete"
