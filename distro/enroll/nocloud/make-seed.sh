#!/usr/bin/env bash
# make-seed.sh - mint-to-seed helper. Takes a FRESH, single-use, 3-hour-TTL
# enroll token (and the control-plane URL) and produces a CIDATA-labelled
# cidata.iso to attach as a second CD-ROM. The published image is NEVER
# pre-filled; the secret lives only in the seed the operator builds here, and
# the seed + user-data are gitignored.
#
# Usage:
#   make-seed.sh --token <ENROLL_TOKEN> --url <https://cp.example> [--out cidata.iso]
#
# Token discipline: this helper does NOT mint the token (minting is a
# control-plane action, mintEnrollmentTokenAction). It only packages a token the
# operator just minted. The token is single-use and expires in 3 hours, so
# build the seed and boot promptly; if it expires, re-mint and re-run.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOKEN=""; URL=""; OUT="cidata.iso"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --token) TOKEN="${2:?--token needs a value}"; shift 2 ;;
    --url)   URL="${2:?--url needs a value}"; shift 2 ;;
    --out)   OUT="${2:?--out needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$TOKEN" ]] || { echo "ERROR: --token is required (a freshly-minted single-use enroll token)" >&2; exit 2; }
[[ -n "$URL" ]]   || { echo "ERROR: --url is required (the control-plane base URL)" >&2; exit 2; }

# Basic liveness sanity: warn (do not block) if the token looks obviously stale.
[[ "${#TOKEN}" -ge 16 ]] || echo "WARN: token looks short; make sure it is a live single-use token" >&2

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

INSTANCE_ID="vacti-$(head -c6 /dev/urandom | od -An -tx1 | tr -d ' \n')"

# Fill the templates. Use a delimiter that cannot appear in a URL/token.
sed -e "s|__ENROLL_TOKEN__|${TOKEN}|g" -e "s|__VACTI_URL__|${URL}|g" \
  "${HERE}/user-data.example" > "${WORK}/user-data"
sed -e "s|__INSTANCE_ID__|${INSTANCE_ID}|g" \
  "${HERE}/meta-data.example" > "${WORK}/meta-data"

# Build the NoCloud seed ISO (volume label MUST be CIDATA for cloud-init).
if command -v genisoimage >/dev/null 2>&1; then
  genisoimage -quiet -output "$OUT" -volid CIDATA -joliet -rock "${WORK}/user-data" "${WORK}/meta-data"
elif command -v xorriso >/dev/null 2>&1; then
  xorriso -as mkisofs -quiet -o "$OUT" -V CIDATA -J -r "${WORK}/user-data" "${WORK}/meta-data"
else
  echo "ERROR: need genisoimage or xorriso to build the seed ISO" >&2; exit 1
fi

chmod 0600 "$OUT" 2>/dev/null || true
echo "[+] wrote ${OUT} (volid=CIDATA, instance-id=${INSTANCE_ID})."
echo "    Attach it as a second CD-ROM and boot. The token is single-use / 3h TTL; boot promptly."
echo "    Do NOT commit or redistribute ${OUT} - it carries the live token."
