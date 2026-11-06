#!/usr/bin/env bash
# distro/chromium/build-chromium-deb.sh - build the `vacti-engine-chromium` .deb: the pinned Playwright
# Chromium bundle shipped as a SEPARATE package so engine code updates (vacti-engine) do not re-extract
# the ~250MB browser tree.
#
# OWNERSHIP: Chromium packaging + distribution lives in vacti-distro (relocated from the engine's
# packaging/). The engine .deb still Recommends (not Depends) this package; when it is installed,
# ensure-browser.sh finds the executable and skips the download, and when it is NOT installed the engine
# self-heals the pinned build at postinst/startup time. This builder produces the artifact that
# chromium-release.yml publishes to the Hugging Face dataset anggipradana/vacti-distro-images.
#
# SELF-CONTAINED: unlike the engine's old packaging/build-chromium-deb.sh (which resolved the revision
# from the engine repo's own node_modules), this build installs a PINNED playwright-core into a temp
# workspace and resolves the chromium revision from THAT package's browsers.json. The pin comes from
# --playwright-version (or PLAYWRIGHT_VERSION); the release workflow reads it from the engine's committed
# package-lock.json so the built chromium can never skew from the engine it ships beside. With no pin the
# latest published playwright-core is used (fine for a manual one-off; the workflow always pins).
#
# Usage: distro/chromium/build-chromium-deb.sh [--arch amd64|arm64] [--out DIR] [--playwright-version VER]
# Produces: <out>/vacti-engine-chromium_<revision>_<arch>.deb (prints its path on the last line)
# The produced .deb (control/postinst/layout/output name) is byte-equivalent to the engine's original.
set -euo pipefail

# ARCH selection order (same as the engine build): --arch flag > TARGET_ARCH env > host dpkg arch.
ARCH="${TARGET_ARCH:-$(dpkg --print-architecture 2>/dev/null || echo amd64)}"
OUT="$(pwd)/dist-deb"
PW_VERSION="${PLAYWRIGHT_VERSION:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --arch) ARCH="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --playwright-version) PW_VERSION="$2"; shift 2 ;;
    -h | --help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "build-chromium-deb: unknown arg: $1" >&2; exit 2 ;;
  esac
done

log() { echo "==> $*"; }

case "$ARCH" in amd64 | arm64) ;; *) echo "unsupported arch '${ARCH}' (amd64|arm64 only)" >&2; exit 2 ;; esac
command -v node >/dev/null 2>&1 || { echo "node not available; cannot build chromium" >&2; exit 3; }
command -v npm >/dev/null 2>&1 || { echo "npm not available; cannot install playwright-core" >&2; exit 3; }
command -v dpkg-deb >/dev/null 2>&1 || { echo "dpkg-deb not available" >&2; exit 3; }

# Cross-arch guard (same logic as the engine original): Chromium is arch-specific. The release workflow
# runs each arch on its NATIVE runner (no QEMU), so this guard never trips there.
HOST_ARCH="$(dpkg --print-architecture 2>/dev/null || echo unknown)"
if [ "$ARCH" != "$HOST_ARCH" ] && [ "${VACTI_DEB_CROSS:-0}" != "1" ]; then
  echo "ERROR: --arch ${ARCH} on a ${HOST_ARCH} host. Chromium is arch-specific; build on the target arch." >&2
  exit 4
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- install the pinned playwright-core (the single source of the chromium revision) ----------------
PC_DIR="${WORK}/pc"
mkdir -p "$PC_DIR"
log "installing playwright-core${PW_VERSION:+@${PW_VERSION}} into a temp workspace"
(
  cd "$PC_DIR"
  npm init -y >/dev/null 2>&1
  npm install --no-audit --no-fund --no-save "playwright-core${PW_VERSION:+@${PW_VERSION}}" >/dev/null 2>&1
) || { echo "npm install playwright-core failed" >&2; exit 3; }

# Resolve the Chromium revision from the installed playwright-core (browsers.json is the source of truth).
REVISION="$(node -e "
  const fs = require('fs');
  const path = require('path');
  const p = require.resolve('playwright-core/package.json', { paths: [process.argv[1]] });
  const dir = path.dirname(p);
  for (const rel of ['browsers.json', 'lib/server/browsers.json']) {
    const f = path.join(dir, rel);
    if (fs.existsSync(f)) {
      const b = JSON.parse(fs.readFileSync(f, 'utf8'));
      const c = b.browsers.find(x => x.name === 'chromium');
      if (c) { process.stdout.write(String(c.revision)); process.exit(0); }
    }
  }
  process.stderr.write('could not resolve chromium revision from playwright-core\n');
  process.exit(1);
" "$PC_DIR")"
log "building vacti-engine-chromium revision ${REVISION} (${ARCH})"

CLI="$(node -e "process.stdout.write(require.resolve('playwright-core/cli.js', { paths: [process.argv[1]] }))" "$PC_DIR")"

# --- download the pinned Chromium into a staging dir ------------------------------------------------
STAGING="${WORK}/stage"
APP="${STAGING}/usr/lib/vacti-engine"
install -d "${APP}/ms-playwright" "${STAGING}/DEBIAN"

log "downloading pinned chromium (revision ${REVISION}) from the public Playwright CDN"
PLAYWRIGHT_BROWSERS_PATH="${APP}/ms-playwright" node "$CLI" install chromium

# Prune dead weight (identical to the engine original - keep in sync).
find "${APP}/ms-playwright" -type f -path '*/locales/*.pak' ! -name 'en-US.pak' -delete 2>/dev/null || true
find "${APP}/ms-playwright" -type d -name WidevineCdm -prune -exec rm -rf {} + 2>/dev/null || true

# Sanity: the arch-correct chrome executable must exist.
CHROME="$(find "${APP}/ms-playwright" -type f -name chrome -path '*chromium-*' 2>/dev/null | head -n1)"
[ -n "$CHROME" ] && [ -s "$CHROME" ] || { echo "pinned chrome executable missing after install" >&2; exit 5; }

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
 The Playwright-pinned Chromium build the vacti engine uses for headful browsing, evidence capture,
 and web testing. Shipped separately so engine code updates do not re-extract the ~250MB browser tree.
 When this package is installed, vacti-engine skips the Chromium download at install/startup time.
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
  fakeroot dpkg-deb --build -Zgzip --root-owner-group "$STAGING" "$DEB"
else
  dpkg-deb --build -Zgzip --root-owner-group "$STAGING" "$DEB"
fi

log "built ${DEB}"
echo "${DEB}"
