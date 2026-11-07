#!/usr/bin/env bash
#
# publish-images-to-hf.sh
#
# Publish vacti-distro VM/ISO/cloud images (amd64 + arm64) to a public
# Hugging Face Dataset. GitHub Releases cap each asset at 2GiB, which blocks
# the OVA/ISO/qcow2 artifacts. HF Datasets allow up to 50GiB per LFS file,
# free, with stable public resolve URLs: the right permanent home for them.
#
# The small .deb and fingerprint JSON stay on the GitHub Release / apt repo
# (their canonical home, well under 2GiB) and are NOT published here.
#
# Usage:
#   scripts/publish-images-to-hf.sh --run-id <id> --version <X.Y.Z|auto> --arch <amd64|arm64|both>
#
# Behaviour:
#   1. gh run download <run-id> into a staging dir.
#   2. Rename the matrix artifacts (vacti-engine-<rel>[-arch]-<form>.*) to the
#      human scheme (vacti-distro-<version>-<arch>.<form>).
#   3. Compute SHA256 for each and merge into SHA256SUMS (remote-aware upsert).
#   4. huggingface-cli upload the renamed set under v<version>/.
#   5. Regenerate the dataset README.md index (names the latest release).
#   6. Print each uploaded file's public resolve URL.
#   7. Clean up the staging dir on success; on ANY failure, STOP, keep the
#      staging dir, and exit non-zero.
#
# Idempotent: re-running against the same run+version UPSERTS (HF handles the
# commit); the script asserts remote vs local hashes match and warns on drift.
#
# Requires: gh (authenticated), huggingface-cli (huggingface_hub), curl,
# sha256sum, awk, sed, find. HF_TOKEN must be exported (hf_... write token).

set -euo pipefail

REPO_ID="anggipradana/vacti-distro-images"
REPO_NAME="vacti-distro-images"
SRC_REPO="anggipradana/vacti-distro"
RESOLVE_BASE="https://huggingface.co/datasets/${REPO_ID}/resolve/main"
API_BASE="https://huggingface.co/api/datasets/${REPO_ID}"

RUN_ID=""
VERSION=""
ARCH="both"

log()  { echo "[publish-hf] $*"; }
warn() { echo "[publish-hf] WARN: $*" >&2; }

# fail: STOP, report the preserved staging dir, exit non-zero. Never deletes.
fail() {
  echo "[publish-hf] ERROR: $*" >&2
  if [ -n "${STAGE:-}" ] && [ -d "${STAGE}" ]; then
    echo "[publish-hf] staging dir PRESERVED for inspection: ${STAGE}" >&2
  fi
  exit 1
}

usage() {
  sed -n '2,37p' "$0" >&2
  exit "${1:-2}"
}

# --- parse args --------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --run-id)  RUN_ID="${2:-}"; shift 2 ;;
    --version) VERSION="${2:-}"; shift 2 ;;
    --arch)    ARCH="${2:-}"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) echo "[publish-hf] unknown argument: $1" >&2; usage 2 ;;
  esac
done

[ -n "$RUN_ID" ] || { echo "[publish-hf] --run-id is required" >&2; usage 2; }
case "$ARCH" in
  amd64|arm64|both) ;;
  *) echo "[publish-hf] --arch must be amd64, arm64, or both" >&2; usage 2 ;;
esac
: "${HF_TOKEN:?HF_TOKEN must be exported (hf_... write-scoped token)}"

for bin in gh huggingface-cli curl sha256sum awk sed find; do
  command -v "$bin" >/dev/null 2>&1 || fail "required tool not found: ${bin}"
done

STAGE="/tmp/hf-stage-${RUN_ID}"
RAW="${STAGE}/raw"
RENAMED="${STAGE}/renamed"
rm -rf "$STAGE"
mkdir -p "$RAW" "$RENAMED"

# --- 1. download the run's artifacts ----------------------------------------
# Only pull the form-* artifacts (the publishable VM/ISO/cloud images). A bare
# `gh run download` grabs EVERY artifact on the run, including the golden disk
# (large, skipped below) and the `*.dockerbuild` BuildKit build record emitted
# by docker/build-push-action. That build record is not a standard zip, so gh
# aborts with "error extracting zip archive: zip: not a valid zip file" and the
# whole download fails. Restricting to form-* avoids it and skips the needless
# golden download.
log "downloading form-* artifacts from ${SRC_REPO} run ${RUN_ID} ..."
gh run download "$RUN_ID" -R "$SRC_REPO" -D "$RAW" --pattern 'form-*' || fail "gh run download failed for run ${RUN_ID}"

