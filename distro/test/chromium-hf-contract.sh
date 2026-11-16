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

echo "== build is independent of playwright-core (vacti-owned pin + SHA256) =="
PIN="distro/packages/chromium-pin.json"
if [ -f "$PIN" ] && python3 -I -c '
import json, re, sys
p = json.load(open(sys.argv[1]))
assert re.fullmatch(r"\d+", p["revision"])
for arch in ("amd64", "arm64"):
    names = sorted(c["name"] for c in p["arches"][arch])
    assert names == ["chromium", "chromium-headless-shell", "ffmpeg"], names
    for c in p["arches"][arch]:
        assert re.fullmatch(r"[0-9a-f]{64}", c["sha256"]) and c["url"].startswith("https://")
' "$PIN" 2>/dev/null; then
  ok "$PIN well-formed (amd64 + arm64, sha256 + https per archive)"
else
  fail "$PIN missing or malformed"
fi
for f in "$BUILDER" ci/build-chromium-deb.sh "$FETCH" "$WF"; do
  if grep -vE '^\s*#' "$f" | grep -qE 'npm install|playwright-core/(cli\.js|browsers\.json|package\.json)|require\.resolve\(.playwright|PLAYWRIGHT_HOST_PLATFORM_OVERRIDE|node "\$CLI"'; then
    fail "$f still drives the build through playwright-core"
  else
    ok "$f does not use playwright-core"
  fi
done
grep -q "chromium-pin.json" "$BUILDER" && grep -q "sha256sum -c" "$BUILDER" \
  && ok "builder reads the pin and SHA256-verifies archives" || fail "builder lacks pin read / SHA256 verify"
grep -q "SHA256SUMS" "$FETCH" && grep -q "sha256sum" "$FETCH" \
  && ok "HF backfill verifies against SHA256SUMS" || fail "HF backfill does not verify SHA256"

[ $rc -eq 0 ] && echo "== chromium-hf-contract PASS ==" || echo "== chromium-hf-contract FAIL ==" >&2
exit $rc
