#!/usr/bin/env bash
# s4-docker-fulltoken.sh - Docker + FULL enrollment token (backward-compat).
#
# Same as s3 but the operator supplies a 32-char full enrollment token directly
# (VACTI_ENROLL_TOKEN), so the entrypoint takes the pre-short-code path: NO
# exchange call, the token itself is the apt-pull credential and the enroll
# bearer. Proves the short-code work did not regress the historical token path.
#
# Checkpoints (fail on first miss):
#   c1 image present
#   c2 full token pre-registered in the mock; container started with it
#   c3 mock CP did NOT receive an exchange POST (path unchanged)
#   c4 mock CP served the engine .deb over apt with the SUPPLIED token
#   c5 mock CP received the enroll POST + entrypoint reached the engine runner
set -euo pipefail
E2E_SCENARIO="s4"
# shellcheck source=test/e2e/lib/assert.sh
. "${E2E_LIB}/assert.sh"

require_cmd docker curl
IMAGE="${DOCKER_IMAGE:-ghcr.io/anggipradana/vacti-distro:0.1.0}"
CNAME="vacti-e2e-s4"
CP_FOR_CONTAINER="${GUEST_CP_URL_DOCKER:-http://mock-cp:${MOCK_PORT}}"

# A 32-char hex token (mirrors the full enrollment-token shape; NOT a real token).
FULL_TOKEN="$(head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n')"

cleanup() { docker rm -f "$CNAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  docker pull "$IMAGE" || cp_fail "c1-image" "docker pull failed for ${IMAGE}"
fi
cp_pass "c1 image present"

# c2: pre-register the token so apt + enroll accept it, then run with it.
mock_issue_token "$FULL_TOKEN"
docker run -d --name "$CNAME" \
  --add-host "mock-cp:host-gateway" \
  -e "VACTI_ENROLL_TOKEN=${FULL_TOKEN}" \
  -e "VACTI_CP_URL=${CP_FOR_CONTAINER}" \
  "$IMAGE" >/dev/null \
  || cp_fail "c2-run" "docker run failed"
cp_pass "c2 container started with full token"

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
printf '%s\n' "$logs" > "${E2E_WORK:-/tmp}/s4-container.log" 2>/dev/null || true

# c3: NO exchange happened (the token was already full)
if echo "$state" | grep -q '"kind": "exchange"'; then
  cp_fail "c3-no-exchange" "unexpected exchange POST on the full-token path"
fi
cp_pass "c3 no exchange POST (full-token path unchanged)"

# c4: apt deb pulled with the supplied token
assert_contains "$state" '"is_deb": true' "c4 engine .deb pulled over apt with supplied token"

# c5: enroll + runner
assert_contains "$state" '"kind": "enroll"'          "c5 enroll POST received"
assert_contains "$logs"  'starting vacti-engine runner' "c5b entrypoint reached the engine runner"

e2e_ok "scenario 4 PASS"
