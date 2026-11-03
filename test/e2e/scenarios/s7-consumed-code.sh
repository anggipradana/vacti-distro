#!/usr/bin/env bash
# s7-consumed-code.sh - a short code is single-use: a second exchange returns 410.
#
# Mint a code, exchange it successfully (200 + token), then exchange the SAME code
# again and expect 410 (gone: already consumed). Runs against the mock CP by
# default; export E2E_EXCHANGE_URL to target the real CP's exchange endpoint.
#
# Checkpoints:
#   c1 code minted
#   c2 first exchange succeeds (200) and returns a token
#   c3 second exchange of the same code returns 410
set -euo pipefail
E2E_SCENARIO="s7"
# shellcheck source=test/e2e/lib/assert.sh
. "${E2E_LIB}/assert.sh"
require_cmd curl

EX_URL="${E2E_EXCHANGE_URL:-${MOCK_CP_URL_HOST}/api/pentest/enroll/exchange}"
CODE="${S7_CODE:-ONCE-TEST}"
mock_reset
mock_mint "$CODE" 600
cp_pass "c1 code minted"

# c2: first exchange -> 200 with a token (body captured to a temp file; the token
# VALUE is never printed, only its presence asserted).
tmp="$(mktemp)"
st="$(curl -sS -o "$tmp" -w '%{http_code}' --max-time 20 \
      -H 'Content-Type: application/json' \
      -X POST "$EX_URL" --data "$(printf '{"code":"%s"}' "$CODE")" 2>/dev/null || echo 000)"
assert_http_status "$st" "200" "c2 first exchange succeeds"
if grep -q '"token"' "$tmp"; then cp_pass "c2b first exchange returned a token"; else rm -f "$tmp"; cp_fail "c2b-token" "no token in 200 response"; fi
rm -f "$tmp"

# c3: second exchange of the same (now consumed) code -> 410
st="$(http_status POST "$EX_URL" "$(printf '{"code":"%s"}' "$CODE")")"
assert_http_status "$st" "410" "c3 reused code exchange returns 410"

e2e_ok "scenario 7 PASS"