# --- version: auto-derive from a filename if requested ----------------------
if [ -z "$VERSION" ] || [ "$VERSION" = "auto" ]; then
  sample="$(find "$RAW" -type f -name 'vacti-engine-*' | head -n1 || true)"
  [ -n "$sample" ] || fail "cannot auto-derive --version: no vacti-engine-* artifact under ${RAW}"
  VERSION="$(basename "$sample" | sed -E 's/^vacti-engine-([0-9]+\.[0-9]+\.[0-9]+).*/\1/')"
  log "auto-derived version: ${VERSION}"
fi
echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || fail "version is not X.Y.Z: '${VERSION}'"

# --- 2. rename matrix artifacts -> human scheme -----------------------------
# Arch is read from the filename (amd64 has no suffix; arm64 carries -arm64).
# Sidecars (*.sha256, *.mf, MANIFEST.sha256) and the golden disk are skipped;
# SHA256SUMS is generated fresh below.
map_name() {
  local base="$1" a="$2" out="" fl="headless"
  # Flavor tag read from the filename. The VM/cloud forms now ALWAYS carry a
  # -headless/-gui tag (vacti-engine-<rel>[-arch]-<flavor>-<form>.*); default to
  # headless so a re-publish of a pre-flavor run (headless-only) still maps
  # cleanly. The ISO path carries its own -headless/-gui tag and is unaffected.
  case "$base" in
    *-gui-*|*-gui.*)           fl="gui" ;;
    *-headless-*|*-headless.*) fl="headless" ;;
  esac
  case "$base" in
    *-golden.qcow2)   return 1 ;;
    *-cloud.qcow2)    out="vacti-distro-${VERSION}-${a}-${fl}.qcow2" ;;
    *.raw.gz)         out="vacti-distro-${VERSION}-${a}-${fl}.raw.gz" ;;
    *-vmware.ova)     out="vacti-distro-${VERSION}-${a}-${fl}.vmware.ova" ;;
    *-virtualbox.ova) out="vacti-distro-${VERSION}-${a}-${fl}.vbox.ova" ;;
    *-headless.iso)   out="vacti-distro-${VERSION}-${a}-headless.iso" ;;
    *-gui.iso)        out="vacti-distro-${VERSION}-${a}-gui.iso" ;;
    *) return 1 ;;
  esac
  printf '%s' "$out"
}

found=0
while IFS= read -r -d '' f; do
  base="$(basename "$f")"
  case "$base" in
    *.sha256|*.mf|SHA256SUMS) continue ;;
  esac
  case "$base" in
    *-arm64-*|*-arm64.*) a="arm64" ;;
    *) a="amd64" ;;
  esac
  if [ "$ARCH" != "both" ] && [ "$a" != "$ARCH" ]; then
    continue
  fi
  if ! newname="$(map_name "$base" "$a")"; then
    log "skip (not a published form): ${base}"
    continue
  fi
  if [ -e "${RENAMED}/${newname}" ]; then
    warn "duplicate target ${newname} from ${base}; keeping the first"
    continue
  fi
  cp -n "$f" "${RENAMED}/${newname}" || fail "copy failed: ${f} -> ${newname}"
  log "rename: ${base} -> ${newname}"
  found=$((found + 1))
done < <(find "$RAW" -type f -print0)

[ "$found" -gt 0 ] || fail "no publishable image artifacts matched under ${RAW} for arch=${ARCH}"
log "matched ${found} image artifact(s)"

# --- 3. SHA256SUMS: compute local, merge with remote (upsert), assert -------
LOCAL_SUMS="${STAGE}/local.SHA256SUMS"
REMOTE_SUMS="${STAGE}/remote.SHA256SUMS"
( cd "$RENAMED" && sha256sum -- * ) > "$LOCAL_SUMS" || fail "sha256sum failed"

if curl -fsSL "${RESOLVE_BASE}/v${VERSION}/SHA256SUMS" -o "$REMOTE_SUMS" 2>/dev/null; then
  log "fetched existing v${VERSION}/SHA256SUMS for merge"
else
  : > "$REMOTE_SUMS"
fi

# Idempotency assertion: warn when a remote hash for the same name differs.
while read -r lh ln; do
  [ -n "$ln" ] || continue
  rh="$(awk -v n="$ln" '$2 == n {print $1}' "$REMOTE_SUMS" | head -n1)"
  if [ -n "$rh" ] && [ "$rh" != "$lh" ]; then
    warn "hash drift for ${ln}: remote ${rh} != local ${lh}; upserting local"
  fi
done < "$LOCAL_SUMS"

# Merge: remote first, local overrides, one entry per name, sorted by name.
awk '
  FNR == NR { if (NF >= 2) h[$2] = $1; next }
  { if (NF >= 2) h[$2] = $1 }
  END { for (n in h) printf "%s  %s\n", h[n], n }
