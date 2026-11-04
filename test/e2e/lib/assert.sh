#!/usr/bin/env bash
# assert.sh - shared assertion + checkpoint helpers for the e2e harness.
#
# Sourced by every scenario. Scenarios are CHECKPOINT-oriented: each verifiable
# step is a named checkpoint. cp_pass records a met checkpoint; cp_fail prints the
# specific failed checkpoint and exits NON-ZERO immediately (fail-closed, fail on
# first miss - the brief's "fail with specific checkpoint on first miss"). No
# secret VALUE (token / code / admin token) is ever printed by these helpers.
#
# This file defines functions + a couple of log helpers ONLY; it has no side
# effects beyond defining them, so it is safe to source from anywhere.

# --- logging ---------------------------------------------------------------
e2e_log()  { printf '[e2e] %s\n'        "$*"; }
e2e_ok()   { printf '[e2e][ok]   %s\n'  "$*"; }
e2e_warn() { printf '[e2e][warn] %s\n'  "$*" >&2; }
e2e_err()  { printf '[e2e][FAIL] %s\n'  "$*" >&2; }

# --- checkpoints -----------------------------------------------------------
# A scenario sets E2E_SCENARIO (e.g. "s3") for nicer messages; optional.
cp_pass() { # name
  e2e_ok "checkpoint PASS: ${E2E_SCENARIO:+[${E2E_SCENARIO}] }$1"
}

# cp_fail NAME [DETAIL] - print the specific checkpoint that failed and exit 1.
cp_fail() { # name [detail]
  local name="$1"; shift || true
  e2e_err "checkpoint FAIL: ${E2E_SCENARIO:+[${E2E_SCENARIO}] }${name}${1:+ -- $*}"
  exit 1
}

# --- generic assertions (each fails the current checkpoint on miss) ---------
# assert_eq GOT WANT CHECKPOINT
assert_eq() { # got want checkpoint
  if [[ "$1" == "$2" ]]; then
    cp_pass "$3 (==$2)"
  else
    cp_fail "$3" "expected '$2' got '$1'"
  fi
}

# assert_contains HAYSTACK NEEDLE CHECKPOINT
assert_contains() { # haystack needle checkpoint
  if [[ "$1" == *"$2"* ]]; then
    cp_pass "$3"
  else
    cp_fail "$3" "expected substring '$2'"
  fi
}

# assert_file_contains FILE NEEDLE CHECKPOINT
assert_file_contains() { # file needle checkpoint
  if [[ -f "$1" ]] && grep -qF -- "$2" "$1"; then
    cp_pass "$3"
  else
    cp_fail "$3" "file '$1' missing or lacks '$2'"
  fi
}

# assert_http_status GOT WANT CHECKPOINT - WANT may be a |-list e.g. "404|410"
assert_http_status() { # got want checkpoint
  local got="$1" want="$2" name="$3"
  case "|$want|" in
    *"|$got|"*) cp_pass "$name (HTTP $got)" ;;
    *)          cp_fail "$name" "expected HTTP in [$want] got $got" ;;
  esac
}

# image_has_file IMAGE PATH - non-failing probe (NO checkpoint side effects) for
# whether PATH exists inside a qcow2/raw disk IMAGE, via libguestfs (read-only).
# Return: 0 present, 1 absent, 2 cannot determine (no libguestfs / unreadable image).
# Used to AUTO-DETECT the image form (fat vs thin) so a scenario stays correct for
# both without an env flag, and never breaks the pre-existing thin expectation.
image_has_file() { # image path
  local image="$1" path="$2"
  [[ -f "$image" ]] || return 2
  if command -v guestfish >/dev/null 2>&1; then
    local out; out="$(guestfish --ro -a "$image" -i exists "$path" 2>/dev/null)" || return 2
    [[ "$out" =~ ^true ]] && return 0 || return 1
  elif command -v virt-ls >/dev/null 2>&1; then
    local dir base; dir="$(dirname "$path")"; base="$(basename "$path")"
    local listing; listing="$(virt-ls -a "$image" "$dir" 2>/dev/null)" || return 2
    grep -qx "$base" <<<"$listing" && return 0 || return 1
  fi
  return 2
}

