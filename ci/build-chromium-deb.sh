#!/usr/bin/env bash
# ci/build-chromium-deb.sh - build the `vacti-engine-chromium` .deb on the distro CI host, from the
# engine's OWN bundled playwright-core, with NO cross-repo auth and NO secret.
#
# WHY THIS EXISTS: the ~226MB (amd64) / ~285MB (arm64) chromium .deb is too big for the apt pool
# (Cloudflare 100MB cap -> engine upload 413s) and lives otherwise only in the PRIVATE engine repo's
# GitHub Release / a PRIVATE GHCR package, neither readable by this repo's GITHUB_TOKEN. So instead of
# fetching a prebuilt chromium .deb, we BUILD it here from the PUBLIC Playwright-pinned Chromium:
# chromium is the open-source Playwright build, downloaded anonymously from the public Playwright CDN
# (x64 via Chrome-for-Testing, arm64 via builds/chromium) by playwright-core's own install CLI. It is
# NOT methodology IP; building it downstream re-publishes nothing the engine .deb did not already carry.
#
# SINGLE SOURCE OF TRUTH: we do not pin a chromium revision here. The vacti-engine app .deb (already
# fetched from the signed apt pool) bundles usr/lib/vacti-engine/node_modules/playwright-core, whose
# browsers.json pins the EXACT revision this engine build runs. We extract ONLY that playwright-core
# (pure JS, arch-independent; no engine methodology is unpacked) and run its cli.js, so the built
# chromium can never skew from the baked engine.
#
# CROSS-ARCH on one runner: playwright-core's install CLI is host-arch-locked by default, but honours
# PLAYWRIGHT_HOST_PLATFORM_OVERRIDE. The amd64 CI runner that bakes the multi-arch Docker image sets it
# to produce the arm64 build; the native arch is built with no override (identical to the engine's own
# packaging/build-chromium-deb.sh). The on-disk layout + executablePath the override yields matches the
# layout the engine resolves at runtime for that platform, so the .deb is structure-equivalent to the
# engine-built one.
#
# Usage: ci/build-chromium-deb.sh --engine-deb <vacti-engine_*.deb> --arch <amd64|arm64> --out <dir>
# Produces: <out>/vacti-engine-chromium_<revision>_<arch>.deb (prints its path on the last line)
# Exit: 0 on success; non-zero on any failure (caller treats a failure as "fall back to another source").
set -euo pipefail

ENGINE_DEB=""
ARCH=""
OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --engine-deb) ENGINE_DEB="${2:-}"; shift 2 ;;
    --arch)       ARCH="${2:-}";       shift 2 ;;
    --out)        OUT="${2:-}";        shift 2 ;;
    -h | --help)  sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "build-chromium-deb: unknown arg: $1" >&2; exit 2 ;;
  esac
done

log()  { echo "[build-chromium-deb] $*"; }
err()  { echo "[build-chromium-deb][err] $*" >&2; }

[ -n "$ENGINE_DEB" ] && [ -f "$ENGINE_DEB" ] || { err "need --engine-deb <file> (got '${ENGINE_DEB}')"; exit 2; }
[ -n "$ARCH" ] || { err "need --arch <amd64|arm64>"; exit 2; }
[ -n "$OUT" ]  || { err "need --out <dir>"; exit 2; }
case "$ARCH" in amd64|arm64) ;; *) err "unsupported arch '${ARCH}' (amd64|arm64 only)"; exit 2 ;; esac

