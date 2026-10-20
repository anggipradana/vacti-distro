#!/usr/bin/env bash
# arsenal-sync-check.sh - the divergence guard. FAILS the build if the distro's
# baked engine-arsenal set has drifted from the engine's arsenal manifest. This
# is the "teeth" the old prose ("do not hand-maintain a divergent list") lacked:
# the distro no longer hand-transcribes the engine's apt arrays, so this check
# keeps the vendored snapshot + the generator honest against the engine.
#
# WHAT IT COMPARES
#   DISTRO side  : distro/packages/arsenal-manifest.json  (the vendored snapshot
#                  the generator derives every image's arsenal from), plus the
#                  live output of gen-live-build-list.sh.
#   ENGINE side  : the AUTHORITATIVE manifest for the pinned engine ref, resolved
#                  in this order:
#                    1. $VACTI_ENGINE_MANIFEST  - an explicit path (an engine
#                       checkout's packaging/arsenal-manifest.json, or a file a CI
#                       step extracted from the installed .deb). Used as-is.
#                    2. a best-effort pull of the vacti-engine .deb from
#                       $VACTI_APT_URL (Basic auth $VACTI_APT_PRODUCER_TOKEN) at
#                       $VACTI_ENGINE_REF, from which the shipped manifest at
#                       /usr/lib/vacti-engine/packaging/arsenal-manifest.json is
#                       extracted. Any failure here SOFT-SKIPS (never a hard CI
#                       failure) so the check stays dormant until the operator
#                       wires the apt credential, matching the dormant
#                       engine-deb-published dispatch.
#   CHECK A      : the vendored snapshot must EQUAL the engine manifest on every
#                  arsenal field (apt.grant / apt.core / apt.verticals.* / apt.ctf
#                  / tools / playwright_mcp_spec / assets.frida / pins). A diff is a
#                  hard FAIL.
#   CHECK B      : the generator must actually EMIT every manifest arsenal package
#                  for the right flavour (full + ctf is a superset of core + ctf).
#
# Exit: 0 = in sync (or soft-skip); 1 = divergence (named) or a real error.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG_DIR="${ROOT}/distro/packages"
VENDORED="${PKG_DIR}/arsenal-manifest.json"
GEN="${PKG_DIR}/gen-live-build-list.sh"
INSTALLED_MANIFEST_PATH="usr/lib/vacti-engine/packaging/arsenal-manifest.json"

log()  { echo "[arsenal-sync] $*"; }
warn() { echo "[arsenal-sync][warn] $*" >&2; }
skip() { echo "[arsenal-sync][SKIP] $*" >&2; exit 0; }
fail() { echo "[arsenal-sync][FAIL] $*" >&2; exit 1; }

# --revendor <dest>: resolve the AUTHORITATIVE engine manifest (exactly as the
# normal check does - one resolver, no second source of truth) and copy it to
# <dest>, then stop WITHOUT running CHECK A/B. This is how an auto-triggered
# distro rebuild refreshes the vendored snapshot so an expected arsenal drift
# does not red-lint. A soft-skip (no reference reachable) exits 0 and leaves
# <dest> untouched, so the build falls back to the committed snapshot.
REVENDOR_DEST=""
if [[ "${1:-}" == "--revendor" ]]; then
  REVENDOR_DEST="${2:-}"
  [[ -n "$REVENDOR_DEST" ]] || fail "--revendor requires a destination path"
fi

command -v python3 >/dev/null 2>&1 || skip "python3 not available; cannot compare manifests"
[[ -f "$VENDORED" ]] || fail "vendored snapshot missing: ${VENDORED}"

# --- resolve the AUTHORITATIVE engine manifest --------------------------------
ENGINE_MANIFEST=""
CLEANUP=""
# shellcheck disable=SC2064
trap '[[ -n "$CLEANUP" ]] && rm -rf "$CLEANUP" 2>/dev/null || true' EXIT

if [[ -n "${VACTI_ENGINE_MANIFEST:-}" && -f "${VACTI_ENGINE_MANIFEST}" ]]; then
  ENGINE_MANIFEST="${VACTI_ENGINE_MANIFEST}"
  log "authoritative manifest: ${ENGINE_MANIFEST} (explicit)"
