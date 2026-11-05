#!/usr/bin/env bash
# build-iso.sh - the thin live-build driver. Materializes the SHARED distro/
# tree (package manifest + branding + enroll) into the live-build config/, then
# runs `lb config` + `lb build`. One source of truth: the exact same package
# list, branding assets, and firstboot unit the golden image bakes.
#
# HEAVY BUILD - RUNS IN CI (a debian:trixie --privileged container, for loop
# devices + mount), NOT on the prod control plane. Do NOT run on the prod box.
#
# THIN-BOOTSTRAP: the vacti-engine package is NOT baked into the ISO. The arsenal
# comes from public sources only (Debian + the pinned Kali repo), so no private apt
# repo and no build-time secret are used here; the engine .deb is pulled at first
# boot (vacti-engine-install.service) using the enrollment token.
#
# Usage: VACTI_ISO_SKU=headless|gui ./build-iso.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISTRO_DIR="$(cd "${HERE}/.." && pwd)"
# shellcheck source=/dev/null
source "${DISTRO_DIR}/vacti-appliance.env"
SKU="${VACTI_ISO_SKU:-headless}"

command -v lb >/dev/null 2>&1 || { echo "live-build (lb) not found (apt-get install live-build)" >&2; exit 1; }

echo "[iso] materializing the shared distro/ tree into config/ (SKU=${SKU})"

# 1. package list: generate vacti-core from the shared manifest (honors VACTI_FULL_ARSENAL),
#    then split out the BEST-EFFORT packages. The golden/OVA path (build-golden.sh)
#    and the engine's bootstrap-apt.sh install the arsenal best-effort per-package
#    ("no apt candidate = a warning, never an aborted bootstrap"); live-build instead
#    installs a package-list ALL-OR-NOTHING, so a name apt cannot locate (e.g.
#    globalprotect-openconnect, which is in NEITHER Debian 13 trixie NOR the pinned
#    Kali archive) aborts the WHOLE ISO build ("E: Unable to locate package ...") while
#    the identical OVA build only warns. To restore OVA/ISO parity, keep the hard
#    package-list to the resolvable packages and hand the best-effort set to
#    0330-vpn-besteffort.hook.chroot (same warn-and-continue semantics; runtime
#    arsenal-check self-heals any residual). packages/best-effort.list is the single
#    source for which arsenal packages may be absent.
CORE_LIST="${HERE}/config/package-lists/vacti-core.list.chroot"
BE_SRC="${DISTRO_DIR}/packages/best-effort.list"
"${DISTRO_DIR}/packages/gen-live-build-list.sh" "${CORE_LIST}"
# THIN-BOOTSTRAP: never bake the engine package into the ISO. The generated list
# is arsenal-only, but strip any vacti-engine* line defensively so a future
# manifest change can never pull the engine (and its plain-text IP) into the
# squashfs. The engine .deb is pulled at first boot by vacti-engine-install.service.
if [[ -f "$CORE_LIST" ]]; then
  grep -vE '^[[:space:]]*vacti-engine([[:space:]]|$)' "$CORE_LIST" > "${CORE_LIST}.tmp" || true
  mv -f "${CORE_LIST}.tmp" "$CORE_LIST"
fi
if [[ -f "$BE_SRC" ]]; then
  # stripped best-effort package names (drop comments + blank lines)
  BE_NAMES="$(sed -e 's/#.*$//' -e 's/[[:space:]]\+$//' "$BE_SRC" | grep -vE '^[[:space:]]*$' || true)"
  if [[ -n "$BE_NAMES" ]]; then
    # a) remove them from the hard package-list so live-build never hard-fails on an
    #    absent candidate (grep -vxF: exact whole-line, fixed-string match). `|| true`
    #    guards the grep exit-1 (empty result) case under `set -e`.
    grep -vxF -f <(printf '%s\n' "$BE_NAMES") "$CORE_LIST" > "${CORE_LIST}.tmp" || true
    mv -f "${CORE_LIST}.tmp" "$CORE_LIST"
    # b) stage the best-effort list into the build chroot for the hook. It lands
    #    under /opt/vacti-build (gitignored before_packages overlay) and is removed
    #    by the hook + 0900-remove-build-auth, so it never ships.
    BE_STAGE="${HERE}/config/includes.chroot_before_packages/opt/vacti-build"
    install -d "$BE_STAGE"
    printf '%s\n' "$BE_NAMES" > "${BE_STAGE}/best-effort.list"
    echo "[iso] best-effort packages moved to 0330 hook (not the hard list): $(printf '%s' "$BE_NAMES" | tr '\n' ' ')"
  fi
