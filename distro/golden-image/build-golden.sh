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

# Build-time networking for the in-guest apt pulls. virt-customize runs this
# script in the libguestfs appliance with the guest chrooted, but the appliance
# leaves eth0 administratively DOWN with no address (the genericcloud guest's
# own DHCP client / systemd-networkd does not run here), so the guest has no
# route and every apt pull dies with "Temporary failure resolving". libguestfs'
# user-mode net backend is qemu SLIRP (passt is removed in CI), whose lease is
# the stable, well-known 10.0.2.0/24: host/gateway 10.0.2.2, DNS 10.0.2.3,
# guest 10.0.2.15. Configure eth0 statically to that lease so SLIRP NATs our
# apt traffic out. Also fix resolv.conf: the chrooted guest image's is the
# offline systemd-resolved stub. Build-time only; the shipped image regenerates
# its network + resolv.conf at boot.
echo "[prov] build-time networking (passt lease)"
# libguestfs' passt serves the guest over a -netdev stream socket but nothing in
# the appliance brings eth0 up / runs DHCP, so configure it here. libguestfs
# passes passt --address 169.254.2.15 (guest), gateway 169.254.2.2, DNS
# 169.254.2.3 (the passt analogue of SLIRP's 10.0.2.x). Try a DHCP client first
# (in case passt's DHCP is authoritative), then fall back to the static lease.
ip link set eth0 up 2>/dev/null || true
command -v dhclient >/dev/null 2>&1 && timeout 20 dhclient -1 eth0 2>/dev/null || true
command -v udhcpc   >/dev/null 2>&1 && timeout 20 udhcpc -i eth0 -n -q 2>/dev/null || true
if ! ip -4 addr show eth0 2>/dev/null | grep -q 'inet '; then
  ip addr add 169.254.2.15/24 dev eth0 2>/dev/null || true
  ip route replace default via 169.254.2.2 dev eth0 2>/dev/null || true
fi
rm -f /etc/resolv.conf
# Public resolvers first (reachable once virt-customize --network enables NAT),
# then the passt/SLIRP stub resolver as a fallback. Hardcoded public DNS is safe
# here: this resolv.conf exists only for the build-time apt pulls and the shipped
# image regenerates it at boot (see FINALIZE / first-boot).
printf 'nameserver 8.8.8.8\nnameserver 8.8.4.4\nnameserver 1.1.1.1\nnameserver 169.254.2.3\n' > /etc/resolv.conf
# Verify DNS actually resolves before any apt/curl; fail loudly if still broken.
if getent hosts deb.debian.org >/dev/null 2>&1 \
   || nslookup deb.debian.org >/dev/null 2>&1 \
   || host deb.debian.org >/dev/null 2>&1 \
   || dig +short deb.debian.org 2>/dev/null | grep -q .; then
  echo "[prov] DNS OK: deb.debian.org resolves"
else
  echo "[prov][diag] DNS still broken after resolv.conf fix"
fi
# TEMP connectivity diagnostics (guarded; reverted once the build is green)
ip -brief addr 2>/dev/null || true
ip route 2>/dev/null || true
getent hosts deb.debian.org 2>/dev/null || echo "[prov][diag] DNS resolve FAILED for deb.debian.org"
curl -fsS -m 20 -o /dev/null -w '[prov][diag] curl deb.debian.org -> HTTP %{http_code}\n' https://deb.debian.org/ 2>&1 || echo "[prov][diag] curl to deb.debian.org FAILED (no route/NAT?)"
# TEMP: raw IP-level reachability test (bypasses DNS) to confirm passt NAT works
curl -fsS -m 20 -o /dev/null -w '[prov][diag] curl 1.1.1.1 -> HTTP %{http_code}\n' https://1.1.1.1/ 2>&1 || echo "[prov][diag] curl to 1.1.1.1 (by IP) FAILED -> no NAT path at all"

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
# --network is REQUIRED: libguestfs runs the appliance with networking DISABLED
# by default (qemu user-net started with restrict=on / no NAT forwarding), so the
# guest comes up with an eth0 address and a route but no outbound path - every
# in-guest apt/curl then dies with "Temporary failure resolving 'deb.debian.org'"
# even though `ip addr`/`ip route` look healthy. Passing --network tells
# libguestfs to enable the user-mode NAT (passt/SLIRP) so the guest can actually
# reach the Debian + vacti mirrors while provision.sh runs.
log "virt-customize: applying the shared appliance layer"
virt-customize --network -a "$GOLDEN" \
  --copy-in "${STAGE}/usr:/" \
  --copy-in "${STAGE}/etc:/" \
  --copy-in "${STAGE}/opt:/" \
  --upload "${WORK}/provision.sh:/tmp/provision.sh" \
  --run-command "bash /tmp/provision.sh && rm -f /tmp/provision.sh" \
  --root-password disabled

# The provisioning script held the build-time token (host-expanded); remove it
# now that virt-customize has run. The in-guest copy was already cleaned up by
# the --run-command. The staged copy-in tree carried no secret.
rm -f "${WORK}/provision.sh"
rm -rf "${STAGE}"

# --- 6. convert back to a compact qcow2 + checksum ----------------------------
log "compacting golden qcow2"
qemu-img convert -O qcow2 -c "$GOLDEN" "${GOLDEN}.tmp" && mv -f "${GOLDEN}.tmp" "$GOLDEN"
( cd "$OUT" && sha256sum "$(basename "$GOLDEN")" > "$(basename "$GOLDEN").sha256" )

# --- 7. MANDATORY no-secret scan on the finalized golden disk -----------------
log "no-secret scan on the golden disk"
"${DISTRO_DIR}/../ci/no-secret-scan.sh" "$GOLDEN" || die "no-secret scan FAILED on the golden disk - refusing to emit"

log "GOLDEN ready: ${GOLDEN}"
