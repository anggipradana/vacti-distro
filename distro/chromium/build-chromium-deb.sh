#!/usr/bin/env bash
# distro/chromium/build-chromium-deb.sh - build the `vacti-engine-chromium` .deb: the pinned Chromium bundle
# shipped as a SEPARATE package so engine code updates (vacti-engine) do not re-extract the ~250MB browser tree.
#
# OWNERSHIP: Chromium packaging + distribution lives in vacti-distro. The engine .deb Recommends (not Depends)
# this package; when it is installed, the engine's ensure-browser.sh finds the executable and skips the
# download. This builder produces the artifact chromium-release.yml publishes to the Hugging Face dataset
# anggipradana/vacti-distro-images, and ci/build-chromium-deb.sh (fetch-engine-debs.sh tier 3) wraps it.
#
# PIN SOURCE (no playwright-core): the revision, browser version, per-arch download URLs and SHA256s come from
# the vacti-owned distro/packages/chromium-pin.json. Every archive is downloaded DIRECTLY (amd64 Chromium +
# headless shell from Google Chrome for Testing; arm64 + ffmpeg from the Playwright-published static build
# URLs, because linux-arm64 Chrome for Testing only exists from 153.x) and SHA256-verified against the pin
# before it is unpacked. A hash mismatch is a hard failure. No npm install, no playwright-core cli.
#
# LAYOUT: the archives unpack into the exact on-disk layout Playwright's own `install chromium` produces
# (<dir>/<zip top dir>/... + <dir>/INSTALLATION_COMPLETE under /usr/lib/vacti-engine/ms-playwright), so the
# engine's PLAYWRIGHT_BROWSERS_PATH, preflight-heal.ts, tool-versions.ts and Playwright's executablePath()
# resolve it unchanged.
#
# CROSS-ARCH: downloading + repacking never executes the browser, so any host can build any arch (the old
# host-arch guard existed only because the playwright cli was host-locked). The ELF machine of the packaged
# executable is checked against --arch.
#
# Usage: distro/chromium/build-chromium-deb.sh [--arch amd64|arm64] [--out DIR] [--pin FILE] [--cache DIR]
#   --cache DIR  reuse/keep verified archives in DIR (named <sha256>.zip); env VACTI_CHROMIUM_CACHE.
# Produces: <out>/vacti-engine-chromium_<revision>_<arch>.deb (prints its path on the last line)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCH="${TARGET_ARCH:-$(dpkg --print-architecture 2>/dev/null || echo amd64)}"
OUT="$(pwd)/dist-deb"
PIN="${VACTI_CHROMIUM_PIN:-${SCRIPT_DIR}/../packages/chromium-pin.json}"
CACHE="${VACTI_CHROMIUM_CACHE:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --arch) ARCH="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --pin) PIN="$2"; shift 2 ;;
    --cache) CACHE="$2"; shift 2 ;;
    --playwright-version) echo "build-chromium-deb: --playwright-version is obsolete (pin comes from chromium-pin.json); ignored" >&2; shift 2 ;;
    -h | --help) sed -n '2,27p' "$0"; exit 0 ;;
    *) echo "build-chromium-deb: unknown arg: $1" >&2; exit 2 ;;
  esac
done

log() { echo "==> $*"; }
die() { echo "build-chromium-deb: $1" >&2; exit "${2:-1}"; }

case "$ARCH" in amd64 | arm64) ;; *) die "unsupported arch '${ARCH}' (amd64|arm64 only)" 2 ;; esac
for t in python3 curl unzip sha256sum dpkg-deb; do
  command -v "$t" >/dev/null 2>&1 || die "${t} not available" 3
done
[ -f "$PIN" ] || die "pin file not found: ${PIN}" 3

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- resolve the pin (TSV: name dir exe url sha256 size) --------------------------------------------
REVISION="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["revision"])' "$PIN")"
BROWSER_VERSION="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["browser_version"])' "$PIN")"
python3 -I - "$PIN" "$ARCH" > "${WORK}/components.tsv" <<'PY'
import json, re, sys
pin = json.load(open(sys.argv[1]))
comps = pin.get("arches", {}).get(sys.argv[2]) or []
if not comps:
    sys.exit("no components for arch %s in pin" % sys.argv[2])
for c in comps:
    for k in ("name", "dir", "exe", "url", "sha256", "size"):
        if k not in c:
            sys.exit("pin component missing %s: %r" % (k, c))
    if not re.fullmatch(r"[0-9a-f]{64}", c["sha256"]):
        sys.exit("bad sha256 for %s" % c["name"])
    if not c["url"].startswith("https://"):
        sys.exit("non-https url for %s" % c["name"])
    if "/" in c["dir"] or c["dir"].startswith("."):
        sys.exit("bad dir for %s" % c["name"])
    print("\t".join(str(c[k]) for k in ("name", "dir", "exe", "url", "sha256", "size")))
PY
[[ "$REVISION" =~ ^[0-9]+$ ]] || die "bad revision in pin: ${REVISION}"
log "building vacti-engine-chromium revision ${REVISION} (Chrome ${BROWSER_VERSION}, ${ARCH}) from ${PIN}"