fi

# 2. branding assets -> includes.chroot (apply-branding.sh reads /usr/share/vacti/branding)
install -d "${HERE}/config/includes.chroot/usr/share/vacti/branding"
cp -a "${DISTRO_DIR}/branding/os-release" "${DISTRO_DIR}/branding/issue" \
      "${DISTRO_DIR}/branding/issue.net" \
      "${DISTRO_DIR}/branding/motd" "${DISTRO_DIR}/branding/disclaimer.txt" \
      "${DISTRO_DIR}/branding/apply-branding.sh" \
      "${HERE}/config/includes.chroot/usr/share/vacti/branding/"
for d in grub plymouth wallpaper greeter console fastfetch xfce profile.d logo kiosk; do
  [[ -d "${DISTRO_DIR}/branding/${d}" ]] && cp -a "${DISTRO_DIR}/branding/${d}" "${HERE}/config/includes.chroot/usr/share/vacti/branding/"
done
# GRUB boot-menu splash (binary overlay), if the operator provided one
[[ -f "${DISTRO_DIR}/branding/grub/splash.png" ]] && \
  install -D -m0644 "${DISTRO_DIR}/branding/grub/splash.png" "${HERE}/config/includes.binary/boot/grub/splash.png"

# 3. enroll: firstboot script + the ISO firstrun unit
install -D -m0755 "${DISTRO_DIR}/enroll/firstboot/vacti-firstboot" \
  "${HERE}/config/includes.chroot/usr/local/sbin/vacti-firstboot"
install -D -m0644 "${HERE}/config/includes.chroot/etc/systemd/system/vacti-firstrun.service" \
  "${HERE}/config/includes.chroot/etc/systemd/system/vacti-firstrun.service" 2>/dev/null || true

# 3a. THIN-BOOTSTRAP first-boot engine install: the unit + wrapper that pull the
#     vacti-engine .deb from the private apt repo at first boot (no engine baked).
#     Pulled by Wants=/After= from vacti-firstrun.service, so present-on-disk is
#     enough - no explicit enable.
install -D -m0755 "${DISTRO_DIR}/enroll/install/vacti-engine-install" \
  "${HERE}/config/includes.chroot/usr/local/sbin/vacti-engine-install"
install -D -m0644 "${DISTRO_DIR}/enroll/install/vacti-engine-install.service" \
  "${HERE}/config/includes.chroot/etc/systemd/system/vacti-engine-install.service"

# 3b. PRE-LOGIN activation (both SKUs ship the files; the GUI gate is wired by
#     the GUI package list + 0100-branding.hook.chroot + apply-branding.sh). On
#     the installed system these travel verbatim in the squashfs (Calamares
#     unpackfs), so the gate carries through to the installed box.
install -D -m0755 "${DISTRO_DIR}/enroll/activate/vacti-activate" \
  "${HERE}/config/includes.chroot/usr/local/sbin/vacti-activate"
# Premium GTK4 + libadwaita kiosk app (GUI SKU). Travels verbatim in the squashfs;
# vacti-activate invokes it when GTK4/libadwaita import, else falls back to yad.
install -D -m0755 "${DISTRO_DIR}/enroll/activate/vacti-kiosk" \
  "${HERE}/config/includes.chroot/usr/local/share/vacti-kiosk/vacti-kiosk"
install -D -m0644 "${DISTRO_DIR}/enroll/activate/vacti-activate.service" \
  "${HERE}/config/includes.chroot/etc/systemd/system/vacti-activate.service"
install -D -m0644 "${DISTRO_DIR}/enroll/activate/vacti-activate-fallback.service" \
  "${HERE}/config/includes.chroot/etc/systemd/system/vacti-activate-fallback.service"
install -D -m0644 "${DISTRO_DIR}/enroll/activate/vacti-activate-polkit.rules" \
  "${HERE}/config/includes.chroot/etc/polkit-1/rules.d/49-vacti-activate.rules"
# POST-ENROLL network panel: once enrolled, land on a NetworkManager settings
# console before the desktop login (GUI), or nmtui on the console (headless NM).
# The GUI unit is enabled by the 0100-branding hook (GUI SKU); the lightdm defer
# drop-in (15-vacti-netpanel.conf) is installed by apply-branding.sh.
install -D -m0755 "${DISTRO_DIR}/enroll/activate/vacti-netpanel" \
  "${HERE}/config/includes.chroot/usr/local/sbin/vacti-netpanel"