' "$REMOTE_SUMS" "$LOCAL_SUMS" | sort -k2 > "${RENAMED}/SHA256SUMS" || fail "SHA256SUMS merge failed"

# --- 4. upload the version directory -----------------------------------------
log "hf login + whoami ..."
huggingface-cli login --token "$HF_TOKEN" >/dev/null 2>&1 || fail "huggingface-cli login failed"
who="$(huggingface-cli whoami 2>/dev/null | head -n1 || true)"
log "hf user: ${who:-unknown}"

# Ensure the dataset repo exists (no-op if already present).
huggingface-cli repo create "$REPO_NAME" --type dataset -y >/dev/null 2>&1 || true

log "uploading v${VERSION}/ (${found} files + SHA256SUMS) ..."
huggingface-cli upload "$REPO_ID" "$RENAMED" "v${VERSION}/" \
  --repo-type dataset \
  --commit-message "release v${VERSION} (${ARCH})" \
  || fail "huggingface-cli upload failed"

# --- 5. regenerate the README.md index (the 'latest' pointer) ---------------
# >>> readme-render-begin (anchored for scripts/test/test-readme-render.sh) <<<
# Rebuilt from the REMOTE tree so it reflects every file in v<version>/,
# regardless of which arch publish ran last (amd64 and arm64 are separate runs).
#
# Arch-completeness rule (VACTI_HF_README_ARCH_COMPLETE, default ON):
#   amd64 builds finish ~4h before arm64, so the newest v<version>/ folder is
#   usually amd64-only for hours. Advertising it as "Latest release" the instant
#   amd64 landed made the operator perpetually see an amd64-only newest version.
#   Fix: advance the README headline only to the LATEST version that holds BOTH
#   a *-amd64-*.ova AND a *-arm64-*.ova (LATEST_COMPLETE). When a newer but
#   still-incomplete version exists (LATEST_PARTIAL), keep the headline on
#   LATEST_COMPLETE and add a "Building: v<LATEST_PARTIAL> (arm64 pending)" note
#   rather than promoting a half-published version. Set the env to 0 for the
#   legacy behaviour (headline = the version just published).
#   One recursive tree fetch feeds BOTH the file table and the completeness scan
#   (this replaces the former per-version fetch; still a single API call).
README_ARCH_COMPLETE="${VACTI_HF_README_ARCH_COMPLETE:-1}"

