#!/usr/bin/env bash
# lint.sh - LIGHT checks only (shellcheck + yaml/xml sanity). This is NOT a heavy
# image build; it is safe to run anywhere, including locally. The real image
# build runs in CI (GitHub Actions). See .github/workflows/build.yml.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
rc=0

echo "== shellcheck =="
if command -v shellcheck >/dev/null 2>&1; then
  # all our shell scripts (scripts, hooks, auto/config, make-seed, etc.)
  mapfile -t SH < <(find distro ci -type f \( -name '*.sh' -o -name 'vacti-firstboot' -o -name 'vacti-swap-firstboot' -o -name 'vacti-activate' -o -name 'vacti-netpanel' -o -name 'vacti-netsetup' -o -name 'vacti-engine-install' \) ; \
                    echo distro/live-build-config/auto/config)
  # hooks are /bin/sh; include them too
  mapfile -t HOOKS < <(find distro/live-build-config/config/hooks -type f -name '*.chroot' 2>/dev/null || true)
  shellcheck -x -S warning "${SH[@]}" "${HOOKS[@]}" || rc=1
else
  echo "shellcheck not installed; skipping (CI installs it)"
fi

echo "== yaml sanity =="
if command -v python3 >/dev/null 2>&1; then
  for y in distro/packages/manifest.yml .github/workflows/build.yml; do
    python3 -c "import sys,yaml; yaml.safe_load(open('$y'))" 2>/dev/null \
      && echo "  ok: $y" || { echo "  YAML parse FAILED: $y" >&2; rc=1; }
  done
else
  echo "python3 not available; skipping YAML check"
fi

echo "== OVF/xml sanity =="
if command -v xmllint >/dev/null 2>&1; then
  for x in distro/golden-image/ovf-templates/*.ovf.tmpl; do
    # templates carry @PLACEHOLDER@ tokens; strip them before well-formedness check
    sed -E 's/@[A-Z_]+@/0/g' "$x" | xmllint --noout - 2>/dev/null \
      && echo "  ok: $x" || { echo "  XML not well-formed: $x" >&2; rc=1; }
  done
else
  echo "xmllint not available; skipping OVF check"
fi

echo "== arsenal sync (distro <-> engine manifest) =="
# The divergence guard. It self-resolves the authoritative engine manifest
# (VACTI_ENGINE_MANIFEST, else a best-effort apt pull via VACTI_APT_URL +
# VACTI_APT_PRODUCER_TOKEN) and SOFT-SKIPS when no reference is reachable, so
# `make lint` stays offline-safe; it only hard-FAILS on a real divergence.
if [[ -x ci/arsenal-sync-check.sh ]]; then
  ci/arsenal-sync-check.sh || rc=1
else
  echo "  ci/arsenal-sync-check.sh missing; skipping"
fi

echo "== enroll boot-chain contracts =="
# Static contract test: guarantees the activation kiosk reappears after any reboot
# that happens before enrollment completes (no systemd needed; safe offline).
if [[ -x distro/test/enroll-boot-contracts.sh ]]; then
  bash distro/test/enroll-boot-contracts.sh || rc=1
else
  echo "  distro/test/enroll-boot-contracts.sh missing; skipping"
fi

echo "== kiosk-stuck runtime test (container) =="
# EMPIRICAL runtime proof that --no-block (vacti-activate:403) + the content-aware
# engine_env_ready poll (vacti-activate:410) actually change observable behaviour:
# it sources the real activate script and times stage_token_and_enroll under a
# Type=oneshot systemctl stub. Needs Docker to isolate from host systemd; LOUD SKIP
# when Docker is absent so `make lint` stays runnable anywhere.
if command -v docker >/dev/null 2>&1; then
  if [[ -x distro/test/kiosk-runtime/run.sh ]]; then
    bash distro/test/kiosk-runtime/run.sh || rc=1
  else
    echo "  distro/test/kiosk-runtime/run.sh missing; skipping"
  fi
else
  echo "  !!! SKIP: docker not available - kiosk-stuck runtime test NOT executed !!!"
fi

echo "== chromium -> HF contract =="
# Static contract test for the Chromium -> Hugging Face move (no network): chromium is built +
# published to the HF dataset and the consumer backfill fetches from HF, not GHCR/oras.
if [[ -x distro/test/chromium-hf-contract.sh ]]; then
  bash distro/test/chromium-hf-contract.sh || rc=1
else
  echo "  distro/test/chromium-hf-contract.sh missing; skipping"
fi

[[ $rc -eq 0 ]] && echo "== lint PASS ==" || echo "== lint FAIL ==" >&2
exit $rc