install -D -m0644 "${DISTRO_DIR}/enroll/activate/vacti-netpanel.service" \
  "${HERE}/config/includes.chroot/etc/systemd/system/vacti-netpanel.service"
install -D -m0644 "${DISTRO_DIR}/enroll/activate/vacti-netpanel-headless.service" \
  "${HERE}/config/includes.chroot/etc/systemd/system/vacti-netpanel-headless.service"
install -D -m0755 "${DISTRO_DIR}/enroll/netsetup/vacti-netsetup" \
  "${HERE}/config/includes.chroot/usr/local/sbin/vacti-netsetup"

# 4. GUI SKU gets the extra package list; headless does not
if [[ "$SKU" == "gui" ]]; then
  cp -f "${HERE}/config/package-lists/vacti-gui.list.chroot.in" "${HERE}/config/package-lists/vacti-gui.list.chroot"
else
  rm -f "${HERE}/config/package-lists/vacti-gui.list.chroot"
fi

# 4b. Headless NetworkManager opt-in (VACTI_HEADLESS_NM=1). Default 0 keeps
#     systemd-networkd + cloud-init (zero-touch seed) and is a no-op. When opted
#     in on the HEADLESS SKU, add network-manager to the package set and stage a
#     mask of systemd-networkd + an NM enable + the NetworkManager renderer so the
#     two renderers never fight. Symlinks in includes.chroot are preserved by
#     live-build. (The GUI SKU already ships network-manager-gnome; no-op there.)
if [[ "${VACTI_HEADLESS_NM:-0}" =~ ^(1|true|yes|on)$ && "$SKU" == "headless" ]]; then
  echo "[iso] VACTI_HEADLESS_NM=1 (headless) - adding NetworkManager, masking systemd-networkd"
  printf 'network-manager\n' > "${HERE}/config/package-lists/vacti-nm.list.chroot"
  install -d "${HERE}/config/includes.chroot/etc/systemd/system/multi-user.target.wants"
  ln -sf /dev/null                                   "${HERE}/config/includes.chroot/etc/systemd/system/systemd-networkd.service"
  ln -sf /lib/systemd/system/NetworkManager.service  "${HERE}/config/includes.chroot/etc/systemd/system/multi-user.target.wants/NetworkManager.service"
  install -d "${HERE}/config/includes.chroot/etc/cloud/cloud.cfg.d"
  printf 'system_info:\n  network:\n    renderers: [NetworkManager]\n' \
    > "${HERE}/config/includes.chroot/etc/cloud/cloud.cfg.d/99-vacti-nm.cfg"
  # POST-ENROLL nmtui console panel for the headless-NM SKU (graceful degradation of
  # the GUI panel). Enable it via a wants/ symlink that travels in the squashfs. The
  # unit is gated engine.env + !/etc/lightdm + no opt-out, so it is inert until the
  # box is enrolled; OnFailure=getty@tty1 keeps it fail-open.
  ln -sf /etc/systemd/system/vacti-netpanel-headless.service \
    "${HERE}/config/includes.chroot/etc/systemd/system/multi-user.target.wants/vacti-netpanel-headless.service"
else
  rm -f "${HERE}/config/package-lists/vacti-nm.list.chroot" 2>/dev/null || true
fi

# 5. THIN-BOOTSTRAP: no vacti private apt wiring at build time. The ISO never bakes
#    the vacti-engine package (no /usr/lib/vacti-engine, no prompt-bundle, no
#    skill-bundle - that plain-text methodology is the real IP and must not ride a
#    public download). The arsenal is installed from PUBLIC sources only (Debian +
#    the pinned Kali repo); the engine .deb is pulled at first boot by
#    vacti-engine-install.service using the enrollment token. So there is no
#    producer-token requirement, no build-chroot auth.conf, no [trusted=yes] private
#    source line, and no host-scoped TLS-verify-off to stage or strip here.
#    0900-remove-build-auth still runs as defense-in-depth (its removals are no-ops
#    now, since none of those files are created).

# 7. Kali package source key (Option A). The checked-in kali.list.chroot adds
#    the pinned Kali repo; live-build needs its signing key installed into the
#    build chroot BEFORE it apt-updates that source. The native, ordering-correct
#    way is a paired config/archives/kali.key.chroot (installed during
#    chroot_archives, ahead of the update) - an includes.chroot keyring lands too
#    late. Fetch the PUBLIC Kali archive key at build time (not a credential; the
#    exact key build-golden.sh uses). For Option B (VACTI_NO_KALI_REPO=1) drop the
#    Kali source entirely so no unsigned/unused repo lingers in the chroot.
if [[ "${VACTI_NO_KALI_REPO:-0}" =~ ^(1|true|yes|on)$ ]]; then
  echo "[iso] VACTI_NO_KALI_REPO set - removing the Kali apt source from the ISO config"
  rm -f "${HERE}/config/archives/kali.list.chroot" \
        "${HERE}/config/archives/kali.pref.chroot" \
        "${HERE}/config/archives/kali.key.chroot"
