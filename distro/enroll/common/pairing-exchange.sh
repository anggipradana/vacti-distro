#!/usr/bin/env bash
# distro/enroll/common/pairing-exchange.sh - shared short-code pairing exchange.
#
# Installed at runtime as /usr/local/lib/vacti/pairing-exchange.sh and SOURCED by
# the two NON-GUI enrollment paths so both accept an 8-char pairing code
# (K7X9-R8W2) in addition to the full 32-char UUID enrollment token - the same
# convenience the premium GTK4 kiosk (vacti-activate / vacti-kiosk) already offers:
#
#   * distro/enroll/netsetup/vacti-netsetup   (headless whiptail TUI)
#   * distro/golden-image/docker-entrypoint.sh (container ENTRYPOINT)
#
# The short code is CONTROL-PLANE-scoped: it is exchanged at
#   POST ${base}/api/pentest/enroll/exchange   body {"code":"K7X9R8W2"}
# which returns 200 {"token":"<full-uuid>"} on success. The code is normalised
# (uppercased, hyphens/spaces stripped) on the client exactly as the CP does
# (code.replace(/[\s-]+/g,'').toUpperCase()). No code or token VALUE is ever
# logged here; parsing/validation of the resulting full token stays the job of
# the existing enroll chain (vacti-firstboot / the enroll POST). This file
# defines functions ONLY and has no side effects when sourced.

# vacti_is_short_code RAW -> 0 if RAW looks like an 8-char pairing code, else 1.
# Crockford-ish alphabet (no I/O/0/1), optionally hyphenated XXXX-XXXX. Anything
# else (e.g. a full UUID enrollment token) is NOT a short code and must pass
# through verbatim. Mirrors the GUI kiosk's SHORT_CODE_RE and the CP contract.
vacti_is_short_code() { # raw
  local s="${1//[[:space:]]/}"; s="${s^^}"
  [[ "$s" =~ ^[A-HJ-NP-Z2-9]{4}-?[A-HJ-NP-Z2-9]{4}$ ]]
}

# vacti_pairing_exchange URL CODE
# Exchange a short code for the full enrollment token. Prints the token on stdout
# on success. Exit codes (mirroring vacti-activate's resolve_exchange contract):
#   0  ok (token on stdout)
#   44 HTTP 404 - code not found
#   41 HTTP 410 - code gone (expired / already consumed; single-use, 3h TTL)
#   49 HTTP 409 - operator gone
#   42 HTTP 429 - rate-limited / lockout
#   1  network / other / empty token
# The code is normalised (uppercased, hyphen+space-stripped) before sending.
vacti_pairing_exchange() { # url code
  local base="${1%/}" code="${2//[[:space:]]/}"
  code="${code^^}"; code="${code//-/}"
  local out http tok="" rc=1
  out="$(mktemp)"
  http="$(curl -sS -o "$out" -w '%{http_code}' --connect-timeout 10 --max-time 20 \
      -H 'Content-Type: application/json' \
      -X POST "${base}/api/pentest/enroll/exchange" \
      --data "$(printf '{"code":"%s"}' "$code")" 2>/dev/null || true)"
  case "$http" in
    200)
      if command -v jq >/dev/null 2>&1; then
        tok="$(jq -r '.token // empty' "$out" 2>/dev/null)"
      fi
      [[ -z "$tok" ]] && tok="$(sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$out" | head -n1)"
      if [[ -n "$tok" ]]; then printf '%s' "$tok"; rc=0; else rc=1; fi
      ;;
    404) rc=44 ;;
    410) rc=41 ;;
    409) rc=49 ;;
    429) rc=42 ;;
    *)   rc=1 ;;
  esac
  rm -f "$out"
  return "$rc"
}

# vacti_pairing_error_en RC -> a one-line English reason for a non-zero exchange rc.
vacti_pairing_error_en() { # rc
  case "${1:-1}" in
    44) echo "pairing code not found - check it and try again" ;;
    41) echo "pairing code expired or already used (single-use, 3h TTL) - re-mint in the dashboard" ;;
    49) echo "pairing session is no longer available - re-mint a code in the dashboard" ;;
    42) echo "too many attempts - wait a moment and try again" ;;
    *)  echo "network error while exchanging the pairing code - try again" ;;
  esac
}

# vacti_pairing_error_id RC -> a one-line Indonesian reason for a non-zero rc.
vacti_pairing_error_id() { # rc
  case "${1:-1}" in
    44) echo "Kode tidak ditemukan. Periksa lalu coba lagi." ;;
    41) echo "Kode sudah dipakai atau kedaluwarsa (sekali pakai, 3 jam). Mint ulang di dashboard." ;;
    49) echo "Sesi kode tidak tersedia lagi. Mint ulang kode di dashboard." ;;
    42) echo "Terlalu banyak percobaan. Tunggu sebentar lalu coba lagi." ;;
    *)  echo "Gangguan jaringan saat menukar kode. Coba lagi." ;;
  esac
}
