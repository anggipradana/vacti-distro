#!/usr/bin/env bash
# incontainer.sh - runs INSIDE the debian:13-slim container (no network). It sources
# the ACTUAL distro/enroll/activate/vacti-activate function body and drives
# stage_token_and_enroll / engine_env_ready under the Type=oneshot systemctl stub,
# measuring real wall-clock time. Exits non-zero on ANY scenario miss.
#
# Mounts provided by run.sh:
#   /src/vacti-activate   (ro)  - the real, current activate script
#   /test                 (ro)  - this suite (stubs + patch + this driver)
set -uo pipefail

SRC_ACTIVATE="/src/vacti-activate"
TEST_DIR="/test"
WORK="/work"
STUBBIN="$WORK/stubbin"
CFG_DIR="/etc/vacti-engine"
CFG_ENV="$CFG_DIR/engine.env"

# Timing / modelling knobs (kept well inside the 3-minute end-to-end budget).
FB_DELAY=10          # firstboot writes engine.env this many seconds after start
BLOCK_SECONDS=60     # a plain (blocking) oneshot `systemctl start` takes this long
THRESH_FIX=15        # with-fix must return under this
THRESH_NOFIX=50      # without-fix must exceed this

export STUB_FB_SCRIPT="$TEST_DIR/stub-firstboot.sh"
export STUB_FB_DELAY="$FB_DELAY"
export STUB_BLOCK_SECONDS="$BLOCK_SECONDS"
export CFG_ENV

mkdir -p "$WORK" "$STUBBIN"

# Install the systemctl stub first on PATH so the real script's systemctl calls
# are intercepted and host systemd is NEVER touched.
cp "$TEST_DIR/stub-systemctl.sh" "$STUBBIN/systemctl"
chmod +x "$STUBBIN/systemctl"
export PATH="$STUBBIN:$PATH"

# --- Build the two function bodies we exercise --------------------------------
# The real script runs a `case "${1:-}"` dispatch + main boot body at the bottom;
# we source only the prefix (config vars + function definitions, everything BEFORE
# that dispatch) so sourcing defines stage_token_and_enroll / engine_env_ready
# without executing the boot path. The boundary is found dynamically.
extract_funcs() { # <src-activate> <out>
  awk '/^case "\$\{1:-\}" in/{exit} {print}' "$1" > "$2"
}

# WITH-fix body: straight from the real current script.
extract_funcs "$SRC_ACTIVATE" "$WORK/activate-funcs-fixed.sh"

# WITHOUT-fix body: apply the scratchpad revert patch to a COPY (never the mounted
# read-only original), then extract. The patch is applied INSIDE the container with
# `patch`; no git, the worktree is untouched.
cp "$SRC_ACTIVATE" "$WORK/vacti-activate"
( cd "$WORK" && patch -p1 --silent < "$TEST_DIR/without-fix.patch" ) \
  || { echo "FATAL: could not apply without-fix.patch" >&2; exit 2; }
extract_funcs "$WORK/vacti-activate" "$WORK/activate-funcs-nofix.sh"

# Sanity: both prefixes must actually define the functions we are about to call.
for f in "$WORK/activate-funcs-fixed.sh" "$WORK/activate-funcs-nofix.sh"; do
  if ! bash -c "source '$f'; declare -F stage_token_and_enroll >/dev/null && declare -F engine_env_ready >/dev/null"; then
    echo "FATAL: $f did not define the expected functions" >&2
    exit 2
  fi
done

reset_state() {
  pkill -f "$TEST_DIR/stub-firstboot.sh" 2>/dev/null || true
  rm -rf "$CFG_DIR"
  mkdir -p "$CFG_DIR"
}

# Run stage_token_and_enroll from the given function body and return elapsed seconds
# on stdout. Runs in a subshell so the script's `set -euo pipefail` and the stubbed
# systemctl do not leak into this driver.
time_enroll() { # <funcs-file>
  local funcs="$1" start end
  start="$(date +%s)"
  (
    # shellcheck source=/dev/null
    source "$funcs"
    stage_token_and_enroll "https://x/" "stub-token" "vacti-firstboot.service"
  ) >/dev/null 2>&1 || true
  end="$(date +%s)"
  echo "$(( end - start ))"
}

# Evaluate engine_env_ready against whatever is currently at $CFG_ENV; echo its rc.
rc_engine_env_ready() { # <funcs-file>
  local funcs="$1"
  (
    # shellcheck source=/dev/null
    source "$funcs"
    engine_env_ready
  ) >/dev/null 2>&1
  echo "$?"
}

overall=0
declare -a REPORT

# --- SCENARIO 1: with fix, content-complete engine.env ------------------------
reset_state
s1="$(time_enroll "$WORK/activate-funcs-fixed.sh")"
if [[ "$s1" -lt "$THRESH_FIX" ]]; then v1=PASS; else v1=FAIL; overall=1; fi
REPORT+=("SCENARIO 1 (with fix, content-complete engine.env): elapsed=${s1}s, expected < ${THRESH_FIX}s -> $v1")

# --- SCENARIO 2: without fix, same input --------------------------------------
reset_state
s2="$(time_enroll "$WORK/activate-funcs-nofix.sh")"
if [[ "$s2" -gt "$THRESH_NOFIX" ]]; then v2=PASS; else v2=FAIL; overall=1; fi
REPORT+=("SCENARIO 2 (without fix, same input): elapsed=${s2}s, expected > ${THRESH_NOFIX}s -> $v2")

# --- SCENARIO 3: empty engine.env (case 5) ------------------------------------
reset_state
: > "$CFG_ENV"            # zero-byte / empty engine.env
r3="$(rc_engine_env_ready "$WORK/activate-funcs-fixed.sh")"
if [[ "$r3" -ne 0 ]]; then v3=PASS; else v3=FAIL; overall=1; fi
REPORT+=("SCENARIO 3 (empty engine.env): engine_env_ready rc=${r3}, expected non-zero -> $v3")

# --- SCENARIO 4: valid engine.env ---------------------------------------------
reset_state
printf '%s\n' 'VACTI_URL=https://x/' > "$CFG_ENV"
r4="$(rc_engine_env_ready "$WORK/activate-funcs-fixed.sh")"
if [[ "$r4" -eq 0 ]]; then v4=PASS; else v4=FAIL; overall=1; fi
REPORT+=("SCENARIO 4 (valid engine.env): engine_env_ready rc=${r4}, expected zero -> $v4")

reset_state

echo "======== kiosk-runtime report ========"
for line in "${REPORT[@]}"; do echo "$line"; done
echo "======================================"
# Adversarial delta check: scenario 2 must exceed scenario 1 by a wide margin,
# proving the fix changed the observable outcome (not just that each threshold held).
delta=$(( s2 - s1 ))
echo "delta (scenario2 - scenario1) = ${delta}s (fix changes observable behaviour)"
if [[ "$delta" -le 35 ]]; then
  echo "DELTA FAIL: without-fix did not stall markedly longer than with-fix" >&2
  overall=1
fi

[[ "$overall" -eq 0 ]] && echo "ALL SCENARIOS PASS" || echo "ONE OR MORE SCENARIOS FAILED" >&2
exit "$overall"