elif [[ -f "${HERE}/config/archives/kali.list.chroot" ]]; then
  echo "[iso] fetching the public Kali archive signing key -> config/archives/kali.key.chroot"
  if curl -fsSL --retry 3 https://archive.kali.org/archive-key.asc \
       -o "${HERE}/config/archives/kali.key.chroot"; then
    # Sanity: must be an ASCII-armored public key block, or live-build/apt will
    # reject the Kali source again. Fail loudly rather than build an unsigned repo.
    grep -q 'BEGIN PGP PUBLIC KEY BLOCK' "${HERE}/config/archives/kali.key.chroot" \
      || { echo "[iso][FATAL] fetched Kali key is not an armored public key block" >&2; exit 1; }
    echo "[iso] Kali archive key staged (armored, public)."
  else
    echo "[iso][FATAL] could not fetch the Kali archive signing key (needed to sign the pinned Kali source)" >&2
    exit 1
  fi
fi

cd "$HERE"
echo "[iso] lb config"
VACTI_ISO_SKU="$SKU" lb config

# Ensure ca-certificates (+ its openssl dep) is in the FIRST-stage debootstrap, so
# the chroot can TLS-verify any HTTPS apt source (the Debian mirror, and the
# first-boot vacti source the installed system wires later) - a minimal debootstrap
# has no CA store, and without it an HTTPS InRelease fetch fails. The
# `--bootstrap-include` CLI flag was dropped in this live-build, but the underlying
# LB_BOOTSTRAP_INCLUDE config variable (consumed by `lb bootstrap` ->
# debootstrap --include) is stable.
if [[ -f config/bootstrap ]]; then
  if grep -q '^LB_BOOTSTRAP_INCLUDE=' config/bootstrap; then
    sed -i 's/^LB_BOOTSTRAP_INCLUDE=.*/LB_BOOTSTRAP_INCLUDE="ca-certificates"/' config/bootstrap
  else
    echo 'LB_BOOTSTRAP_INCLUDE="ca-certificates"' >> config/bootstrap
  fi
  echo "[iso] set LB_BOOTSTRAP_INCLUDE=ca-certificates in config/bootstrap"
else
  echo "[iso][WARN] config/bootstrap not found after lb config; cannot pin ca-certificates into debootstrap" >&2
fi

# --- WORKAROUND (Debian trixie): live-build 1:20250505's installer_debian-installer
#     picks the FUSE runtime lib as:
#       if Check_package_available libfuse3-4 -> libfuse3-4 ; else -> libfuse3-3
#     trixie's fuse3 bumped its SONAME, so the shared-lib package is libfuse3-4
#     (3.17.x) - there is NO libfuse3-3 (and NO libfuse3-3t64) in trixie. With a
#     healthy chroot apt state the primary libfuse3-4 branch is taken, but the
#     stale fallback otherwise dies with "E: Unable to locate package libfuse3-3"
#     while the GUI SKU (--debian-installer live) builds the d-i package pool.
#     Defensively rewrite the stale name in the installed live-build scripts so
#     BOTH branches resolve to libfuse3-4. Best-effort + non-fatal (CI runs as
#     root, so the live-build tree is writable). Drop once upstream live-build
#     ships the corrected trixie name.
echo "[iso] patching live-build's stale libfuse3-3 d-i fallback -> libfuse3-4 (trixie SONAME bump)"
for _d in /usr/lib/live/build /usr/share/live; do
  [[ -d "$_d" ]] || continue
  while IFS= read -r _f; do
    [[ -w "$_f" ]] || continue
    if sed -i -E 's/\blibfuse3-3\b/libfuse3-4/g' "$_f" 2>/dev/null; then
      echo "[iso]   patched ${_f}"
    fi
  done < <(grep -rlE '\blibfuse3-3\b' "$_d" 2>/dev/null || true)
done

echo "[iso] lb build (this is the heavy step; CI only)"
lb build 2>&1 | tee build.log

ISO="$(ls -1 ./*.hybrid.iso 2>/dev/null | head -1 || true)"
[[ -n "$ISO" ]] && echo "[iso] built: ${ISO}" || echo "[iso] build finished; check build.log for the output image"
