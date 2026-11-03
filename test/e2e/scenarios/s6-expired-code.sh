#!/usr/bin/env bash
# s6-expired-code.sh - exchanging an EXPIRED short code returns 410.
#
# Mint a short code, let it expire, then exchange it. Expect 410 (gone).
# Default (mock) path expires the code instantly via the admin API so the suite
# stays fast. To exercise a REAL time-based expiry (e.g. the real CP's ~11-min
# TTL), export E2E_REAL_EXPIRY=1 and E2E_EXPIRY_WAIT (seconds, default 660); the
# scenario then actually sleeps instead of admin-expiring.
#
# Checkpoints:
#   c1 code minted
#   c2 code expired (admin, or real wait)
#   c3 exchange of the expired code returns 410
set -euo pipefail
E2E_SCENARIO="s6"
# shellcheck source=test/e2e/lib/assert.sh
. "${E2E_LIB}/assert.sh"
require_cmd curl

EX_URL="${E2E_EXCHANGE_URL:-${MOCK_CP_URL_HOST}/api/pentest/enroll/exchange}"
CODE="${S6_CODE:-EXPR-TEST}"
mock_reset

if [[ "${E2E_REAL_EXPIRY:-0}" == "1" ]]; then
  wait_s="${E2E_EXPIRY_WAIT:-660}"
  # mint with a TTL shorter than the wait so it is expired by exchange time.
  mock_mint "$CODE" "$(( wait_s / 2 ))"
  cp_pass "c1 code minted (ttl $(( wait_s / 2 ))s)"
  e2e_log "waiting ${wait_s}s for real time-based expiry"
  sleep "$wait_s"
  cp_pass "c2 waited past TTL"
else
  mock_mint "$CODE" 600
  cp_pass "c1 code minted"
  mock_admin POST /__admin/expire "$(printf '{"code":"%s"}' "$CODE")" >/dev/null
  cp_pass "c2 code expired (admin fast-path)"
fi

st="$(http_status POST "$EX_URL" "$(printf '{"code":"%s"}' "$CODE")")"
assert_http_status "$st" "410" "c3 expired code exchange returns 410"

e2e_ok "scenario 6 PASS"
