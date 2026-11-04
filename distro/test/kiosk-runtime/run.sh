#!/usr/bin/env bash
# run.sh - host driver for the kiosk-stuck RUNTIME test.
#
# WHAT IT PROVES (empirically, not by grep):
#   The fix at distro/enroll/activate/vacti-activate:403 (`systemctl start
#   --no-block "$fb_unit"`) + :410 (content-aware `engine_env_ready` poll) makes
#   stage_token_and_enroll return the instant firstboot publishes engine.env,
#   instead of blocking for the whole Type=oneshot ExecStart.
#
# HOW:
#   A debian:13-slim container (matching the distro) bind-mounts the ACTUAL
#   vacti-activate, sources its function body, and drives stage_token_and_enroll
#   under a stubbed `systemctl` that models Type=oneshot blocking, plus a stubbed
#   firstboot that atomically publishes engine.env after a delay. It measures real
#   wall-clock time for the with-fix vs without-fix bodies and checks the
#   engine_env_ready predicate against empty vs valid engine.env.
#
# The test run uses `--network none`: everything is simulated locally, no secrets,
# host systemd is never touched (systemctl is intercepted inside the container).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
IMAGE="vacti-kiosk-runtime-test:local"

ACTIVATE="$REPO/distro/enroll/activate/vacti-activate"
[[ -r "$ACTIVATE" ]] || { echo "FATAL: cannot read $ACTIVATE" >&2; exit 2; }

if ! command -v docker >/dev/null 2>&1; then
  echo "SKIP: docker not available - kiosk-runtime test needs a container to isolate from host systemd" >&2
  exit 3
fi

echo "== building test image ($IMAGE) =="
docker build -q -t "$IMAGE" -f "$HERE/Dockerfile" "$HERE" >/dev/null

echo "== running kiosk-runtime scenarios (container, --network none) =="
# Read-only bind mounts: the real activate script + this suite. All writable state
# (/work, /etc/vacti-engine) lives inside the ephemeral container.
docker run --rm \
  --network none \
  -v "$ACTIVATE":/src/vacti-activate:ro \
  -v "$HERE":/test:ro \
  "$IMAGE"
rc=$?

if [[ $rc -eq 0 ]]; then
  echo "== kiosk-runtime PASS =="
else
  echo "== kiosk-runtime FAIL (rc=$rc) ==" >&2
fi
exit $rc
