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
# auth.conf `machine` must match the sources.list path by host+path-PREFIX, so
# derive it from the FULL repo URL (scheme stripped, /apt appended) - NOT host
# only - or apt never sends the credential (401 on the engine .deb pull).
APT_MACHINE="$(printf '%s/apt' "${VACTI_APT_URL%/}" | sed -E 's#^[a-z]+://##')"
umask 077
printf 'machine %s login vacti password %s\n' "$APT_MACHINE" "$VACTI_APT_PRODUCER_TOKEN" \
  > "${HERE}/config/includes.chroot/etc/apt/auth.conf.d/vacti-engine.conf"
umask 022
echo "[iso] NOTE: auth.conf staged into the BUILD chroot only; 0900-remove-build-auth deletes it before squashfs."

# 5b. BUILD-TIME TLS: the vacti source is [trusted=yes] (full build-time trust)
#     and HTTPS. A minimal debootstrap chroot does not reliably regenerate its
#     CA bundle before the first package-list apt update, so the vacti InRelease
#     fetch can fail "certificate verify failed" even though the cert is valid
#     (golden/virt-customize pulls the same URL fine). Scope-disable TLS verify
#     for the vacti HOST ONLY (Debian/Kali verification untouched). This file is
#     build-chroot only and stripped by 0900-remove-build-auth before squashfs,
#     so no weakened-TLS config ever ships.
APT_HOST="$(printf '%s' "${VACTI_APT_URL#*://}" | cut -d/ -f1)"
if [[ -n "$APT_HOST" ]]; then
  install -d "${HERE}/config/includes.chroot/etc/apt/apt.conf.d"
  cat > "${HERE}/config/includes.chroot/etc/apt/apt.conf.d/99vacti-build-notls.conf" <<EOF
// BUILD-TIME ONLY - removed by 0900-remove-build-auth before squashfs. Scoped
// to the vacti apt host (${APT_HOST}); the source is [trusted=yes]. Does NOT
// relax verification for Debian/Kali or ship on the image.
Acquire::https::${APT_HOST}::Verify-Peer "false";
Acquire::https::${APT_HOST}::Verify-Host "false";
EOF
  echo "[iso] staged build-only TLS-verify-off for ${APT_HOST} (stripped pre-squashfs)"
fi

# 6. MATERIALIZE the vacti private apt SOURCE line from VACTI_APT_URL. The
#    checked-in config/archives/vacti.list.chroot is only a static placeholder
#    (https://repo.vacti.example/apt); regenerate it here so the ISO chroot
#    pulls vacti-engine from the SAME host the auth.conf `machine` above was
#    derived from. Mirrors build-golden.sh's sources.list line exactly:
#      deb [trusted=yes] <VACTI_APT_URL>/apt ./
#    (no credential here - public source line; the token lives only in auth.conf
#    and is stripped pre-squashfs by 0900-remove-build-auth).
APT_SCHEME_HOST="${VACTI_APT_URL%/}"
install -d "${HERE}/config/archives"
printf '# Generated by build-iso.sh from VACTI_APT_URL (public source line; no creds).\n# The Basic-auth credential is in the build-chroot auth.conf and is removed by\n# 0900-remove-build-auth before squashfs. Mirrors build-golden.sh.\ndeb [trusted=yes] %s/apt ./\n' \
  "$APT_SCHEME_HOST" > "${HERE}/config/archives/vacti.list.chroot"
echo "[iso] materialized config/archives/vacti.list.chroot -> ${APT_SCHEME_HOST}/apt"

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

# Ensure ca-certificates (+ its openssl dep) is in the FIRST-stage debootstrap,
# so the chroot can TLS-verify the vacti private apt source (its-ai.site behind
# Cloudflare) on the very first apt update - a minimal debootstrap has no CA
# store, and without it the HTTPS InRelease fetch fails and vacti-engine can
# never be indexed ("held broken packages"). The `--bootstrap-include` CLI flag
# was dropped in this live-build, but the underlying LB_BOOTSTRAP_INCLUDE config
# variable (consumed by `lb bootstrap` -> debootstrap --include) is stable.
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
