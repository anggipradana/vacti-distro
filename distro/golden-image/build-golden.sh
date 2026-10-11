#!/usr/bin/env bash
# build-golden.sh - build the GOLDEN disk: the single source of truth for the
# cloud and VM forms. Fetches + verifies the official Debian 13 genericcloud
# qcow2, then applies the shared appliance layer with virt-customize and emits
# vacti-engine-<ver>-golden.qcow2. convert-*.sh / fanout.sh repackage this one
# disk into every target format so cloud / VMware OVA / VBox OVA are the same
# engine bit-for-bit.
#
# HEAVY BUILD - RUNS IN CI (GitHub Actions), NOT on the prod control plane.
# Requires root-ish libguestfs (virt-customize) and network to the Debian mirror
# + the vacti private apt repo. Do NOT run on the prod box.
#
# Build-time secret (NEVER baked): VACTI_APT_PRODUCER_TOKEN must be set in the
# environment; it is written to an auth.conf used ONLY during the build and is
# removed before the disk is finalized. No enroll/engine/tailscale secret is
# ever written to the golden disk.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISTRO_DIR="$(cd "${HERE}/.." && pwd)"
# shellcheck source=/dev/null
source "${DISTRO_DIR}/vacti-appliance.env"

PKG_DIR="${DISTRO_DIR}/packages"
BRAND_DIR="${DISTRO_DIR}/branding"
ENROLL_DIR="${DISTRO_DIR}/enroll"
WORK="${WORK:-${DISTRO_DIR}/.build/golden}"
CACHE="${CACHE:-${DISTRO_DIR}/.build/cache}"
OUT="${OUT_DIR:-${DISTRO_DIR}/out}"
GOLDEN="${OUT}/vacti-engine-${VACTI_RELEASE}-golden.qcow2"

log() { echo "[golden] $*"; }
die() { echo "[golden][FATAL] $*" >&2; exit 1; }

command -v virt-customize >/dev/null 2>&1 || die "virt-customize not found (apt-get install libguestfs-tools)"
command -v qemu-img       >/dev/null 2>&1 || die "qemu-img not found (apt-get install qemu-utils)"
[[ -n "${VACTI_APT_PRODUCER_TOKEN:-}" ]] || die "VACTI_APT_PRODUCER_TOKEN unset - the build-time private-repo credential is required (it is NOT baked into the image)"

mkdir -p "$WORK" "$CACHE" "$OUT"

# --- 1. fetch + verify the official Debian cloud image ------------------------
BASE_IMG="${CACHE}/${DEBIAN_CLOUD_IMAGE}"
SUMS="${CACHE}/${DEBIAN_CLOUD_SHA512SUMS}"
if [[ ! -f "$BASE_IMG" ]]; then
  log "fetching ${DEBIAN_CLOUD_IMAGE}"
  curl -fSL --retry 3 -o "$BASE_IMG" "${DEBIAN_CLOUD_BASEURL}/${DEBIAN_CLOUD_IMAGE}"
fi
log "fetching ${DEBIAN_CLOUD_SHA512SUMS}"
curl -fSL --retry 3 -o "$SUMS" "${DEBIAN_CLOUD_BASEURL}/${DEBIAN_CLOUD_SHA512SUMS}"
log "verifying SHA512 of the base image"
( cd "$CACHE" && grep " ${DEBIAN_CLOUD_IMAGE}\$" "$DEBIAN_CLOUD_SHA512SUMS" | sha512sum -c - ) \
  || die "base image SHA512 verification FAILED - refusing to build on an unverified base"

# --- 2. working copy ----------------------------------------------------------
log "copying base -> working golden disk"
cp -f "$BASE_IMG" "$GOLDEN"
# Give the appliance room (engine + arsenal). genericcloud is ~2GB sparse.
qemu-img resize "$GOLDEN" 20G >/dev/null

# --- 3. stage the shared appliance inputs into a copy-in root -----------------
STAGE="${WORK}/stage"
rm -rf "$STAGE"; mkdir -p \
  "${STAGE}/usr/share/vacti/branding" \
  "${STAGE}/usr/local/sbin" \
  "${STAGE}/etc/systemd/system" \
  "${STAGE}/opt/vacti-build"