STAGING="${WORK}/stage"
APP="${STAGING}/usr/lib/vacti-engine"
BROWSERS="${APP}/ms-playwright"
install -d "$BROWSERS" "${STAGING}/DEBIAN"
if [ -n "$CACHE" ]; then mkdir -p "$CACHE"; fi

# --- download + SHA256-verify + unpack each component -----------------------------------------------
CHROME_EXE=""
while IFS=$'\t' read -r name dir exe url sha size; do
  zip="${WORK}/${sha}.zip"
  if [ -n "$CACHE" ] && [ -f "${CACHE}/${sha}.zip" ]; then
    cp -f "${CACHE}/${sha}.zip" "$zip"
    log "${name}: using cached archive ${CACHE}/${sha}.zip"
  else
    log "${name}: downloading ${url}"
    curl -fSL --retry 3 --retry-delay 5 --proto '=https' --tlsv1.2 -o "$zip" "$url" || die "${name}: download failed: ${url}" 5
  fi
  got_size="$(stat -c %s "$zip")"
  [ "$got_size" = "$size" ] || die "${name}: size mismatch (pin ${size}, got ${got_size}) for ${url}" 6
  echo "${sha}  ${zip}" | sha256sum -c --status - || die "${name}: SHA256 mismatch for ${url} (pin ${sha}, got $(sha256sum "$zip" | cut -d' ' -f1))" 6
  log "${name}: sha256 verified (${sha})"
  if [ -n "$CACHE" ] && [ ! -f "${CACHE}/${sha}.zip" ]; then cp -f "$zip" "${CACHE}/${sha}.zip"; fi
  install -d "${BROWSERS}/${dir}"
  unzip -q -o "$zip" -d "${BROWSERS}/${dir}" || die "${name}: unzip failed" 5
  rm -f "$zip"
  [ -s "${BROWSERS}/${dir}/${exe}" ] || die "${name}: expected executable ${dir}/${exe} missing after unpack" 5
  chmod 0755 "${BROWSERS}/${dir}/${exe}"
  # Playwright's install marker: its registry treats a browser dir without it as not installed.
  : > "${BROWSERS}/${dir}/INSTALLATION_COMPLETE"
  if [ "$name" = "chromium" ]; then CHROME_EXE="${BROWSERS}/${dir}/${exe}"; fi
done < "${WORK}/components.tsv"

[ -n "$CHROME_EXE" ] && [ -s "$CHROME_EXE" ] || die "pinned chrome executable missing after unpack" 5

# Sanity: the packaged chrome must be an ELF for the target arch (e_machine 0x3e x86-64, 0xb7 aarch64).
case "$ARCH" in amd64) want="3e00" ;; arm64) want="b700" ;; esac
got="$(od -An -tx1 -j18 -N2 "$CHROME_EXE" | tr -d ' \n')"
[ "$got" = "$want" ] || die "chrome ELF machine ${got} does not match ${ARCH} (want ${want})" 5

# Prune dead weight (unchanged from the previous builder - keep in sync with the engine's build-deb.sh).
find "$BROWSERS" -type f -path '*/locales/*.pak' ! -name 'en-US.pak' -delete 2>/dev/null || true
find "$BROWSERS" -type d -name WidevineCdm -prune -exec rm -rf {} + 2>/dev/null || true

INSTALLED_KB="$(du -sk "${STAGING}/usr" | awk '{print $1}')"
cat > "${STAGING}/DEBIAN/control" <<CONTROL
Package: vacti-engine-chromium
Version: ${REVISION}
Architecture: ${ARCH}
Maintainer: anggipradana <pra7dana@gmail.com>
Section: web
Priority: optional
Installed-Size: ${INSTALLED_KB}
Description: Pinned Chromium browser for the vacti pentest engine
 The vacti-pinned Chromium build (Chrome ${BROWSER_VERSION}, build ${REVISION}) the vacti engine uses for
 headful browsing, evidence capture, and web testing. Shipped separately so engine code updates do not
 re-extract the ~250MB browser tree. When this package is installed, vacti-engine skips the Chromium
 download at install/startup time.
CONTROL

cat > "${STAGING}/DEBIAN/postinst" <<'POSTINST'
#!/bin/bash
set -e
CFG_ENV="/etc/vacti-engine/engine.env"
ENGINE_USER="vacti-engine"
if [ -f "$CFG_ENV" ]; then
  u="$(sed -n 's/^ENGINE_USER=//p' "$CFG_ENV" | head -1 | tr -d '"'"'"' ')"
  [ -n "$u" ] && ENGINE_USER="$u"
fi
chown -R root:root /usr/lib/vacti-engine/ms-playwright 2>/dev/null || true
chmod -R a+rX /usr/lib/vacti-engine/ms-playwright 2>/dev/null || true
exit 0
POSTINST
chmod 0755 "${STAGING}/DEBIAN/postinst"

mkdir -p "$OUT"
DEB="${OUT}/vacti-engine-chromium_${REVISION}_${ARCH}.deb"
if command -v fakeroot >/dev/null 2>&1; then
  fakeroot dpkg-deb --build -Zgzip --root-owner-group "$STAGING" "$DEB" >/dev/null
else
  dpkg-deb --build -Zgzip --root-owner-group "$STAGING" "$DEB" >/dev/null
fi

log "built ${DEB}"
echo "${DEB}"
