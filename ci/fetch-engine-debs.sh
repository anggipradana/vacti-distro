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
# and is never baked.
#
# FAIL-LOUD (P1-4): the script exits NON-ZERO (with a ::error:: annotation on the CI
# log, not just a line in an in-image log file) when
#   - an apt-pool HTTP request fails (curl 4xx/5xx on the index or a .deb),
#   - a downloaded .deb's SHA256 does not match the apt index / HF SHA256SUMS,
#   - VACTI_ENGINE_REF is set and the staged vacti-engine is a different version,
#   - either .deb (engine or chromium) could not be obtained from any tier.
# A silent THIN fallback shipped stale/empty images before. The THIN fallback is
# now an explicit opt-in: VACTI_FETCH_ALLOW_THIN=1 restores the old exit-0 behaviour.
#
# Usage: ci/fetch-engine-debs.sh <arch> <outdir>
# Env:
#   VACTI_APT_PRODUCER_TOKEN   producer token for the private apt pool (apt-pool path)
#   VACTI_APT_URL              apt base URL (required; e.g. https://apt.example.com)
#   VACTI_ENGINE_REF           optional: pin the vacti-engine version (exact; X.Y.Z matches
#                              X.Y.Z and X.Y.Z+build / X.Y.Z-rev / X.Y.Z~pre); empty = latest
#   VACTI_FETCH_ALLOW_THIN     1 = exit 0 even when the .debs are missing (explicit THIN opt-in)
#   VACTI_FETCH_POOL_WAIT      seconds to WAIT for the engine .deb to appear in the apt pool before
#                              failing (default 0 = no wait, fail-loud immediately). The release
#                              cascade can dispatch the image build before the engine .deb finishes
#                              publishing; a non-zero wait turns that race from a hard failure into a
#                              retry-with-timeout. A HARD error (auth/HTTP/hash) still aborts the wait.
#   VACTI_FETCH_POOL_INTERVAL  poll interval in seconds while waiting (default 30)
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
REF="${REF#v}"
REPO="${VACTI_ENGINE_REPO:-anggipradana/vacti-pentest-engine}"
ALLOW_THIN="${VACTI_FETCH_ALLOW_THIN:-0}"
HARD_ERR=0

log()  { echo "[fetch-engine-debs] $*"; }
warn() { echo "[fetch-engine-debs][warn] $*" >&2; }
# A HARD error (HTTP failure, hash mismatch) is never downgraded to a THIN fallback.
hard() { echo "::error::[fetch-engine-debs] $*" >&2; HARD_ERR=1; }

# version_matches <version> <pin>: exact, or pin followed by a Debian separator
# (+build, -revision, ~pre). The old substring match let pin 0.2.47 pick 0.2.471.
version_matches() {
  local v="$1" p="$2"
  [[ -z "$p" || "$v" == "$p" || "$v" == "$p"+* || "$v" == "$p"-* || "$v" == "$p"~* ]]
}

mkdir -p "$OUTDIR"

base="${VACTI_APT_URL:?VACTI_APT_URL must be set (apt pool base URL)}"
base="${base%/}/apt"

have_engine()   { compgen -G "${OUTDIR}/vacti-engine_"*_"${ARCH}".deb >/dev/null 2>&1; }
have_chromium() { compgen -G "${OUTDIR}/vacti-engine-chromium_"*_"${ARCH}".deb >/dev/null 2>&1; }