# branding assets -> /usr/share/vacti/branding (apply-branding.sh reads these)
cp -a "${BRAND_DIR}/os-release" "${BRAND_DIR}/issue" "${BRAND_DIR}/motd" \
      "${BRAND_DIR}/disclaimer.txt" "${STAGE}/usr/share/vacti/branding/"
for d in grub plymouth wallpaper; do
  [[ -d "${BRAND_DIR}/${d}" ]] && cp -a "${BRAND_DIR}/${d}" "${STAGE}/usr/share/vacti/branding/"
done
cp -a "${BRAND_DIR}/apply-branding.sh" "${STAGE}/opt/vacti-build/apply-branding.sh"
# firstboot unit + script
cp -a "${ENROLL_DIR}/firstboot/vacti-firstboot"          "${STAGE}/usr/local/sbin/vacti-firstboot"
cp -a "${ENROLL_DIR}/firstboot/vacti-firstboot.service"  "${STAGE}/etc/systemd/system/vacti-firstboot.service"
# resolve the arsenal list for this build flavour
"${PKG_DIR}/gen-live-build-list.sh" "${STAGE}/opt/vacti-build/arsenal.list"
# kali repo files (Option A)
if [[ ! "${VACTI_NO_KALI_REPO}" =~ ^(1|true|yes|on)$ ]]; then
  mkdir -p "${STAGE}/opt/vacti-build/kali-repo"
  cp -a "${PKG_DIR}/kali-repo/kali.list" "${PKG_DIR}/kali-repo/kali-pin.pref" "${STAGE}/opt/vacti-build/kali-repo/"
fi
chmod 0755 "${STAGE}/usr/local/sbin/vacti-firstboot" "${STAGE}/opt/vacti-build/apply-branding.sh"

# --- 4. the provisioning script that runs INSIDE the guest --------------------
# Build-time apt wiring (source + auth.conf) is written here and REMOVED before
# finalize. Mirrors the engine bootstrap-apt.sh configure_apt exactly.
# auth.conf `machine` must match the sources.list path by host+path-PREFIX, so
# derive it from the FULL repo URL (scheme stripped, /apt appended) - NOT host
# only. VACTI_APT_URL=https://its-ai.site/api/pentest -> its-ai.site/api/pentest/apt
# which is a prefix of the sources path its-ai.site/api/pentest/apt (match).
APT_MACHINE="$(printf '%s/apt' "${VACTI_APT_URL%/}" | sed -E 's#^[a-z]+://##')"
APT_SCHEME_HOST="${VACTI_APT_URL%/}"
cat > "${WORK}/provision.sh" <<PROV
#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "[prov] base deps"
apt-get update -y
apt-get install -y --no-install-recommends ca-certificates curl gnupg jq

# Option A: Kali apt source, pinned prio 100 (package source only, no branding)
if [[ -d /opt/vacti-build/kali-repo ]]; then
  echo "[prov] adding pinned Kali apt source (prio 100)"
  curl -fsSL https://archive.kali.org/archive-key.asc | gpg --dearmor -o /usr/share/keyrings/kali-archive-keyring.gpg
  install -m0644 /opt/vacti-build/kali-repo/kali.list     /etc/apt/sources.list.d/kali.list
  install -m0644 /opt/vacti-build/kali-repo/kali-pin.pref /etc/apt/preferences.d/kali-pin
fi

# vacti private apt source + BUILD-TIME auth.conf (removed before finalize)
echo "[prov] wiring vacti apt source (build-time credential, not baked)"
install -d -m0755 /etc/apt/auth.conf.d
umask 077
# NOTE: the token is expanded by the HOST into this build-only script (which
# lives under .build/, is gitignored, and is shredded by build-golden.sh when
# virt-customize returns). It is written to auth.conf INSIDE the guest only for
# the apt pull and removed by FINALIZE below; the no-secret scan re-verifies.
printf 'machine %s login vacti password %s\n' "${APT_MACHINE}" "${VACTI_APT_PRODUCER_TOKEN}" > /etc/apt/auth.conf.d/vacti-engine.conf
chmod 0600 /etc/apt/auth.conf.d/vacti-engine.conf
umask 022
printf 'deb [trusted=yes] %s/apt ./\n' "${APT_SCHEME_HOST}" > /etc/apt/sources.list.d/vacti-engine.list

