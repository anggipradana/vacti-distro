#!/bin/bash
# vacti-appliance-skin - operator helper (installed as /usr/sbin/vacti-appliance-skin).
#   --ack      accept the currently applied skin version: disarms the 24h auto-revert
#   --status   show applied version, ack state, revert deadline, diversions, masks
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=skin-lib.sh
. "${HERE}/skin-lib.sh"

usage() {
  cat <<EOF
usage: vacti-appliance-skin --ack | --status | --help
  --ack     acknowledge the applied skin (disarms the 24h auto-revert for this version)
  --status  show the skin state
  user migration (separate, operator-invoked): ${SKIN_LIBEXEC}/migrate-user.sh --help
EOF
}

do_ack() {
  local ver
  skin_require_root
  ver="$(skin_applied_version)"
  if [ -z "$ver" ]; then
    echo "skin is not applied (no ${SKIN_MARKER}); nothing to acknowledge" >&2
    exit 1
  fi
  install -d -m 0755 "$SKIN_STATE"
  printf '%s %s %s\n' "$ver" "$(date -u '+%FT%TZ')" "${SUDO_USER:-${USER:-root}}" > "$SKIN_ACK"
  rm -f "$SKIN_DEADLINE"
  systemctl disable --now "$SKIN_TIMER" >/dev/null 2>&1 || true
  skin_log "acknowledged skin ${ver}; auto-revert disarmed"
}

do_status() {
  local ver ack dl now
  ver="$(skin_applied_version)"
  ack="$(skin_acked_version)"
  echo "package version : $(skin_version)"
  echo "applied version : ${ver:-<not applied>}"
  echo "acknowledged    : ${ack:-<no>}"
  dl="$(awk 'NR==1{print $1}' "$SKIN_DEADLINE" 2>/dev/null || true)"
  if [ -n "$dl" ] && [ -n "$ver" ] && [ "$ack" != "$ver" ]; then
    now="$(date +%s)"
    echo "auto-revert at  : $(date -d "@${dl}" '+%F %T %Z' 2>/dev/null || echo "$dl") ($(((dl - now) / 60)) min)"
  fi
  echo "timer           : $(systemctl is-active "$SKIN_TIMER" 2>/dev/null || true)/$(systemctl is-enabled "$SKIN_TIMER" 2>/dev/null || true)"
  [ -f "${SKIN_STATE}/auto-reverted" ] && echo "last auto-revert: $(cat "${SKIN_STATE}/auto-reverted")"
  echo "diversions      :"
  skin_our_diversions | sed 's/^/  /; s/\t/ -> /'
  echo "masks           : $(skin_manifest_values mask | tr '\n' ' ')"
}

case "${1:-}" in
  --ack) do_ack ;;
  --status) do_status ;;
  -h | --help | '') usage ;;
  *)
    usage >&2
    exit 2
    ;;
esac
