#!/usr/bin/env bash
# stub-firstboot.sh - simulates the engine.env write that the REAL
# distro/enroll/firstboot/vacti-firstboot performs at its step 3 (ENV_WRITTEN).
#
# It reproduces firstboot's ATOMIC publish sequence verbatim:
#   install -d -m0755 "$CFG_DIR"
#   ENV_TMP="$(mktemp "${CFG_ENV}.tmp.XXXXXX")"
#   <write populated KEY=value content to $ENV_TMP>
#   mv -f "$ENV_TMP" "$CFG_ENV"      # rename is atomic on the same fs
#   chmod 0600 "$CFG_ENV"
# (compare distro/enroll/firstboot/vacti-firstboot:149,162,215,224)
#
# The point of the delay: the real firstboot writes engine.env PART-WAY through a
# long ExecStart (it then goes on to `systemctl start vacti-engine.service`, a slow
# engine boot, at vacti-firstboot:233). So engine.env becomes observable while the
# oneshot unit is still "activating". This stub writes the file after STUB_FB_DELAY
# seconds to model exactly that window.
#
# No network. No secrets. The URL/value are generic placeholders.
set -euo pipefail

CFG_DIR="${CFG_DIR:-/etc/vacti-engine}"
CFG_ENV="${CFG_ENV:-${CFG_DIR}/engine.env}"
DELAY="${STUB_FB_DELAY:-10}"

sleep "$DELAY"

install -d -m0755 "$CFG_DIR"
ENV_TMP="$(mktemp "${CFG_ENV}.tmp.XXXXXX")"
# Content-complete engine.env: exists, non-empty, carries a populated KEY=value so
# the activate script's engine_env_ready predicate accepts it (not a zero-byte
# remnant). Generic placeholder host, no real endpoint.
{
  printf '%s\n' 'VACTI_URL=https://x/'
  printf '%s\n' 'VACTI_PRODUCER_TOKEN=stub-placeholder-token'
} > "$ENV_TMP"
mv -f "$ENV_TMP" "$CFG_ENV"
chmod 0600 "$CFG_ENV"
