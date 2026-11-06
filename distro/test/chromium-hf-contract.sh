#!/usr/bin/env bash
# distro/test/chromium-hf-contract.sh - static contract test for the Chromium -> Hugging Face move.
# Asserts the architecture rule holds in-tree (no network): chromium is built + published to HF, the
# consumer backfill fetches from HF (not GHCR/oras), and the relocated builder exists. Safe offline.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
rc=0
fail() { echo "  FAIL: $*" >&2; rc=1; }
ok()   { echo "  ok: $*"; }

WF=".github/workflows/chromium-release.yml"
BUILDER="distro/chromium/build-chromium-deb.sh"
FETCH="ci/fetch-engine-debs.sh"

echo "== chromium-release workflow =="
if [ -f "$WF" ]; then
  grep -q "name: chromium-release" "$WF" && ok "workflow present" || fail "workflow name missing"
  grep -q "huggingface-cli upload" "$WF" && ok "uploads to Hugging Face" || fail "no huggingface-cli upload"
  grep -q "anggipradana/vacti-distro-images" "$WF" && ok "targets the vacti-distro-images dataset" || fail "wrong/no HF dataset"
  grep -q "chromium/" "$WF" && ok "publishes under chromium/" || fail "no chromium/ path"
  grep -q "ubuntu-24.04-arm" "$WF" && ok "arm64 on a native runner" || fail "no native arm64 runner"
  grep -qiE "ghcr\.io|oras pull|oras login" "$WF" && fail "workflow still USES GHCR/oras" || ok "no GHCR/oras usage in the workflow"
else
  fail "$WF missing"
fi

echo "== relocated builder =="
if [ -f "$BUILDER" ]; then
  ok "$BUILDER present"
  grep -q "Package: vacti-engine-chromium" "$BUILDER" && ok "dpkg Package name unchanged" || fail "dpkg Package name changed"
else
  fail "$BUILDER missing"
fi

echo "== consumer backfill fetches from HF, not GHCR =="
if [ -f "$FETCH" ]; then
  grep -q "huggingface.co/datasets/anggipradana/vacti-distro-images" "$FETCH" \
    && ok "fetch-engine-debs backfills chromium from HF" || fail "no HF backfill in fetch-engine-debs"
  if grep -qiE "oras pull|oras login|ensure_oras|ghcr\.io|GHCR_REPO|VACTI_CHROMIUM_GHCR" "$FETCH"; then
    fail "fetch-engine-debs still references the GHCR/oras chromium mirror"
  else
    ok "no GHCR/oras chromium mirror in fetch-engine-debs"
  fi
else
  fail "$FETCH missing"
fi

[ $rc -eq 0 ] && echo "== chromium-hf-contract PASS ==" || echo "== chromium-hf-contract FAIL ==" >&2
exit $rc
