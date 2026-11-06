#!/usr/bin/env bash
# ci/fetch-engine-debs.sh - FAT-OVA build input. Download the vacti-engine app .deb
# and the vacti-engine-chromium .deb for ARCH into OUTDIR so build-golden.sh can BAKE
# them into the golden disk (ENGINE_DEBS_DIR). The source is the PRIVATE vacti apt
# pool (preferred - the exact source the live fleet updates from, so the baked
# version == the shippable release) or, as a fallback, the latest GitHub release of
# the private engine repo. NEVER a public mirror of the pool (that would re-publish
# the plaintext methodology the thin model exists to protect).
#
# This is a BUILD-TIME helper only: the producer token is used solely on the CI host
# and is never baked. If neither source yields the .debs, the script exits 0 with an
# empty OUTDIR so build-golden.sh gracefully falls back to the THIN first-boot path.
#
# Usage: ci/fetch-engine-debs.sh <arch> <outdir>
# Env:
#   VACTI_APT_PRODUCER_TOKEN   producer token for the private apt pool (apt-pool path)
#   VACTI_APT_URL              apt base URL (default https://repo.example.com)
#   VACTI_ENGINE_REF           optional: pin the vacti-engine version; empty = latest
#   VACTI_ENGINE_REPO          GH fallback repo (default anggipradana/vacti-pentest-engine)
#   GH_TOKEN                   token with read access to the engine repo (GH fallback)
#   VACTI_CHROMIUM_HF_BASE     HF dataset resolve base for the chromium .deb backfill
#                              (default https://huggingface.co/datasets/anggipradana/vacti-distro-images/resolve/main/chromium)
set -euo pipefail

ARCH="${1:?usage: fetch-engine-debs.sh <arch> <outdir>}"
OUTDIR="${2:?usage: fetch-engine-debs.sh <arch> <outdir>}"
TOKEN="${VACTI_APT_PRODUCER_TOKEN:-}"
REF="${VACTI_ENGINE_REF:-}"
REPO="${VACTI_ENGINE_REPO:-anggipradana/vacti-pentest-engine}"

log()  { echo "[fetch-engine-debs] $*"; }
warn() { echo "[fetch-engine-debs][warn] $*" >&2; }

mkdir -p "$OUTDIR"

base="${VACTI_APT_URL:-https://repo.example.com}"
base="${base%/}/apt"

have_engine()   { compgen -G "${OUTDIR}/vacti-engine_"*.deb >/dev/null 2>&1; }
have_chromium() { compgen -G "${OUTDIR}/vacti-engine-chromium_"*.deb >/dev/null 2>&1; }

# --- 1. private apt pool (preferred) -----------------------------------------
fetch_from_pool() {
  [[ -n "$TOKEN" ]] || { warn "VACTI_APT_PRODUCER_TOKEN unset; skipping apt-pool fetch"; return 1; }
  local idx
  idx="$(curl -fsSL -u "vacti:${TOKEN}" "${base}/Packages" 2>/dev/null \
         || curl -fsSL -u "vacti:${TOKEN}" "${base}/Packages.gz" 2>/dev/null | gunzip -c 2>/dev/null \
         || true)"
  [[ -n "$idx" ]] || { warn "could not read the apt index at ${base}/Packages[.gz]"; return 1; }

  # Emit "version<TAB>filename" for every stanza matching pkg + arch (or arch=all).
  stanzas() { # pkg
    awk -v pkg="$1" -v arch="$ARCH" '
      BEGIN { RS=""; FS="\n" }
      {
        p=""; v=""; a=""; f=""
        for (i = 1; i <= NF; i++) {
          if      ($i ~ /^Package: /)      { p = substr($i, 10) }
          else if ($i ~ /^Version: /)      { v = substr($i, 10) }
          else if ($i ~ /^Architecture: /) { a = substr($i, 15) }
          else if ($i ~ /^Filename: /)     { f = substr($i, 11) }
        }
        if (p == pkg && (a == arch || a == "all") && f != "") { print v "\t" f }
      }' <<<"$idx"
  }

  # Choose the pinned version if $3 is set, else the greatest version (dpkg order).
  choose() { # pkg [pin]
    local pkg="$1" pin="${2:-}" best_v="" best_f="" v f
    while IFS=$'\t' read -r v f; do
      [[ -n "$v" ]] || continue
      if [[ -n "$pin" && "$v" != "$pin" && "$v" != "$pin"* && "$v" != *"$pin"* ]]; then
        continue
      fi
      if [[ -z "$best_v" ]] || dpkg --compare-versions "$v" gt "$best_v"; then
        best_v="$v"; best_f="$f"
      fi
    done < <(stanzas "$pkg")
    [[ -n "$best_f" ]] || return 1
    printf '%s\t%s\n' "$best_v" "$best_f"
  }

  pull() { # pkg [pin]
    local sel ver fn
    sel="$(choose "$1" "${2:-}")" || { warn "no $1 (${ARCH}) in the apt index${2:+ matching '$2'}"; return 1; }
    ver="${sel%%$'\t'*}"; fn="${sel#*$'\t'}"
    log "apt pool: $1 ${ver} -> ${fn}"
    curl -fSL -u "vacti:${TOKEN}" -o "${OUTDIR}/$(basename "$fn")" "${base}/${fn}"
  }

  # Pin the engine app to VACTI_ENGINE_REF when set; chromium is a build-number
  # package independent of the engine release, so always take the greatest.
  pull vacti-engine "$REF"          || return 1
  pull vacti-engine-chromium ""     || return 1
}

