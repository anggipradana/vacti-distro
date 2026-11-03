#!/usr/bin/env bash
# inject-input.sh - input-injection + screenshot helpers for the VM scenarios.
#
# GUI flavor  : drive the GTK4 pre-login kiosk (vacti-kiosk) over the qemu VNC
#               using vncdotool - the kiosk has an "URL control-plane" entry and a
#               "Kode aktivasi / Token" entry (confirmed in
#               distro/enroll/activate/vacti-kiosk), then an apply action.
# Headless    : drive the whiptail netsetup prompts (vacti-netsetup) over the
#               serial PTY using expect - it asks "Control-plane URL" then a
#               pairing-code/token prompt (confirmed in
#               distro/enroll/netsetup/vacti-netsetup).
#
# No code/token VALUE is echoed to the log by these helpers.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test/e2e/lib/assert.sh
. "${HERE}/assert.sh"

# vnc_shot HOST::PORT OUTPNG - capture a VNC screenshot (boot progress evidence).
vnc_shot() { # host::port outpng
  local target="$1" out="$2"
  command -v vncdo >/dev/null 2>&1 || { e2e_warn "vncdotool (vncdo) not installed; skipping screenshot"; return 0; }
  vncdo -s "$target" capture "$out" >/dev/null 2>&1 \
    && e2e_log "screenshot -> $out" \
    || e2e_warn "VNC capture failed (guest may still be pre-display)"
}

# vnc_wait_for_display HOST::PORT DIR PREFIX TIMEOUT - poll every 30s, capturing a
# screenshot each cycle, until the VNC server accepts a capture (a GUI is up) or
# the timeout elapses. Returns 0 if a capture ever succeeded.
vnc_wait_for_display() { # host::port dir prefix timeout
  local target="$1" dir="$2" prefix="$3" timeout="$4"
  command -v vncdo >/dev/null 2>&1 || { e2e_warn "vncdotool missing; cannot verify GUI"; return 1; }
  mkdir -p "$dir"
  local waited=0 n=0 shot ok=1
  while [[ "$waited" -lt "$timeout" ]]; do
    n=$((n + 1))
    shot="$(printf '%s/%s-%02d.png' "$dir" "$prefix" "$n")"
    if vncdo -s "$target" capture "$shot" >/dev/null 2>&1; then
      e2e_log "boot screenshot $n captured ($shot)"
      ok=0
    else
      e2e_log "boot screenshot $n: VNC not ready yet (t=${waited}s)"
    fi
    sleep 30; waited=$((waited + 30))
    [[ "$ok" -eq 0 && "$waited" -ge 60 ]] && break
  done
  return "$ok"
}

# vnc_type_kiosk HOST::PORT URL CODE - type the CP URL + short code into the
# kiosk's two entry rows and submit. Uses Tab to move between fields and Enter to
# activate the default (apply) action. The code is passed via a file/arg; it is
# not echoed. Requires vncdotool.
vnc_type_kiosk() { # host::port url code
  local target="$1" url="$2" code="$3"
  require_cmd vncdo
  e2e_log "typing CP URL + activation code into kiosk (code not logged)"
  # Focus the first entry (URL). The kiosk focuses its first row on show; a
  # leading Tab makes focus deterministic across themes.
  vncdo -s "$target" key tab >/dev/null 2>&1 || true
  vncdo -s "$target" type "$url" >/dev/null 2>&1 || cp_fail "kiosk-input" "could not type URL"
  vncdo -s "$target" key tab >/dev/null 2>&1
  vncdo -s "$target" type "$code" >/dev/null 2>&1 || cp_fail "kiosk-input" "could not type code"
  # Move to the apply button and activate.
  vncdo -s "$target" key tab key tab key return >/dev/null 2>&1 || true
  e2e_ok "kiosk input submitted"
}

# expect_netsetup PTY URL CODE LOGFILE - drive the whiptail netsetup prompts over
# the serial console. Keeps DHCP (default), skips proxy/VPN, enters the CP URL,
# then the pairing code. Writes the raw session to LOGFILE for assertions.
expect_netsetup() { # pty url code logfile
  local pty="$1" url="$2" code="$3" logfile="$4"
  require_cmd expect
  e2e_log "driving headless netsetup over serial (code not logged)"
  # shellcheck disable=SC2016  # the $-vars below are expect/Tcl, not bash
  VACTI_PTY="$pty" VACTI_URL="$url" VACTI_CODE="$code" VACTI_LOG="$logfile" \
  expect <<'EXPECT'
set timeout 300
set pty  $env(VACTI_PTY)
set url  $env(VACTI_URL)
set code $env(VACTI_CODE)
log_file -a $env(VACTI_LOG)
spawn -open [open $pty r+]
# Keep DHCP / skip static + proxy + VPN: answer "No" (Tab then Enter on whiptail
# yesno defaults vary; sending just Return accepts the highlighted default which
# for these is the safe path). Then fill URL and code.
expect {
  -re "STATIC IPv4" { send "\t\r"; exp_continue }
  -re "proxy" { send "\r"; exp_continue }
  -re "VPN"   { send "\t\r"; exp_continue }
  -re "[Cc]ontrol-plane URL" { send "$url\r"; exp_continue }
  -re "[Pp]airing code" { send "$code\r" }
  timeout { exit 3 }
}
# Give the enroll chain time to run.
expect {
  -re "enroll" { exp_continue }
  timeout { }
  eof { }
}
EXPECT
  e2e_ok "netsetup input submitted"
}

# Allow direct invocation for ad-hoc use: inject-input.sh <fn> <args...>
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  fn="${1:?usage: inject-input.sh <vnc_shot|vnc_wait_for_display|vnc_type_kiosk|expect_netsetup> ...}"
  shift
  "$fn" "$@"
fi