TREE="${STAGE}/tree.json"
all_paths=""
# VACTI_HF_TREE_FILE is a test-only seam: when set, read the tree JSON from a
# local file instead of the network (used by scripts/test/test-readme-render.sh).
if [ -n "${VACTI_HF_TREE_FILE:-}" ] && [ -f "${VACTI_HF_TREE_FILE}" ]; then
  cp -f "${VACTI_HF_TREE_FILE}" "$TREE"
  all_paths="$(grep -oE '"path":"[^"]*"' "$TREE" | sed -E 's/"path":"//; s/"$//' || true)"
elif curl -fsSL "${API_BASE}/tree/main?recursive=true" -o "$TREE" 2>/dev/null; then
  all_paths="$(grep -oE '"path":"[^"]*"' "$TREE" | sed -E 's/"path":"//; s/"$//' || true)"
fi

# files present under a given v<ver>/ (SHA256SUMS excluded), sorted by name.
files_for_version() {
  local ver="$1" vre
  vre="$(printf '%s' "$ver" | sed 's/\./\\./g')"
  printf '%s\n' "$all_paths" \
    | grep -E "^v${vre}/" \
    | sed -E "s#^v${vre}/##" \
    | grep -v '^SHA256SUMS$' | grep -v '^$' | sort || true
}

# version_files = the files for the version THIS run published; used by the
# step-6 URL print and (in the common case) by the README table. Falls back to
# the locally renamed set when the remote tree is unavailable.
version_files="$(files_for_version "$VERSION")"
if [ -z "$version_files" ]; then
  version_files="$(find "$RENAMED" -maxdepth 1 -type f -printf '%f\n' | grep -v '^SHA256SUMS$' | sort)"
fi

# Scan every v<X>/ folder for arch-completeness to pick the README headline.
LATEST_PARTIAL=""
LATEST_COMPLETE=""
if [ -n "$all_paths" ]; then
  all_versions="$(printf '%s\n' "$all_paths" \
    | grep -oE '^v[0-9]+\.[0-9]+\.[0-9]+/' \
    | sed -E 's#^v##; s#/$##' | sort -uV || true)"
  LATEST_PARTIAL="$(printf '%s\n' "$all_versions" | grep -v '^$' | tail -n1 || true)"
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    vre="$(printf '%s' "$v" | sed 's/\./\\./g')"
    amd="$(printf '%s\n' "$all_paths" | grep -E "^v${vre}/.*-amd64-.*\.ova$" | head -n1 || true)"
    arm="$(printf '%s\n' "$all_paths" | grep -E "^v${vre}/.*-arm64-.*\.ova$" | head -n1 || true)"
    if [ -n "$amd" ] && [ -n "$arm" ]; then
      LATEST_COMPLETE="$v"   # ascending sort => last match is the newest complete
    fi
  done <<EOF
${all_versions}
EOF
fi

# Default to legacy: headline = the version just published.
HEADLINE_VERSION="$VERSION"
HEADLINE_LABEL="Latest release"
PENDING_VERSION=""
if [ "$README_ARCH_COMPLETE" != "0" ] && [ -n "$LATEST_COMPLETE" ]; then
  HEADLINE_VERSION="$LATEST_COMPLETE"
  if [ -n "$LATEST_PARTIAL" ] && [ "$LATEST_COMPLETE" != "$LATEST_PARTIAL" ]; then
    HEADLINE_LABEL="Latest complete release"
    PENDING_VERSION="$LATEST_PARTIAL"
  fi
fi

# The README table lists the headline version's files.
if [ "$HEADLINE_VERSION" = "$VERSION" ]; then
  readme_files="$version_files"
else
  readme_files="$(files_for_version "$HEADLINE_VERSION")"
fi

README="${STAGE}/README.md"
{
  echo "---"
  echo "license: other"
  echo "pretty_name: vacti-distro images"
  echo "tags:"
  echo "  - vacti"
  echo "  - disk-images"
  echo "---"
  echo
  echo "# Vacti appliance images"
  echo
  echo "Pre-built operating-system images for the Vacti pentest appliance."
  echo "Each image boots pre-provisioned; first boot runs enrollment against"
  echo "your Vacti control plane."
  echo
  echo "Documentation: [docs.vacti.org](https://docs.vacti.org)."
  echo
  echo "## ${HEADLINE_LABEL}: v${HEADLINE_VERSION}"
  echo
  if [ -n "$PENDING_VERSION" ]; then
    echo "Building: v${PENDING_VERSION} (arm64 pending)"
    echo
  fi
  echo "| file | download |"
  echo "| --- | --- |"
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    echo "| \`${n}\` | ${RESOLVE_BASE}/v${HEADLINE_VERSION}/${n} |"
  done <<EOF
${readme_files}
EOF
  echo
  echo "Verify: download \`${RESOLVE_BASE}/v${HEADLINE_VERSION}/SHA256SUMS\` and run"
  echo "\`sha256sum -c SHA256SUMS\` next to the images."
  echo
  echo "## Docker (alternative to the OVA)"
  echo
  echo "The same appliance is also published as a multi-arch Docker image"
  echo "(\`linux/amd64\` + \`linux/arm64\`) at \`ghcr.io/anggipradana/vacti-distro:<version>\`."
  echo "It bakes the engine, so first run enrolls against your control plane the same"
  echo "way the OVA does."
  echo
  echo '```'
  echo "docker pull ghcr.io/anggipradana/vacti-distro:${VERSION}"
  echo "docker run -d \\"
  echo "  --name vacti-engine \\"
  echo "  -e VACTI_CP_URL=https://your-control-plane.example \\"
  echo "  -e VACTI_ENROLL_TOKEN=<enrollment-token> \\"
  echo "  --restart unless-stopped \\"
  echo "  ghcr.io/anggipradana/vacti-distro:${VERSION}"
  echo '```'
  echo
  echo "The GHCR image is private; request access from the operator, or deploy from"
  echo "the OVA which needs no registry auth."
  echo
  echo "Older releases are kept under their own \`vX.Y.Z/\` directory."
} > "$README"
# >>> readme-render-end <<<

log "updating README.md index ..."
huggingface-cli upload "$REPO_ID" "$README" "README.md" \
  --repo-type dataset \
  --commit-message "index: latest v${VERSION}" \
  || fail "README.md index upload failed"

# --- 6. print public URLs ----------------------------------------------------
log "published files (public URLs):"
while IFS= read -r n; do
  [ -n "$n" ] || continue
  echo "  ${RESOLVE_BASE}/v${VERSION}/${n}"
done <<EOF
${version_files}
EOF
echo "  ${RESOLVE_BASE}/v${VERSION}/SHA256SUMS"

# --- 7. clean up on success --------------------------------------------------
rm -rf "$STAGE"
log "done: v${VERSION} (${ARCH}) published to ${REPO_ID}; staging cleaned up"
