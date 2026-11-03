#!/usr/bin/env bash
# run-e2e.sh - top-level orchestrator for the vacti-distro OVA + Docker + short-code
# end-to-end harness. Starts a SCOPED mock control-plane fixture (test double, never
# a real CP), exports a stable env contract, and dispatches one or all scenarios.
#
#   test/e2e/run-e2e.sh --all
#   test/e2e/run-e2e.sh --scenario 3
#   test/e2e/run-e2e.sh --cp-url https://cp.example.local --cp-admin-token <tok> --scenario 5
#
# Scenario matrix:
#   1  amd64/arm64 GUI OVA + GTK4 kiosk + short code         (qemu + vncdotool)
#   2  amd64/arm64 headless OVA + whiptail + short code      (qemu + expect)
#   3  Docker image + short code                             (docker)
#   4  Docker image + full enrollment token (backward-compat)(docker)
#   5  exchange rate-limit / lockout (429)                   (curl)
#   6  exchange expired code (410)                           (curl)
#   7  exchange consumed / single-use code (410)             (curl)
#
# Exit codes: 0 all selected scenarios passed; 1 one or more failed; 2 bad usage
# or a missing hard prerequisite (mock CP could not start).
#
# This harness is a TEST FIXTURE. The mock CP imitates only the enroll/exchange/apt
# surface and serves a clearly-labelled STUB engine package; it is never a control
# plane and never ships the real vacti-engine.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${HERE}/lib"
SCEN="${HERE}/scenarios"
# shellcheck source=test/e2e/lib/assert.sh
. "${LIB}/assert.sh"

usage() { sed -n '2,36p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# --- defaults --------------------------------------------------------------
SELECT=""
CP_URL=""                       # real CP (optional; for real-target scenarios)
CP_ADMIN_TOKEN=""               # NEVER baked; passed at runtime only
PAIRING_CODE_IN="${PAIRING_CODE:-TEST-CODE}"
RELEASE="${E2E_RELEASE:-0.1.0}"
ARCH="${E2E_ARCH:-amd64}"
HF_BASE="${E2E_HF_BASE:-https://huggingface.co/datasets/anggipradana/vacti-distro-images/resolve/main}"
IMAGE="${DOCKER_IMAGE:-ghcr.io/anggipradana/vacti-distro:0.1.0}"
MOCK_PORT="${MOCK_PORT:-8080}"
WORK="${E2E_WORK:-}"
KEEP_WORK=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all) SELECT="all" ;;
    --scenario) SELECT="${2:?}"; shift ;;
    --cp-url) CP_URL="${2:?}"; shift ;;
    --cp-admin-token) CP_ADMIN_TOKEN="${2:?}"; shift ;;
    --pairing-code) PAIRING_CODE_IN="${2:?}"; shift ;;
    --release) RELEASE="${2:?}"; shift ;;
    --arch) ARCH="${2:?}"; shift ;;
    --hf-base) HF_BASE="${2:?}"; shift ;;
    --image) IMAGE="${2:?}"; shift ;;
    --mock-port) MOCK_PORT="${2:?}"; shift ;;
    --work-dir) WORK="${2:?}"; shift ;;
    --no-kvm) export E2E_NO_KVM=1 ;;
    --keep-work) KEEP_WORK=1 ;;
    -h|--help) usage; exit 0 ;;
    *) e2e_err "unknown argument: $1"; usage; exit 2 ;;
  esac
  shift
done
[[ -n "$SELECT" ]] || { e2e_err "choose --all or --scenario N"; usage; exit 2; }

# --- workspace -------------------------------------------------------------
if [[ -z "$WORK" ]]; then WORK="$(mktemp -d "${TMPDIR:-/tmp}/vacti-e2e.XXXXXX")"; fi
mkdir -p "$WORK"
EVIDENCE="${WORK}/e2e"
DEB_DIR="${WORK}/apt-fixture"
mkdir -p "$EVIDENCE" "$DEB_DIR"
e2e_log "workspace: ${WORK}"

# --- start the mock CP fixture --------------------------------------------
require_cmd python3 curl
if ! python3 -c 'import flask' >/dev/null 2>&1; then
  e2e_err "python flask is required: pip install -r ${HERE}/requirements.txt"
  exit 2