# --- 1. private apt pool (preferred) -----------------------------------------
fetch_from_pool() {
  [[ -n "$TOKEN" ]] || { warn "VACTI_APT_PRODUCER_TOKEN unset; skipping apt-pool fetch"; return 1; }
  local idx code
  # The index read is the one place a 4xx/5xx is unambiguous: report it as HARD
  # (wrong token / path / server error), never as a silent "not found".
  code="$(curl -sS -o /dev/null -w '%{http_code}' -u "vacti:${TOKEN}" "${base}/Packages" 2>/dev/null || true)"
  idx="$(curl -fsSL -u "vacti:${TOKEN}" "${base}/Packages" 2>/dev/null \
         || curl -fsSL -u "vacti:${TOKEN}" "${base}/Packages.gz" 2>/dev/null | gunzip -c 2>/dev/null \
         || true)"
  [[ -n "$idx" ]] || { hard "could not read the apt index at ${base}/Packages[.gz] (HTTP ${code:-none})"; return 1; }

  # Emit "version<TAB>filename<TAB>sha256" for every stanza matching pkg + arch (or all).
  stanzas() { # pkg
    awk -v pkg="$1" -v arch="$ARCH" '
      BEGIN { RS=""; FS="\n" }
      {
        p=""; v=""; a=""; f=""; s=""
        for (i = 1; i <= NF; i++) {
          if      ($i ~ /^Package: /)      { p = substr($i, 10) }
          else if ($i ~ /^Version: /)      { v = substr($i, 10) }
          else if ($i ~ /^Architecture: /) { a = substr($i, 15) }
          else if ($i ~ /^Filename: /)     { f = substr($i, 11) }
          else if ($i ~ /^SHA256: /)       { s = substr($i, 9) }
        }
        if (p == pkg && (a == arch || a == "all") && f != "") { print v "\t" f "\t" s }
      }' <<<"$idx"
  }

  # Choose the pinned version if set (exact match rules above), else the greatest (dpkg order).
  choose() { # pkg [pin]
    local pkg="$1" pin="${2:-}" best_v="" best_f="" best_s="" v f s
    while IFS=$'\t' read -r v f s; do
      [[ -n "$v" ]] || continue
      version_matches "$v" "$pin" || continue
      if [[ -z "$best_v" ]] || dpkg --compare-versions "$v" gt "$best_v"; then
        best_v="$v"; best_f="$f"; best_s="$s"
      fi
    done < <(stanzas "$pkg")
    [[ -n "$best_f" ]] || return 1
    printf '%s\t%s\t%s\n' "$best_v" "$best_f" "$best_s"
  }

  pull() { # pkg [pin]
    local sel ver fn want got out rest
    sel="$(choose "$1" "${2:-}")" || { warn "no $1 (${ARCH}) in the apt index${2:+ matching '$2'}"; return 1; }
    ver="${sel%%$'\t'*}"; rest="${sel#*$'\t'}"; fn="${rest%%$'\t'*}"; want="${rest#*$'\t'}"
    out="${OUTDIR}/$(basename "$fn")"
    log "apt pool: $1 ${ver} -> ${fn}"
    curl -fSL -u "vacti:${TOKEN}" -o "$out" "${base}/${fn}" \
      || { rm -f "$out"; hard "apt pool download failed (HTTP error) for $1 ${ver}: ${base}/${fn}"; return 1; }
    if [[ "$want" =~ ^[0-9a-fA-F]{64}$ ]]; then
      got="$(sha256sum "$out" | cut -d' ' -f1)"
      if [[ "${got,,}" != "${want,,}" ]]; then
        rm -f "$out"
        hard "SHA256 mismatch for $1 ${ver} (index ${want}, got ${got}); .deb rejected"
        return 1
      fi
      log "apt pool: $1 ${ver} sha256 verified"
    else
      warn "apt index carries no SHA256 for $1 ${ver}; relying on the signed Release at install time"
    fi
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
  # Engine release tags are v-prefixed (release-deb.yml runs on v* tags).
  [[ -n "$REF" ]] && tag=("v${REF}")
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
#
# DECOUPLED FROM have_engine (W47): chromium is an engine-INDEPENDENT, SHA256-pinned package. It used
# to gate on have_engine purely to keep the tier order, which meant a transient engine-.deb miss (e.g.
# the arm64 apt-pool regression) ALSO knocked out chromium and failed the whole fetch. The gate is gone;
# chromium is obtained on its own so an engine miss can never cascade into a chromium miss.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHROMIUM_PIN="${VACTI_CHROMIUM_PIN:-${SCRIPT_DIR}/../distro/packages/chromium-pin.json}"

build_chromium_local() {
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
  # Same transient-resilience as the local build tier: the HF LFS .deb is 100-285MB and the public CDN
  # can drop mid-transfer (curl 18). --retry-all-errors + -C - retry and resume; the SHA256SUMS check
  # below still rejects any corrupt/short result, so this never relaxes the fail-closed verification.
  curl -fSL -C - --retry 5 --retry-all-errors --retry-max-time 600 --proto '=https' --tlsv1.2 "$url" -o "${OUTDIR}/${name}.part" 2>/dev/null \
    || { rm -f "${OUTDIR}/${name}.part"; warn "HF pull failed for revision ${rev} (${ARCH}) after retries; is it published under chromium/?"; return 1; }
  got="$(sha256sum "${OUTDIR}/${name}.part" | cut -d' ' -f1)"
  if [[ "$got" != "$want" ]]; then
    rm -f "${OUTDIR}/${name}.part"
    hard "HF ${name} SHA256 mismatch (SHA256SUMS ${want}, got ${got}); rejected"
    return 1
  fi
  mv -f "${OUTDIR}/${name}.part" "${OUTDIR}/${name}"
  log "HF backfill: ${name} sha256 verified (${got})"
  have_chromium
}

# --- orchestration: engine and chromium are obtained INDEPENDENTLY ------------
# ENGINE: private apt pool (preferred) -> GitHub release fallback. The engine .deb is the artifact the
# release cascade RACES (a dispatch can outrun the apt publish by a few minutes), so when
# VACTI_FETCH_POOL_WAIT>0 we poll the pool for it before giving up, turning the race from a hard failure
# into a retry-with-timeout. A real HARD error (auth/HTTP/hash) still aborts the wait and fails loud.
if [[ "${VACTI_FETCH_POOL_WAIT:-0}" -gt 0 ]] && ! have_engine; then
  pool_wait="${VACTI_FETCH_POOL_WAIT}"; pool_iv="${VACTI_FETCH_POOL_INTERVAL:-30}"
  deadline=$(( SECONDS + pool_wait ))
  log "waiting up to ${pool_wait}s for the ${ARCH} vacti-engine .deb to appear in the apt pool"
  while ! have_engine; do
    HARD_ERR=0
    fetch_from_pool || true
    have_engine && break
    if [[ "$HARD_ERR" -ne 0 ]]; then warn "hard pool error during wait; aborting wait (fail-loud below)"; break; fi
    if [[ "$SECONDS" -ge "$deadline" ]]; then warn "pool wait (${pool_wait}s) elapsed; ${ARCH} engine .deb still absent"; break; fi
    warn "vacti-engine (${ARCH}) not in the apt pool yet; retrying in ${pool_iv}s ..."
    sleep "$pool_iv"
  done
  # Clear any transient HARD flag from the wait; the authoritative tiers + verdict below re-evaluate.
  HARD_ERR=0
fi

if ! have_engine; then
  fetch_from_pool || true
fi
if ! have_engine; then
  warn "engine not in the apt pool; trying the GitHub release fallback"
  fetch_from_github || true
fi

# CHROMIUM: engine-INDEPENDENT. The apt pool does NOT serve chromium (it exceeds the edge upload cap),
# so it is BUILT locally from the vacti chromium pin (SHA256-verified upstream archives, no secret,
# no cross-repo auth, cross-arch on one runner) and, failing that, pulled from the public HF dataset
# (SHA256SUMS-verified, no token). fetch_from_pool may already have staged it if the pool ever serves
# it; otherwise build/backfill it here, with NO dependency on have_engine:
if ! have_chromium; then
  build_chromium_local || fetch_chromium_from_hf || true
fi

if have_engine && have_chromium; then
  log "staged engine + chromium for ${ARCH} (engine: apt pool/GitHub; chromium: local build/HF)"
fi

log "OUTDIR contents:"
ls -l "$OUTDIR" 2>/dev/null | sed 's/^/[fetch-engine-debs]   /' || true

# --- verdict (fail-loud) -------------------------------------------------------
# The staged engine must be the pinned version: a fallback tier (e.g. a GitHub
# "latest" asset) must never silently swap the release the image is stamped with.
if [[ -n "$REF" ]] && have_engine; then
  for d in "${OUTDIR}"/vacti-engine_*.deb; do
    v="$(dpkg-deb -f "$d" Version 2>/dev/null || true)"
    if ! version_matches "$v" "$REF"; then
      hard "staged $(basename "$d") is version '${v:-unknown}', not the pinned VACTI_ENGINE_REF=${REF}"
      rm -f "$d"
    fi
  done
fi
missing=""
have_engine   || missing="${missing} vacti-engine"
have_chromium || missing="${missing} vacti-engine-chromium"
if [[ "$HARD_ERR" -ne 0 ]]; then
  echo "::error::[fetch-engine-debs] FATAL: hard fetch error(s) above (HTTP failure / SHA256 mismatch / version drift); refusing to continue" >&2
  exit 1
fi
if [[ -n "$missing" ]]; then
  if [[ "$ALLOW_THIN" == "1" ]]; then
    warn "missing:${missing} (${ARCH}); VACTI_FETCH_ALLOW_THIN=1 so build-golden.sh falls back to THIN bootstrap"
    exit 0
  fi
  echo "::error::[fetch-engine-debs] FATAL: could not obtain${missing} for ${ARCH}${REF:+ (pin ${REF})} from any tier; set VACTI_FETCH_ALLOW_THIN=1 to build a THIN image on purpose" >&2
  exit 1
fi
log "OK: vacti-engine${REF:+ ${REF}} + vacti-engine-chromium staged for ${ARCH}"
exit 0
