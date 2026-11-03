#!/usr/bin/env bash
# s5-rate-limit.sh - exchange endpoint per-IP lockout.
#
# Fire 11 wrong codes rapidly from the same IP. Expect 10 x {404|410} then a
# 429 lockout. The 1h clear is abstracted (we assert the 429 fired, not the wait,
# per the brief). Runs against the mock CP by default; export E2E_EXCHANGE_URL to
# point at the real CP's /api/pentest/enroll/exchange instead.
#
# Checkpoints: c1..c10 each wrong attempt is 404/410; c11 the 11th is 429.
set -euo pipefail
E2E_SCENARIO="s5"
# shellcheck source=test/e2e/lib/assert.sh
. "${E2E_LIB}/assert.sh"
require_cmd curl

EX_URL="${E2E_EXCHANGE_URL:-${MOCK_CP_URL_HOST}/api/pentest/enroll/exchange}"
mock_reset  # start from a clean per-IP counter (idempotent)

for i in $(seq 1 10); do
  code="WRONG$(printf '%03d' "$i")"   # never minted -> not found
  st="$(http_status POST "$EX_URL" "$(printf '{"code":"%s"}' "$code")")"
  assert_http_status "$st" "404|410" "c${i} wrong attempt #${i} rejected"
done

st="$(http_status POST "$EX_URL" '{"code":"WRONG011"}')"
assert_http_status "$st" "429" "c11 11th attempt locked out (429)"

e2e_ok "scenario 5 PASS"