fi
MOCK_ADMIN_TOKEN="mockadmin-$(head -c8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
MOCK_LOG="${WORK}/mock-cp.log"
e2e_log "starting mock CP fixture on 0.0.0.0:${MOCK_PORT} (test double only)"
MOCK_CP_HOST=0.0.0.0 MOCK_CP_PORT="$MOCK_PORT" \
MOCK_ADMIN_TOKEN="$MOCK_ADMIN_TOKEN" MOCK_SERVE_APT=1 MOCK_DEB_DIR="$DEB_DIR" \
  python3 "${LIB}/mock-cp-server.py" >"$MOCK_LOG" 2>&1 &
MOCK_PID=$!

cleanup() {
  [[ -n "${MOCK_PID:-}" ]] && kill "$MOCK_PID" 2>/dev/null || true
  # best-effort reap of any scenario-leaked qemu/containers is each scenario's job.
  if [[ "$KEEP_WORK" -eq 0 ]]; then rm -rf "$WORK"; else e2e_log "kept workspace: ${WORK}"; fi
}
trap cleanup EXIT INT TERM

# wait for health
ready=0
for _ in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:${MOCK_PORT}/healthz" >/dev/null 2>&1; then ready=1; break; fi
  kill -0 "$MOCK_PID" 2>/dev/null || { e2e_err "mock CP died on startup:"; cat "$MOCK_LOG" >&2; exit 2; }
  sleep 1
done
[[ "$ready" -eq 1 ]] || { e2e_err "mock CP did not become healthy; see ${MOCK_LOG}"; exit 2; }
e2e_ok "mock CP healthy"

# --- env contract exported to scenarios -----------------------------------
export E2E_ROOT="$HERE" E2E_LIB="$LIB" E2E_WORK="$WORK" E2E_EVIDENCE="$EVIDENCE"
export E2E_RELEASE="$RELEASE" E2E_ARCH="$ARCH" E2E_HF_BASE="$HF_BASE"
export DOCKER_IMAGE="$IMAGE"
export PAIRING_CODE="$PAIRING_CODE_IN"
export MOCK_PORT MOCK_ADMIN_TOKEN
export MOCK_ADMIN_URL="http://127.0.0.1:${MOCK_PORT}"
export MOCK_CP_URL_HOST="http://127.0.0.1:${MOCK_PORT}"
export GUEST_CP_URL_VM="http://10.0.2.2:${MOCK_PORT}"       # qemu SLIRP -> host
export GUEST_CP_URL_DOCKER="http://mock-cp:${MOCK_PORT}"    # --add-host mock-cp:host-gateway
# Real-CP passthrough (used by scenarios that opt in): never logged.
export E2E_CP_URL="$CP_URL" E2E_CP_ADMIN_TOKEN="$CP_ADMIN_TOKEN"

declare -A SCRIPTS=(
  [1]="${SCEN}/s1-ova-gui-shortcode.sh"
  [2]="${SCEN}/s2-ova-headless-shortcode.sh"
  [3]="${SCEN}/s3-docker-shortcode.sh"
  [4]="${SCEN}/s4-docker-fulltoken.sh"
  [5]="${SCEN}/s5-rate-limit.sh"
  [6]="${SCEN}/s6-expired-code.sh"
  [7]="${SCEN}/s7-consumed-code.sh"
)

run_one() { # n
  local n="$1" script="${SCRIPTS[$1]:-}"
  [[ -n "$script" ]] || { e2e_err "no such scenario: $n"; return 2; }
  e2e_log "================= scenario ${n} ================="
  mock_reset
  if bash "$script"; then RESULT[$n]="PASS"; return 0; else RESULT[$n]="FAIL"; return 1; fi
}

declare -A RESULT=()
rc=0
if [[ "$SELECT" == "all" ]]; then
  for n in 1 2 3 4 5 6 7; do run_one "$n" || rc=1; done
else
  run_one "$SELECT" || rc=1
fi

# --- summary ---------------------------------------------------------------
echo
e2e_log "================= SUMMARY ================="
for n in 1 2 3 4 5 6 7; do
  [[ -n "${RESULT[$n]:-}" ]] || continue
  if [[ "${RESULT[$n]}" == "PASS" ]]; then e2e_ok "scenario ${n}: PASS"; else e2e_err "scenario ${n}: FAIL"; fi
done
[[ "$rc" -eq 0 ]] && e2e_ok "ALL SELECTED SCENARIOS PASSED" || e2e_err "ONE OR MORE SCENARIOS FAILED"
exit "$rc"