apt-get update -y

# the engine + the arsenal + the pinned Chromium
echo "[prov] installing ${VACTI_ENGINE_PKG} + arsenal"
mapfile -t PKGS < <(grep -vE '^[[:space:]]*(#|\$)' /opt/vacti-build/arsenal.list)
apt-get install -y --no-install-recommends ${VACTI_ENGINE_PKG} "\${PKGS[@]}" || {
  echo "[prov] bulk install hit a snag; retrying best-effort per-package for the arsenal"
  apt-get install -y --no-install-recommends ${VACTI_ENGINE_PKG}
  for p in "\${PKGS[@]}"; do apt-get install -y --no-install-recommends "\$p" || echo "[prov][warn] \$p not installable here (runtime self-heal will cover it)"; done
}

# guest integration (both hypervisors coexist in one rootfs) + tailscale client
echo "[prov] guest tools + tailscale client (no auth key baked)"
apt-get install -y --no-install-recommends open-vm-tools virtualbox-guest-utils || echo "[prov][warn] guest tools partial"
curl -fsSL https://tailscale.com/install.sh | sh || echo "[prov][warn] tailscale install deferred to runtime"
systemctl enable tailscaled 2>/dev/null || true

# branding
echo "[prov] branding"
/opt/vacti-build/apply-branding.sh || echo "[prov][warn] branding partial"

# enable the first-boot enroll unit (no token baked; it fails loudly without one)
systemctl enable vacti-firstboot.service 2>/dev/null || true

# ---- FINALIZE: strip every build-time secret + identity --------------------
echo "[prov] FINALIZE: removing build-time apt credential + identity"
rm -f /etc/apt/auth.conf.d/vacti-engine.conf
rm -rf /opt/vacti-build
# never ship methodology/config on disk
rm -rf /root/.claude /home/*/.claude /etc/vacti-engine/.claude 2>/dev/null || true
# zero identity so every boot is fresh
: > /etc/machine-id
rm -f /var/lib/dbus/machine-id 2>/dev/null || true
ln -sf /etc/machine-id /var/lib/dbus/machine-id 2>/dev/null || true
rm -f /etc/ssh/ssh_host_* 2>/dev/null || true
# clean apt lists + logs
apt-get clean
rm -rf /var/lib/apt/lists/* /var/log/apt/* /tmp/* /var/tmp/* 2>/dev/null || true
# assert no engine.env / token file leaked in
rm -f /etc/vacti-engine/engine.env /etc/vacti-engine/enroll.token 2>/dev/null || true
echo "[prov] done"
PROV
chmod 0755 "${WORK}/provision.sh"

# --- 5. apply the appliance layer with virt-customize -------------------------
log "virt-customize: applying the shared appliance layer"
virt-customize -a "$GOLDEN" \
  --copy-in "${STAGE}/usr:/" \
  --copy-in "${STAGE}/etc:/" \
  --copy-in "${STAGE}/opt:/" \
  --run "${WORK}/provision.sh" \
  --root-password disabled

# The provisioning script held the build-time token (host-expanded); shred it
# now that virt-customize has run. The staged copy-in tree carried no secret.
shred -u "${WORK}/provision.sh" 2>/dev/null || rm -f "${WORK}/provision.sh"
rm -rf "${STAGE}"

# --- 6. convert back to a compact qcow2 + checksum ----------------------------
log "compacting golden qcow2"
qemu-img convert -O qcow2 -c "$GOLDEN" "${GOLDEN}.tmp" && mv -f "${GOLDEN}.tmp" "$GOLDEN"
( cd "$OUT" && sha256sum "$(basename "$GOLDEN")" > "$(basename "$GOLDEN").sha256" )

# --- 7. MANDATORY no-secret scan on the finalized golden disk -----------------
log "no-secret scan on the golden disk"
"${DISTRO_DIR}/../ci/no-secret-scan.sh" "$GOLDEN" || die "no-secret scan FAILED on the golden disk - refusing to emit"

log "GOLDEN ready: ${GOLDEN}"