# --- 2. GitHub release fallback ----------------------------------------------
fetch_from_github() {
  command -v gh >/dev/null 2>&1 || { warn "gh CLI not available; skipping GitHub fallback"; return 1; }
  [[ -n "${GH_TOKEN:-}" ]] || warn "GH_TOKEN unset; GitHub fallback may fail on a private repo"
  local tag=()
  [[ -n "$REF" ]] && tag=("$REF")
  log "GitHub fallback: ${REPO} release ${REF:-<latest>} assets (*_${ARCH}.deb)"
  gh release download "${tag[@]}" --repo "$REPO" \
     --pattern "vacti-engine_*_${ARCH}.deb" \
     --pattern "vacti-engine-chromium_*_${ARCH}.deb" \
     --dir "$OUTDIR" --clobber 2>/dev/null || return 1
}

# --- 3. local chromium build from the engine's OWN bundled playwright-core -----
# Preferred chromium source: BUILD the vacti-engine-chromium .deb right here, with no cross-repo auth
# and no secret. chromium is the open-source Playwright-pinned build, downloaded anonymously from the
# PUBLIC Playwright CDN; the vacti-engine app .deb fetched above bundles playwright-core, whose
# browsers.json pins the exact revision, so the built chromium is version-locked to the baked engine.
# ci/build-chromium-deb.sh extracts ONLY playwright-core (no methodology IP), installs the pinned
# chromium (cross-arch via PLAYWRIGHT_HOST_PLATFORM_OVERRIDE when the runner arch differs), and packages
# it. This needs the engine .deb already present; it runs AFTER have_engine. Fails soft -> HF tier.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

build_chromium_local() {
  have_engine || { warn "no engine .deb present yet; cannot build chromium locally"; return 1; }
  command -v node >/dev/null 2>&1 || { warn "node unavailable; skipping local chromium build"; return 1; }
  local builder="${SCRIPT_DIR}/build-chromium-deb.sh" engine_deb
  [[ -x "$builder" || -f "$builder" ]] || { warn "ci/build-chromium-deb.sh missing"; return 1; }
  # Prefer the arch-matched engine .deb; playwright-core is pure JS so any engine .deb also works.
  engine_deb="$(ls -1 "${OUTDIR}"/vacti-engine_*_"${ARCH}".deb 2>/dev/null | head -n1 || true)"
  [[ -n "$engine_deb" ]] || engine_deb="$(ls -1 "${OUTDIR}"/vacti-engine_*.deb 2>/dev/null | head -n1 || true)"
  [[ -n "$engine_deb" ]] || { warn "could not locate an engine .deb in ${OUTDIR}"; return 1; }
  log "building chromium locally from $(basename "$engine_deb") (public Playwright CDN; no secret)"
  bash "$builder" --engine-deb "$engine_deb" --arch "$ARCH" --out "$OUTDIR" \
    || { warn "local chromium build failed; falling back to the HF backfill"; return 1; }
  have_chromium
}

