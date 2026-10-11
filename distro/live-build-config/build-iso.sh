#!/usr/bin/env bash
# build-iso.sh - the thin live-build driver. Materializes the SHARED distro/
# tree (package manifest + branding + enroll) into the live-build config/, then
# runs `lb config` + `lb build`. One source of truth: the exact same package
# list, branding assets, and firstboot unit the golden image bakes.
#
# HEAVY BUILD - RUNS IN CI (a debian:trixie --privileged container, for loop
# devices + mount), NOT on the prod control plane. Do NOT run on the prod box.
#
# Build-time secret (NEVER baked): VACTI_APT_PRODUCER_TOKEN is injected into the
# build chroot's auth.conf by a config hook and removed by a late hook
# (0900-remove-build-auth) before the squashfs is made.
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

# 1. package list: generate vacti-core from the shared manifest (honors VACTI_FULL_ARSENAL)
"${DISTRO_DIR}/packages/gen-live-build-list.sh" "${HERE}/config/package-lists/vacti-core.list.chroot"

# 2. branding assets -> includes.chroot (apply-branding.sh reads /usr/share/vacti/branding)
install -d "${HERE}/config/includes.chroot/usr/share/vacti/branding"
cp -a "${DISTRO_DIR}/branding/os-release" "${DISTRO_DIR}/branding/issue" \
      "${DISTRO_DIR}/branding/motd" "${DISTRO_DIR}/branding/disclaimer.txt" \
      "${DISTRO_DIR}/branding/apply-branding.sh" \
      "${HERE}/config/includes.chroot/usr/share/vacti/branding/"
for d in grub plymouth wallpaper; do
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

# 4. GUI SKU gets the extra package list; headless does not
if [[ "$SKU" == "gui" ]]; then
  cp -f "${HERE}/config/package-lists/vacti-gui.list.chroot.in" "${HERE}/config/package-lists/vacti-gui.list.chroot"
else
  rm -f "${HERE}/config/package-lists/vacti-gui.list.chroot"
fi

# 5. the build-time apt credential (NOT baked): write it only into the build
#    chroot via an archives hook; 0900-remove-build-auth strips it pre-squashfs.
[[ -n "${VACTI_APT_PRODUCER_TOKEN:-}" ]] || { echo "VACTI_APT_PRODUCER_TOKEN unset (needed at build to pull vacti-engine; never baked)" >&2; exit 1; }
install -d "${HERE}/config/includes.chroot/etc/apt/auth.conf.d"
APT_AUTHORITY="$(printf '%s' "${VACTI_APT_URL%/}" | sed -E 's#^[a-z]+://([^/]+).*#\1#')"
umask 077
printf 'machine %s/apt login vacti password %s\n' "$APT_AUTHORITY" "$VACTI_APT_PRODUCER_TOKEN" \
  > "${HERE}/config/includes.chroot/etc/apt/auth.conf.d/vacti-engine.conf"
umask 022
echo "[iso] NOTE: auth.conf staged into the BUILD chroot only; 0900-remove-build-auth deletes it before squashfs."

cd "$HERE"
echo "[iso] lb config"
VACTI_ISO_SKU="$SKU" lb config
echo "[iso] lb build (this is the heavy step; CI only)"
lb build 2>&1 | tee build.log

ISO="$(ls -1 ./*.hybrid.iso 2>/dev/null | head -1 || true)"
[[ -n "$ISO" ]] && echo "[iso] built: ${ISO}" || echo "[iso] build finished; check build.log for the output image"
