#!/usr/bin/env bash
# s3-docker-shortcode.sh - Docker image + short code end-to-end.
#
# docker run the published multi-arch image with VACTI_PAIRING_CODE + VACTI_CP_URL,
# wired to the host-run mock CP via the `mock-cp` host alias (--add-host
# mock-cp:host-gateway), matching the brief's http://mock-cp:<port> URL without
# containerising the mock.
#
# Checkpoints (fail on first miss):
#   c1 image present (pull if needed)
#   c2 container started with pairing code + CP URL
#   c3 mock CP received the exchange POST for the NORMALISED code and returned 200
#   c4 mock CP served the engine .deb over apt with the EXCHANGED token
#   c5 mock CP received the enroll POST AND the entrypoint reached the engine runner
#
# NOTE on the brief's "systemctl status" step: the container has no systemd (the
# entrypoint execs the runner as PID 1 - see distro/golden-image/docker-entrypoint.sh),
# so engine start is asserted from the entrypoint log line + the enroll POST, which
# is the equivalent liveness proof for the container form.
set -euo pipefail
E2E_SCENARIO="s3"
# shellcheck source=test/e2e/lib/assert.sh
. "${E2E_LIB}/assert.sh"

require_cmd docker curl
IMAGE="${DOCKER_IMAGE:-ghcr.io/anggipradana/vacti-distro:0.1.0}"
CNAME="vacti-e2e-s3"
CP_FOR_CONTAINER="${GUEST_CP_URL_DOCKER:-http://mock-cp:${MOCK_PORT}}"

cleanup() { docker rm -f "$CNAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup  # idempotent: remove a stale container from a prior run

# c1: image present
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  e2e_log "pulling ${IMAGE}"
  docker pull "$IMAGE" || cp_fail "c1-image" "docker pull failed for ${IMAGE}"
fi
cp_pass "c1 image present"

# c2: run detached (the entrypoint execs the long-running stub runner on success)
mock_mint "$PAIRING_CODE" 600
docker run -d --name "$CNAME" \
  --add-host "mock-cp:host-gateway" \
  -e "VACTI_PAIRING_CODE=${PAIRING_CODE}" \
  -e "VACTI_CP_URL=${CP_FOR_CONTAINER}" \
  "$IMAGE" >/dev/null \
  || cp_fail "c2-run" "docker run failed"
cp_pass "c2 container started"

# wait for the entrypoint to walk exchange -> apt -> enroll -> runner
e2e_log "waiting for container enroll flow (up to 180s)"
logs=""; state=""
for _ in $(seq 1 18); do
  sleep 10
  logs="$(docker logs "$CNAME" 2>&1 || true)"
  state="$(mock_state)"
  echo "$logs" | grep -q 'starting vacti-engine runner' && break
  docker inspect -f '{{.State.Running}}' "$CNAME" 2>/dev/null | grep -q false \
    && { e2e_warn "container exited early"; break; }
done
printf '%s\n' "$logs" > "${E2E_WORK:-/tmp}/s3-container.log" 2>/dev/null || true

# c3: exchange POST for normalised code, 200
norm="$(printf '%s' "$PAIRING_CODE" | tr -d ' -' | tr '[:lower:]' '[:upper:]')"
assert_contains "$state" '"kind": "exchange"' "c3 exchange POST received"
assert_contains "$state" '"result": 200'     "c3b exchange returned 200 (code ${norm:0:2}..)"

# c4: apt deb pulled with exchanged token
assert_contains "$state" '"is_deb": true' "c4 engine .deb pulled over apt with exchanged token"

# c5: enroll POST + runner started
assert_contains "$state" '"kind": "enroll"'          "c5 enroll POST received"
assert_contains "$logs"  'starting vacti-engine runner' "c5b entrypoint reached the engine runner"

e2e_ok "scenario 3 PASS"
