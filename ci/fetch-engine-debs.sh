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
#   VACTI_CHROMIUM_GHCR        GHCR repo for the chromium OCI artifact
#                              (default ghcr.io/anggipradana/vacti-engine-chromium)
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

# --- 3. GHCR chromium backfill (public OCI artifact; NO token) ----------------
# The chromium .deb is STRUCTURALLY absent from the apt pool: its ~226MB (amd64) / ~285MB (arm64)
# body exceeds the upstream 100MB (Cloudflare free-plan) request-body cap, so the engine's apt-pool
# upload takes a tolerated HTTP 413 and chromium never lands in the pool (the fleet self-heals the
# browser at runtime via ensure-browser.sh). The engine GH Release has it, but that is a PRIVATE
# cross-repo release this CI cannot read without a PAT the operator will not add. So the engine
# release pipeline also mirrors chromium to GHCR as a PUBLIC OCI artifact (packaging/publish-chromium-
# ghcr.sh, same owner, built-in GITHUB_TOKEN), which is pulled here anonymously - no secret needed.
# This backfills ONLY chromium; vacti-engine itself still comes from the signed apt pool above.
GHCR_REPO="${VACTI_CHROMIUM_GHCR:-ghcr.io/anggipradana/vacti-engine-chromium}"

ensure_oras() {
  command -v oras >/dev/null 2>&1 && return 0
  local ver="${ORAS_VERSION:-1.3.6}" tmp url
  tmp="$(mktemp -d)" || return 1
  url="https://github.com/oras-project/oras/releases/download/v${ver}/oras_${ver}_linux_amd64.tar.gz"
  warn "oras not found; installing ${ver}"
  curl -fsSL "$url" -o "${tmp}/oras.tgz" || { rm -rf "$tmp"; return 1; }
  tar -C "$tmp" -xzf "${tmp}/oras.tgz" oras || { rm -rf "$tmp"; return 1; }
  # Keep the binary OUT of OUTDIR so it never rides the docker build-context / OVA stage dir.
  chmod 0755 "${tmp}/oras" || { rm -rf "$tmp"; return 1; }
  export PATH="${tmp}:${PATH}"
  command -v oras >/dev/null 2>&1
}

fetch_chromium_from_ghcr() {
  ensure_oras || { warn "could not obtain the oras CLI; skipping GHCR chromium backfill"; return 1; }
  # If the package is private rather than public, an anonymous pull 401s; a GH token (if present) is
  # used best-effort so an operator who GRANTED the package to this repo instead of making it public
  # also works. A public package needs no auth at all.
  if [[ -n "${GH_TOKEN:-}" ]]; then
    printf '%s' "${GH_TOKEN}" | oras login ghcr.io -u "${GITHUB_ACTOR:-x-access-token}" --password-stdin >/dev/null 2>&1 || true
  fi
  local oci_tag="latest-${ARCH}"
  log "GHCR backfill: ${GHCR_REPO}:${oci_tag} -> ${OUTDIR}"
  oras pull "${GHCR_REPO}:${oci_tag}" -o "${OUTDIR}" >/dev/null 2>&1 || { warn "oras pull ${GHCR_REPO}:${oci_tag} failed (package public? pushed?)"; return 1; }
  have_chromium
}

if fetch_from_pool && have_engine && have_chromium; then
  log "fetched engine + chromium from the private apt pool"
elif fetch_from_github && have_engine && have_chromium; then
  log "fetched engine + chromium from the GitHub release fallback"
elif have_engine && fetch_chromium_from_ghcr; then
  # Steady state for this build: the apt pool serves vacti-engine but NOT chromium (chromium is over
  # the upstream 100MB upload cap), so chromium is backfilled ALONE from the public GHCR artifact.
  log "fetched engine (apt pool) + chromium (GHCR backfill)"
else
  warn "could not obtain both .debs (engine=$(have_engine && echo yes || echo no), chromium=$(have_chromium && echo yes || echo no)); build-golden.sh will fall back to THIN bootstrap"
fi

log "OUTDIR contents:"
ls -l "$OUTDIR" 2>/dev/null | sed 's/^/[fetch-engine-debs]   /' || true
# Always succeed: a missing .deb is a graceful THIN fallback, not a build failure.
exit 0
