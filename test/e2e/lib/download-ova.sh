#!/usr/bin/env bash
# download-ova.sh - fetch a published vacti-distro OVA from the Hugging Face
# dataset (the permanent image host; see scripts/publish-images-to-hf.sh). The
# HF-renamed scheme is vacti-distro-<version>-<arch>-<flavor>.vbox.ova, served
# from https://huggingface.co/datasets/<repo>/resolve/main/v<version>/<name>.
#
# Verifies the SHA256 against the sibling <name>.sha256 (or v<version>/SHA256SUMS)
# when available; fail-closed on a mismatch. An HF read token (HF_TOKEN) is sent
# only if present (the dataset is public, so it is optional). The download is
# CACHED: a prior good copy with a matching checksum is reused (idempotent).
#
# Usage: download-ova.sh <flavor> <dest-dir>
#   flavor: gui | headless
# Honours: E2E_RELEASE (default 0.1.0), E2E_ARCH (amd64|arm64),
#          E2E_HF_BASE (resolve base URL), HF_TOKEN (optional).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test/e2e/lib/assert.sh
. "${HERE}/assert.sh"

flavor="${1:?usage: download-ova.sh <gui|headless> <dest-dir>}"
dest="${2:?usage: download-ova.sh <gui|headless> <dest-dir>}"
release="${E2E_RELEASE:-0.1.0}"
arch="${E2E_ARCH:-amd64}"
hf_base="${E2E_HF_BASE:-https://huggingface.co/datasets/anggipradana/vacti-distro-images/resolve/main}"

case "$flavor" in gui|headless) ;; *) cp_fail "download" "flavor must be gui|headless";; esac
require_cmd curl sha256sum

name="vacti-distro-${release}-${arch}-${flavor}.vbox.ova"
url="${hf_base%/}/v${release}/${name}"
mkdir -p "$dest"
out="${dest}/${name}"
sum_url="${url}.sha256"

auth=()
[[ -n "${HF_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer ${HF_TOKEN}")

# Fetch the expected checksum (best-effort; the .sha256 sibling is produced by
# convert-vbox-ova.sh and uploaded alongside the OVA).
want_sum=""
if tmp_sum="$(curl -fsSL "${auth[@]}" "$sum_url" 2>/dev/null)"; then
  want_sum="$(printf '%s' "$tmp_sum" | awk '{print $1}')"
fi

# Reuse a cached copy if its checksum matches.
if [[ -f "$out" && -n "$want_sum" ]]; then
  have="$(sha256sum "$out" | awk '{print $1}')"
  if [[ "$have" == "$want_sum" ]]; then
    e2e_ok "cached OVA reused: ${out}"
    printf '%s\n' "$out"
    exit 0
  fi
  e2e_warn "cached OVA checksum mismatch; re-downloading"
  rm -f "$out"
fi

e2e_log "downloading ${name} from HF (this can be several GB)"
curl -fL --retry 3 --retry-delay 5 "${auth[@]}" -o "$out" "$url" \
  || cp_fail "download" "HF fetch failed: ${url}"

if [[ -n "$want_sum" ]]; then
  have="$(sha256sum "$out" | awk '{print $1}')"
  [[ "$have" == "$want_sum" ]] || cp_fail "download" "SHA256 mismatch for ${name}"
  e2e_ok "OVA SHA256 verified"
else
  e2e_warn "no published .sha256 for ${name}; skipping checksum verification"
fi

printf '%s\n' "$out"
