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
#   VACTI_APT_URL              apt base URL (required; e.g. https://apt.example.com)
#   VACTI_ENGINE_REF           optional: pin the vacti-engine version; empty = latest
#   VACTI_ENGINE_REPO          GH fallback repo (default anggipradana/vacti-pentest-engine)
#   GH_TOKEN                   token with read access to the engine repo (GH fallback)
#   VACTI_CHROMIUM_HF_BASE     HF dataset resolve base for the chromium .deb backfill
#                              (default https://huggingface.co/datasets/anggipradana/vacti-distro-images/resolve/main/chromium)
#   VACTI_CHROMIUM_PIN         chromium pin file (default distro/packages/chromium-pin.json)
set -euo pipefail

ARCH="${1:?usage: fetch-engine-debs.sh <arch> <outdir>}"
OUTDIR="${2:?usage: fetch-engine-debs.sh <arch> <outdir>}"
TOKEN="${VACTI_APT_PRODUCER_TOKEN:-}"
REF="${VACTI_ENGINE_REF:-}"
REPO="${VACTI_ENGINE_REPO:-anggipradana/vacti-pentest-engine}"

log()  { echo "[fetch-engine-debs] $*"; }
warn() { echo "[fetch-engine-debs][warn] $*" >&2; }

mkdir -p "$OUTDIR"

base="${VACTI_APT_URL:?VACTI_APT_URL must be set (apt pool base URL)}"
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

# --- 3. local chromium build from the vacti-owned chromium pin ---------------------------------------
# Preferred chromium source: BUILD the vacti-engine-chromium .deb right here, with no cross-repo auth and no
# secret. distro/packages/chromium-pin.json pins the revision + per-arch archive URLs + SHA256s (no
# playwright-core involved); ci/build-chromium-deb.sh downloads, verifies and packages them. Any runner arch
# can build any target arch. It runs after have_engine only to keep the tier order; it no longer reads the
# engine .deb. Fails soft -> HF tier.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHROMIUM_PIN="${VACTI_CHROMIUM_PIN:-${SCRIPT_DIR}/../distro/packages/chromium-pin.json}"

build_chromium_local() {
  have_engine || { warn "no engine .deb present yet; skipping local chromium build"; return 1; }
  local builder="${SCRIPT_DIR}/build-chromium-deb.sh"
  [[ -f "$builder" ]] || { warn "ci/build-chromium-deb.sh missing"; return 1; }
  [[ -f "$CHROMIUM_PIN" ]] || { warn "chromium pin missing: ${CHROMIUM_PIN}"; return 1; }
  log "building chromium locally from $(basename "$CHROMIUM_PIN") (SHA256-pinned upstream archives; no secret)"
  bash "$builder" --arch "$ARCH" --out "$OUTDIR" --pin "$CHROMIUM_PIN" \
    || { warn "local chromium build failed; falling back to the HF backfill"; return 1; }
  have_chromium
}

# --- 4. HF chromium backfill (public dataset; NO token) -----------------------
# chromium is a big BINARY ARTIFACT, published to the PUBLIC Hugging Face dataset anggipradana/
# vacti-distro-images (the same dataset that hosts the OVAs) by vacti-distro's chromium-release.yml.
# This tier pulls the exact pinned revision anonymously over HTTPS. It is a CONTINUITY fallback behind the
# local build (tier 3). The revision comes from the vacti chromium pin, and the pulled .deb MUST match the
# entry for it in the dataset's chromium/SHA256SUMS (published by the same workflow); a missing entry or a
# mismatch rejects the .deb (fail-closed for this tier -> THIN fallback), it is never baked unverified.
HF_BASE="${VACTI_CHROMIUM_HF_BASE:-https://huggingface.co/datasets/anggipradana/vacti-distro-images/resolve/main/chromium}"

chromium_revision_from_pin() {
  [[ -f "$CHROMIUM_PIN" ]] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  local rev
  rev="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["revision"])' "$CHROMIUM_PIN" 2>/dev/null || true)"
  [[ "$rev" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$rev"
}

fetch_chromium_from_hf() {
  local rev name url sums want got
  rev="$(chromium_revision_from_pin)" || { warn "could not resolve the pinned chromium revision from ${CHROMIUM_PIN}; skipping HF backfill"; return 1; }
  name="vacti-engine-chromium_${rev}_${ARCH}.deb"
  url="${HF_BASE}/${name}"
  sums="$(curl -fsSL "${HF_BASE}/SHA256SUMS" 2>/dev/null || true)"
  want="$(awk -v n="$name" '$2 == n { print $1; exit }' <<<"$sums")"
  [[ "$want" =~ ^[0-9a-f]{64}$ ]] || { warn "HF SHA256SUMS has no entry for ${name}; refusing an unverifiable .deb"; return 1; }
  log "HF backfill: ${url} -> ${OUTDIR}"
  curl -fSL "$url" -o "${OUTDIR}/${name}.part" 2>/dev/null \
    || { rm -f "${OUTDIR}/${name}.part"; warn "HF pull failed for revision ${rev} (${ARCH}); is it published under chromium/?"; return 1; }
  got="$(sha256sum "${OUTDIR}/${name}.part" | cut -d' ' -f1)"
  if [[ "$got" != "$want" ]]; then
    rm -f "${OUTDIR}/${name}.part"
    warn "HF ${name} SHA256 mismatch (SHA256SUMS ${want}, got ${got}); rejected"
    return 1
  fi
  mv -f "${OUTDIR}/${name}.part" "${OUTDIR}/${name}"
  log "HF backfill: ${name} sha256 verified (${got})"
  have_chromium
}

if fetch_from_pool && have_engine && have_chromium; then
  log "fetched engine + chromium from the private apt pool"
elif fetch_from_github && have_engine && have_chromium; then
  log "fetched engine + chromium from the GitHub release fallback"
elif have_engine && build_chromium_local; then
  # Steady state for this build: the apt pool serves vacti-engine but NOT chromium (chromium is over
  # the upstream 100MB upload cap), so chromium is BUILT here from the vacti chromium pin (SHA256-verified
  # upstream archives, no secret, no cross-repo auth, cross-arch on one runner).
  log "fetched engine (apt pool) + chromium (built locally from the vacti chromium pin)"
elif have_engine && fetch_chromium_from_hf; then
  # Continuity fallback: pull chromium from the public HF dataset if the local build could not run
  # (e.g. an upstream archive is unreachable). Public anonymous HTTPS, SHA256SUMS-verified, no token.
  log "fetched engine (apt pool) + chromium (HF backfill)"
else
  warn "could not obtain both .debs (engine=$(have_engine && echo yes || echo no), chromium=$(have_chromium && echo yes || echo no)); build-golden.sh will fall back to THIN bootstrap"
fi

log "OUTDIR contents:"
ls -l "$OUTDIR" 2>/dev/null | sed 's/^/[fetch-engine-debs]   /' || true
# Always succeed: a missing .deb is a graceful THIN fallback, not a build failure.
exit 0