# assert_image_has_file IMAGE PATH CHECKPOINT - static, read-only check that PATH
# exists INSIDE a qcow2/raw disk IMAGE, using libguestfs. Used to prove the FAT-OVA
# bake (the engine marker is on disk BEFORE first boot). Soft-skips with a warning -
# NOT a failure - when no libguestfs tool (guestfish/virt-ls) is installed, so the
# harness still runs on a host without libguestfs. Never prints file contents.
assert_image_has_file() { # image path checkpoint
  local image="$1" path="$2" name="$3"
  [[ -f "$image" ]] || cp_fail "$name" "image '$image' not found"
  if command -v guestfish >/dev/null 2>&1; then
    if guestfish --ro -a "$image" -i exists "$path" 2>/dev/null | grep -qi '^true'; then
      cp_pass "$name ($path present)"
    else
      cp_fail "$name" "$path absent inside $image"
    fi
  elif command -v virt-ls >/dev/null 2>&1; then
    if virt-ls -a "$image" "$(dirname "$path")" 2>/dev/null | grep -qx "$(basename "$path")"; then
      cp_pass "$name ($path present)"
    else
      cp_fail "$name" "$path absent inside $image"
    fi
  else
    e2e_warn "libguestfs (guestfish/virt-ls) not installed; SKIPPING static image check '$name' ($path)"
  fi
}

# require_cmd CMD... - fail-closed if a required command is missing.
require_cmd() { # cmd...
  local c missing=0
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || { e2e_err "required command not found: $c"; missing=1; }
  done
  [[ "$missing" -eq 0 ]] || cp_fail "prereq" "install the missing command(s) above"
}

# --- mock CP admin helpers -------------------------------------------------
# These talk to lib/mock-cp-server.py's /__admin API over the loopback admin
# port. MOCK_ADMIN_URL + MOCK_ADMIN_TOKEN are exported by run-e2e.sh.
mock_admin() { # method path [json-body]
  local method="$1" path="$2" body="${3:-}"
  local args=(-sS -o - -w $'\n%{http_code}' -X "$method"
              -H "X-Mock-Admin: ${MOCK_ADMIN_TOKEN:-}")
  [[ -n "$body" ]] && args+=(-H 'Content-Type: application/json' --data "$body")
  curl "${args[@]}" "${MOCK_ADMIN_URL%/}${path}" 2>/dev/null || printf '\n000'
}

# mock_mint CODE TTL_SECONDS - mint a pairing code in the mock CP. Echoes nothing
# sensitive. Returns the admin HTTP status in MOCK_LAST_STATUS.
mock_mint() { # code ttl_seconds
  local out; out="$(mock_admin POST /__admin/mint "$(printf '{"code":"%s","ttl_seconds":%s}' "$1" "$2")")"
  MOCK_LAST_STATUS="${out##*$'\n'}"
  [[ "$MOCK_LAST_STATUS" == "200" ]] || cp_fail "mock-mint" "admin mint returned HTTP $MOCK_LAST_STATUS"
}

# mock_issue_token TOKEN - pre-register a full enrollment token (no exchange),
# for the backward-compat (full-token) scenario.
mock_issue_token() { # token
  local out; out="$(mock_admin POST /__admin/issue-token "$(printf '{"token":"%s"}' "$1")")"
  MOCK_LAST_STATUS="${out##*$'\n'}"
  [[ "$MOCK_LAST_STATUS" == "200" ]] || cp_fail "mock-issue-token" "admin issue-token returned HTTP $MOCK_LAST_STATUS"
}

# mock_state - echo the mock CP state JSON (request log + codes) on stdout.
mock_state() { mock_admin GET /__admin/state | sed '$d'; }

# mock_reset - clear mock CP state between scenarios (idempotency).
mock_reset() { mock_admin POST /__admin/reset >/dev/null; }

# --- http helper -----------------------------------------------------------
# http_status METHOD URL [json-body] [extra-curl-args...] -> echoes status code.
http_status() { # method url [body] [curl-args...]
  local method="$1" url="$2" body="${3:-}"; shift || true; shift || true; shift || true
  local args=(-sS -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 30 -X "$method")
  [[ -n "$body" ]] && args+=(-H 'Content-Type: application/json' --data "$body")
  curl "${args[@]}" "$@" "$url" 2>/dev/null || echo "000"
}