elif [[ -n "${VACTI_APT_URL:-}" && -n "${VACTI_APT_PRODUCER_TOKEN:-}" ]]; then
  # best-effort pull of the engine .deb and extraction of the shipped manifest.
  if command -v dpkg-deb >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
    CLEANUP="$(mktemp -d)"
    base="${VACTI_APT_URL%/}/apt"
    ref="${VACTI_ENGINE_REF:-}"
    log "fetching the engine Packages index from ${base}"
    idx="${CLEANUP}/Packages"
    if curl -fsSL -u "vacti:${VACTI_APT_PRODUCER_TOKEN}" "${base}/Packages" -o "$idx" 2>/dev/null \
       || { curl -fsSL -u "vacti:${VACTI_APT_PRODUCER_TOKEN}" "${base}/Packages.gz" -o "${idx}.gz" 2>/dev/null \
            && gzip -df "${idx}.gz" 2>/dev/null; }; then
      # pick the vacti-engine stanza (matching $ref when set), read its Filename.
      fn="$(python3 - "$idx" "$ref" <<'PY'
import sys
idx, ref = sys.argv[1], sys.argv[2]
cur = {}
best = None
for block in open(idx, encoding="utf-8", errors="replace").read().split("\n\n"):
    d = {}
    for line in block.splitlines():
        if ": " in line:
            k, v = line.split(": ", 1)
            d[k.strip()] = v.strip()
    if d.get("Package") != "vacti-engine":
        continue
    if ref and d.get("Version") != ref:
        continue
    if "Filename" in d:
        best = d["Filename"]  # last match wins (flat repo: typically one)
print(best or "")
PY
)"
      if [[ -n "$fn" ]]; then
        deb="${CLEANUP}/engine.deb"
        if curl -fsSL -u "vacti:${VACTI_APT_PRODUCER_TOKEN}" "${base}/${fn}" -o "$deb" 2>/dev/null \
           || curl -fsSL -u "vacti:${VACTI_APT_PRODUCER_TOKEN}" "${VACTI_APT_URL%/}/${fn}" -o "$deb" 2>/dev/null; then
          if dpkg-deb --fsys-tarfile "$deb" 2>/dev/null | tar -xO "./${INSTALLED_MANIFEST_PATH}" > "${CLEANUP}/engine-manifest.json" 2>/dev/null \
             && [[ -s "${CLEANUP}/engine-manifest.json" ]]; then
            ENGINE_MANIFEST="${CLEANUP}/engine-manifest.json"
            log "authoritative manifest: extracted from ${fn} (ref='${ref:-latest}')"
          fi
        fi
      fi
    fi
  fi
  [[ -n "$ENGINE_MANIFEST" ]] || skip "could not pull the engine .deb (apt creds/repo unreachable); check stays dormant until wired"
else
  skip "no authoritative manifest (set VACTI_ENGINE_MANIFEST, or VACTI_APT_URL + VACTI_APT_PRODUCER_TOKEN); vendored snapshot assumed current"
fi

# --- --revendor: write the resolved authoritative manifest and stop -----------
# Reached only when a manifest WAS resolved above (every no-reference path has
# already soft-skipped/exited). The copy runs before the EXIT trap clears the
# temp dir. Normal (no --revendor) runs skip this and fall through to the checks.
if [[ -n "$REVENDOR_DEST" ]]; then
  cp -f "$ENGINE_MANIFEST" "$REVENDOR_DEST" || fail "could not write revendored manifest to ${REVENDOR_DEST}"
  log "revendored authoritative engine manifest -> ${REVENDOR_DEST} (ref='${VACTI_ENGINE_REF:-latest}')"
  exit 0
fi

# --- CHECK A: vendored snapshot == engine manifest (arsenal fields) -----------
log "CHECK A: vendored snapshot vs engine manifest"
python3 - "$VENDORED" "$ENGINE_MANIFEST" <<'PY' || exit 1
import json, sys
vend = json.load(open(sys.argv[1]))
eng = json.load(open(sys.argv[2]))