command -v node     >/dev/null 2>&1 || { err "node not available; cannot build chromium locally"; exit 3; }
command -v dpkg-deb >/dev/null 2>&1 || { err "dpkg-deb not available"; exit 3; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- 1. extract ONLY playwright-core from the engine .deb (no methodology IP) ----------------------
PC_ROOT="${WORK}/pc"
mkdir -p "$PC_ROOT"
log "extracting playwright-core from $(basename "$ENGINE_DEB")"
dpkg-deb --fsys-tarfile "$ENGINE_DEB" \
  | tar -x -C "$PC_ROOT" --wildcards '*/node_modules/playwright-core/*' 2>/dev/null || true
CLI="$(find "$PC_ROOT" -path '*/playwright-core/cli.js' -type f 2>/dev/null | head -n1)"
BROWSERS_JSON="$(find "$PC_ROOT" -path '*/playwright-core/browsers.json' -type f 2>/dev/null | head -n1)"
[ -n "$CLI" ] && [ -f "$CLI" ] || { err "engine .deb has no bundled playwright-core/cli.js"; exit 4; }
[ -n "$BROWSERS_JSON" ] || { err "engine .deb has no bundled playwright-core/browsers.json"; exit 4; }

# --- 2. resolve the pinned chromium revision from the engine's OWN browsers.json -------------------
REVISION="$(node -e '
  const fs=require("fs");
  const b=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
  const c=(b.browsers||[]).find(x=>x.name==="chromium");
  if(!c||!c.revision){process.stderr.write("no chromium revision in browsers.json\n");process.exit(1);}
  process.stdout.write(String(c.revision));
' "$BROWSERS_JSON")" || { err "could not read the pinned chromium revision"; exit 4; }
log "pinned chromium revision ${REVISION} (${ARCH})"

# --- 3. download the pinned chromium into a staging tree (public Playwright CDN; no auth) ----------
# Target path mirrors the engine .deb: /usr/lib/vacti-engine/ms-playwright (ensure-browser.sh resolves it).
STAGING="${WORK}/stage"
APP="${STAGING}/usr/lib/vacti-engine"
install -d "${APP}/ms-playwright" "${STAGING}/DEBIAN"

HOST_ARCH="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
OVERRIDE=()
if [ "$ARCH" != "$HOST_ARCH" ]; then
  # Cross-arch: tell playwright which platform to fetch for. The distro target is Debian 13 (trixie);
  # the chromium on-disk layout is arch-determined (x64 -> chrome-linux64 via CFT, arm64 -> chrome-linux
  # via the playwright build), so the debianNN token only needs the right arch suffix.
  OVERRIDE=("PLAYWRIGHT_HOST_PLATFORM_OVERRIDE=debian13-${ARCH/amd64/x64}")
  log "cross-arch build on a ${HOST_ARCH} host -> ${OVERRIDE[0]}"
fi

log "downloading pinned chromium (revision ${REVISION}) from the public Playwright CDN"
env "${OVERRIDE[@]}" PLAYWRIGHT_BROWSERS_PATH="${APP}/ms-playwright" \
  node "$CLI" install chromium

# --- 4. prune dead weight (identical to the engine's packaging/build-chromium-deb.sh) --------------
find "${APP}/ms-playwright" -type f -path '*/locales/*.pak' ! -name 'en-US.pak' -delete 2>/dev/null || true
find "${APP}/ms-playwright" -type d -name WidevineCdm -prune -exec rm -rf {} + 2>/dev/null || true

# Sanity: the arch-correct chrome executable must exist (x64 -> chrome-linux64, arm64 -> chrome-linux).
CHROME="$(find "${APP}/ms-playwright" -type f -name chrome -path '*chromium-*' 2>/dev/null | head -n1)"
[ -n "$CHROME" ] && [ -s "$CHROME" ] || { err "pinned chrome executable missing after install"; exit 5; }
log "chrome executable: ${CHROME#"$STAGING"}"

# --- 5. build the .deb (identical control/postinst to the engine's packaging/build-chromium-deb.sh) -
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
  fakeroot dpkg-deb --build -Zgzip --root-owner-group "$STAGING" "$DEB" >/dev/null
else
  dpkg-deb --build -Zgzip --root-owner-group "$STAGING" "$DEB" >/dev/null
fi

log "built ${DEB}"
echo "${DEB}"