# --- 4. HF chromium backfill (public dataset; NO token) -----------------------
# chromium is a big BINARY ARTIFACT, published to the PUBLIC Hugging Face dataset anggipradana/
# vacti-distro-images (the same dataset that hosts the OVAs) by vacti-distro's chromium-release.yml.
# This tier pulls the exact pinned revision anonymously over HTTPS - no oras, no registry login, no
# one-time "make the package public" step. It is a CONTINUITY fallback behind the local build (tier 3):
# it runs only when the local build could not (e.g. no node on the runner). The revision is read from
# the engine .deb's bundled playwright-core/browsers.json so the pulled chromium matches the baked
# engine; vacti-engine itself still comes from the signed apt pool above.
HF_BASE="${VACTI_CHROMIUM_HF_BASE:-https://huggingface.co/datasets/anggipradana/vacti-distro-images/resolve/main/chromium}"

chromium_revision_from_engine_deb() {
  local deb rev tmp bj
  deb="$(ls -1 "${OUTDIR}"/vacti-engine_*_"${ARCH}".deb 2>/dev/null | head -n1 || true)"
  [[ -n "$deb" ]] || deb="$(ls -1 "${OUTDIR}"/vacti-engine_*.deb 2>/dev/null | head -n1 || true)"
  [[ -n "$deb" && -f "$deb" ]] || return 1
  command -v node >/dev/null 2>&1 || return 1
  tmp="$(mktemp -d)" || return 1
  dpkg-deb --fsys-tarfile "$deb" \
    | tar -x -C "$tmp" --wildcards '*/node_modules/playwright-core/browsers.json' 2>/dev/null || true
  bj="$(find "$tmp" -path '*/playwright-core/browsers.json' -type f 2>/dev/null | head -n1)"
  if [[ -n "$bj" ]]; then
    rev="$(node -e '
      const fs=require("fs");
      const b=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
      const c=(b.browsers||[]).find(x=>x.name==="chromium");
      process.stdout.write(c&&c.revision?String(c.revision):"");
    ' "$bj" 2>/dev/null || true)"
  fi
  rm -rf "$tmp"
  [[ -n "$rev" ]] && { printf '%s' "$rev"; return 0; }
  return 1
}

fetch_chromium_from_hf() {
  local rev url
  rev="$(chromium_revision_from_engine_deb)" || { warn "could not resolve the pinned chromium revision from the engine .deb; skipping HF backfill"; return 1; }
  url="${HF_BASE}/vacti-engine-chromium_${rev}_${ARCH}.deb"
  log "HF backfill: ${url} -> ${OUTDIR}"
  curl -fSL "$url" -o "${OUTDIR}/vacti-engine-chromium_${rev}_${ARCH}.deb" 2>/dev/null \
    || { warn "HF pull failed for revision ${rev} (${ARCH}); is it published under chromium/?"; return 1; }
  have_chromium
}

if fetch_from_pool && have_engine && have_chromium; then
  log "fetched engine + chromium from the private apt pool"
elif fetch_from_github && have_engine && have_chromium; then
  log "fetched engine + chromium from the GitHub release fallback"
elif have_engine && build_chromium_local; then
  # Steady state for this build: the apt pool serves vacti-engine but NOT chromium (chromium is over
  # the upstream 100MB upload cap), so chromium is BUILT here from the engine's own pinned playwright-core
  # (public Playwright CDN, no secret, no cross-repo auth, cross-arch on one runner).
  log "fetched engine (apt pool) + chromium (built locally from the engine's pinned playwright-core)"
elif have_engine && fetch_chromium_from_hf; then
  # Continuity fallback: pull chromium from the public HF dataset if the local build could not run
  # (e.g. no node on the runner). Public anonymous HTTPS, no token, no registry login.
  log "fetched engine (apt pool) + chromium (HF backfill)"
else
  warn "could not obtain both .debs (engine=$(have_engine && echo yes || echo no), chromium=$(have_chromium && echo yes || echo no)); build-golden.sh will fall back to THIN bootstrap"
fi

log "OUTDIR contents:"
ls -l "$OUTDIR" 2>/dev/null | sed 's/^/[fetch-engine-debs]   /' || true
# Always succeed: a missing .deb is a graceful THIN fallback, not a build failure.
exit 0
