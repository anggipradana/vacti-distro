#!/usr/bin/env bash
# build-skin-deb.sh - build vacti-appliance-skin_<ver>_all.deb.
#
# Architecture: all, no compiled code. debian/rules copies the branding tree from the
# single source of truth (distro/branding) at build time and forces -Zgzip (the CP apt
# indexer reads control.tar.gz with zlib; zstd/xz would index empty). Output: dist-skin/.
#
# Uses dpkg-buildpackage when debhelper is present; otherwise falls back to a pure
# dpkg-deb assembly that produces a byte-compatible package (same payload, same -Zgzip),
# so the .deb builds on a runner without the full Debian build toolchain.
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
OUT="${HERE}/dist-skin"
VERSION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --version)
      VERSION="${2:-}"
      shift
      ;;
    --out)
      OUT="${2:-}"
      shift
      ;;
    *)
      echo "usage: build-skin-deb.sh [--version X.Y.Z-R] [--out DIR]" >&2
      exit 2
      ;;
  esac
  shift
done

cd "$HERE"
[ -f debian/control ] || {
  echo "debian/control not found in ${HERE}" >&2
  exit 1
}
[ -d ../branding ] || {
  echo "../branding (distro/branding) not found; wrong tree?" >&2
  exit 1
}

if [ -n "$VERSION" ]; then
  if ! head -1 debian/changelog | grep -qF "($VERSION)"; then
    echo "WARNING: requested version ${VERSION} != changelog $(dpkg-parsechangelog -S Version 2>/dev/null || head -1 debian/changelog)" >&2
  fi
fi
PKGVER="$(dpkg-parsechangelog -S Version 2>/dev/null || echo "${VERSION:-0.1.0-1}")"
SRCREV="$(git -C .. rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
mkdir -p "$OUT"

if command -v dpkg-buildpackage >/dev/null 2>&1 && command -v dh >/dev/null 2>&1; then
  echo "== building with dpkg-buildpackage =="
  dpkg-buildpackage -us -uc -b -tc
  mv -f ../"vacti-appliance-skin_${PKGVER}_all.deb" "$OUT"/ 2>/dev/null ||
    mv -f ../vacti-appliance-skin_*_all.deb "$OUT"/
  rm -f ../vacti-appliance-skin_*.buildinfo ../vacti-appliance-skin_*.changes 2>/dev/null || true
else
  echo "== debhelper absent: pure dpkg-deb assembly =="
  STAGE="$(mktemp -d)"
  trap 'rm -rf "$STAGE"' EXIT
  LX="${STAGE}/usr/libexec/vacti-appliance-skin"
  SH="${STAGE}/usr/share/vacti-appliance-skin"
  install -d "$LX" "$SH" "${STAGE}/usr/sbin" "${STAGE}/usr/lib/systemd/system" \
    "${STAGE}/usr/share/doc/vacti-appliance-skin" "${STAGE}/DEBIAN"
  for f in apply.sh remove.sh migrate-user.sh auto-revert.sh ctl.sh skin-lib.sh; do
    install -m 0755 "$f" "${LX}/$f"
  done
  cp -a ../branding "$SH"/branding
  chmod 0755 "$SH"/branding/apply-branding.sh
  printf '%s\n' "$PKGVER" > "$SH"/VERSION
  printf 'vacti-distro %s (distro/branding + distro/appliance-skin)\n' "$SRCREV" > "$SH"/SOURCE
  install -m 0644 README.md "${STAGE}/usr/share/doc/vacti-appliance-skin/README.md"
  install -m 0644 auto-revert.timer "${STAGE}/usr/lib/systemd/system/vacti-appliance-skin-auto-revert.timer"
  install -m 0644 auto-revert.service "${STAGE}/usr/lib/systemd/system/vacti-appliance-skin-auto-revert.service"
  ln -sf ../libexec/vacti-appliance-skin/ctl.sh "${STAGE}/usr/sbin/vacti-appliance-skin"
  # Binary control paragraph for dpkg-deb: debian/control (dh source format) splits fields
  # across a Source and a Binary paragraph, so synthesise a complete single paragraph with
  # the required binary fields. Field values are pulled from debian/control by name.
  cf() { awk -v k="$1" 'BEGIN{IGNORECASE=0} $0 ~ "^"k": " {sub("^"k": ",""); print; exit}' debian/control; }
  desc_block() { awk '/^Description: / {p=1} p && /^[^ ]/ && !/^Description: / {exit} p {print}' debian/control; }
  {
    echo "Package: $(cf Package)"
    echo "Version: ${PKGVER}"
    echo "Architecture: $(cf Architecture)"
    echo "Maintainer: $(cf Maintainer)"
    echo "Section: $(cf Section)"
    echo "Priority: $(cf Priority)"
    echo "Depends: $(cf Depends | sed 's/, \${misc:Depends}//; s/\${misc:Depends}//')"
    echo "Recommends: $(cf Recommends)"
    echo "Provides: $(cf Provides)"
    desc_block
  } > "${STAGE}/DEBIAN/control"
  for s in postinst prerm postrm; do
    sed '/#DEBHELPER#/d' "debian/$s" > "${STAGE}/DEBIAN/$s"
    chmod 0755 "${STAGE}/DEBIAN/$s"
  done
  ( cd "$STAGE" && find . -type f ! -path './DEBIAN/*' -printf '%P\0' | xargs -0 md5sum ) \
    > "${STAGE}/DEBIAN/md5sums" 2>/dev/null || true
  dpkg-deb -Zgzip --root-owner-group --build "$STAGE" "${OUT}/vacti-appliance-skin_${PKGVER}_all.deb"
fi

DEB="$(ls -1 "${OUT}"/vacti-appliance-skin_*_all.deb | head -1)"
echo "== built: ${DEB} =="
dpkg-deb -I "$DEB" | sed -n '1,30p'
# fail closed if the control tarball is not gzip (the CP indexer requirement). Capture the
# member list first: `ar t | grep -q` would SIGPIPE `ar` and trip `set -o pipefail`.
AR_MEMBERS="$(ar t "$DEB")"
grep -q '^control.tar.gz$' <<<"$AR_MEMBERS" || {
  echo "ERROR: control tarball is not control.tar.gz (need -Zgzip for the CP indexer)" >&2
  exit 1
}
echo "sha256: $(sha256sum "$DEB" | awk '{print $1}')"