def apt(m, *path):
    d = m.get("apt", {})
    for p in path:
        d = d.get(p, {}) if isinstance(d, dict) else {}
    return d

def toolset(m):
    out = set()
    for t in m.get("tools", []):
        out.add((
            t.get("name"), t.get("method"), t.get("package"),
            t.get("capability"), ",".join(sorted(t.get("binaries", []) or [])),
            t.get("arch"),
        ))
    return out

diffs = []

def cmp_set(label, a, b):
    sa, sb = set(a or []), set(b or [])
    only_v = sorted(sa - sb)
    only_e = sorted(sb - sa)
    if only_v or only_e:
        diffs.append("%s: only-in-distro=%s only-in-engine=%s" % (label, only_v, only_e))

cmp_set("apt.grant", apt(vend, "grant"), apt(eng, "grant"))
cmp_set("apt.core", apt(vend, "core"), apt(eng, "core"))
cmp_set("apt.ctf", apt(vend, "ctf"), apt(eng, "ctf"))
vkeys = set(apt(vend, "verticals").keys()) | set(apt(eng, "verticals").keys())
for k in sorted(vkeys):
    cmp_set("apt.verticals.%s" % k, apt(vend, "verticals").get(k), apt(eng, "verticals").get(k))
cmp_set("tools", toolset(vend), toolset(eng))
if vend.get("playwright_mcp_spec") != eng.get("playwright_mcp_spec"):
    diffs.append("playwright_mcp_spec: distro=%r engine=%r"
                 % (vend.get("playwright_mcp_spec"), eng.get("playwright_mcp_spec")))

# assets.frida (multi-arch frida-server/gadget blob set: version + arches + per-arch sha256) and the mobile-stack
# pins (caido_cli/caido_mcp/mobile_mcp/jadx/frida/frida_cli) are non-apt declarations the guard must also diff, so a
# drifted frida version/sha or a bumped Caido/mobile-mcp pin in the engine can never slip past the vendored snapshot.
if vend.get("assets") != eng.get("assets"):
    diffs.append("assets: distro=%r engine=%r" % (vend.get("assets"), eng.get("assets")))
if vend.get("pins") != eng.get("pins"):
    diffs.append("pins: distro=%r engine=%r" % (vend.get("pins"), eng.get("pins")))

if diffs:
    sys.stderr.write("[arsenal-sync][FAIL] vendored snapshot DIVERGES from the engine manifest:\n")
    for d in diffs:
        sys.stderr.write("    - " + d + "\n")
    sys.stderr.write("  fix: re-vendor distro/packages/arsenal-manifest.json from the engine at the pinned ref.\n")
    sys.exit(1)
print("[arsenal-sync] CHECK A ok: snapshot equals the engine manifest on every arsenal field")
PY

# --- CHECK B: the generator emits every manifest arsenal package --------------
log "CHECK B: generator derivation covers the manifest"
GENLIST="$(mktemp)"; trap '[[ -n "$CLEANUP" ]] && rm -rf "$CLEANUP"; rm -f "$GENLIST"' EXIT
VACTI_ARSENAL_MANIFEST="$ENGINE_MANIFEST" VACTI_FULL_ARSENAL=1 VACTI_CTF_ARSENAL=1 \
  bash "$GEN" "$GENLIST" >/dev/null 2>&1 || fail "gen-live-build-list.sh errored"
python3 - "$ENGINE_MANIFEST" "$GENLIST" <<'PY' || exit 1
import json, sys
m = json.load(open(sys.argv[1]))
gen = {ln.strip() for ln in open(sys.argv[2]) if ln.strip() and not ln.startswith("#")}
arsenal = set(m["apt"].get("core", [])) | set(m["apt"].get("ctf", []))
missing = sorted(arsenal - gen)
if missing:
    sys.stderr.write("[arsenal-sync][FAIL] generator DROPPED manifest arsenal packages: %s\n" % missing)
    sys.exit(1)
print("[arsenal-sync] CHECK B ok: generated full+ctf list is a superset of the manifest arsenal (%d pkgs)" % len(arsenal))
PY

log "PASS: distro arsenal is in sync with the engine manifest"
