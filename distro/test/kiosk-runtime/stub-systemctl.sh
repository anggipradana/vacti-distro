#!/usr/bin/env bash
# stub-systemctl.sh - a drop-in `systemctl` shim placed FIRST on PATH so the real
# vacti-activate's `systemctl start ...` calls hit this instead of the host's
# systemd. It models a Type=oneshot firstboot unit.
#
# Behaviour of `systemctl start [--no-block] <unit>`:
#   * It ALWAYS spawns the stub firstboot writer in the background. That writer
#     publishes engine.env after STUB_FB_DELAY seconds (modelling firstboot writing
#     engine.env partway through its ExecStart).
#   * WITHOUT --no-block: it then BLOCKS for STUB_BLOCK_SECONDS before returning.
#     This is the crux of the bug - a plain `systemctl start` on a Type=oneshot unit
#     does not return until the WHOLE ExecStart finishes (which for firstboot
#     continues past the engine.env write into a slow `systemctl start
#     vacti-engine.service`). While systemctl blocks, the caller's poll loop below
#     it never runs, so the kiosk stays on "Enrolling device..." even though
#     engine.env already exists.
#   * WITH --no-block: it returns immediately, so the caller's poll loop runs
#     concurrently and returns the instant engine.env is content-ready.
#
# Any other subcommand (cat/disable/reboot/start of an unrelated unit) is a no-op
# success, so sourcing/driving the real script never touches host systemd.
set -euo pipefail

STUB_FB_SCRIPT="${STUB_FB_SCRIPT:?stub firstboot script path required}"
STUB_FB_DELAY="${STUB_FB_DELAY:-10}"
STUB_BLOCK_SECONDS="${STUB_BLOCK_SECONDS:-60}"

subcmd=""
no_block=0
for a in "$@"; do
  case "$a" in
    --no-block) no_block=1 ;;
    -*) : ;;                       # ignore other flags
    *) [[ -z "$subcmd" ]] && subcmd="$a" ;;
  esac
done

case "$subcmd" in
  start)
    # Fire the firstboot writer fully detached so it survives this shim exiting
    # (models the oneshot's ExecStart producing engine.env in the background).
    if command -v setsid >/dev/null 2>&1; then
      setsid env CFG_ENV="${CFG_ENV:-/etc/vacti-engine/engine.env}" \
                 STUB_FB_DELAY="$STUB_FB_DELAY" \
                 bash "$STUB_FB_SCRIPT" </dev/null >/dev/null 2>&1 &
    else
      CFG_ENV="${CFG_ENV:-/etc/vacti-engine/engine.env}" \
      STUB_FB_DELAY="$STUB_FB_DELAY" \
      bash "$STUB_FB_SCRIPT" </dev/null >/dev/null 2>&1 &
      disown 2>/dev/null || true
    fi
    if [[ "$no_block" -eq 0 ]]; then
      # Type=oneshot blocking semantics: ExecStart keeps running long after the
      # engine.env write, and `systemctl start` (no --no-block) waits for all of it.
      sleep "$STUB_BLOCK_SECONDS"
    fi
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
