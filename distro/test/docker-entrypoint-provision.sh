#!/usr/bin/env bash
# docker-entrypoint-provision.sh - runtime contract test for the container first boot.
#
# Executes the REAL distro/golden-image/docker-entrypoint.sh, unprivileged, against a
# FAKE control plane, and asserts it stages what the OVA first boot stages:
#   1. the X-Engine-Auth edge secret (engineSharedSecret) persisted to engine.env 0600
#      and EXPORTED into the engine process env (jq path AND node fallback);
#   2. a tailscaled daemon started with its state on the state volume (kernel mode,
#      userspace fallback, opt-out, absent binary) - and NO `tailscale up` here;
#   3. caido-cli presence reported, and NO boot-time Caido login artifact.
# Plus: enroll failure stays FATAL, a CP that omits the secret yields the pre-fix
# engine.env, and a restart reuses the persisted secret.
#
# Hermetic: the entrypoint runs with a sandbox PATH of symlinked host tools plus fakes
# (curl, tailscaled, tailscale, pgrep), so no network, no root, no host tailscaled.
# The engine marker (dist/runner/cli.js) is present, so the apt pull is skipped, and a
# trailing command replaces the engine exec and records the env it inherited.
# Usage: bash distro/test/docker-entrypoint-provision.sh   (needs bash, jq, node)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
EP="${ROOT}/distro/golden-image/docker-entrypoint.sh"

pass=0; fail=0
ok() { printf 'PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf 'FAIL  %s\n' "$1"; fail=$((fail+1)); }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else no "$d"; fi; }

for t in jq node; do command -v "$t" >/dev/null 2>&1 || { echo "SKIP: $t not installed"; exit 0; }; done
[[ -f "$EP" ]] || { echo "FAIL: entrypoint missing at $EP"; exit 1; }

WORK="$(mktemp -d)"
cleanup() {
  for p in "$WORK"/*/out/ts.pid; do [[ -f "$p" ]] && kill "$(cat "$p")" 2>/dev/null; done
  rm -rf "$WORK"
}
trap cleanup EXIT

SECRET='sek-test-0123456789abcdef'
FAKEBIN="${WORK}/fakebin"; mkdir -p "$FAKEBIN"

# fake curl: the enroll POST returns $FAKE_ENROLL_CODE + $FAKE_ENROLL_JSON into the -o
# file; every other URL (e.g. the caido download) returns 000 so self-heals fail open.
cat > "${FAKEBIN}/curl" <<'EOF'
#!/bin/bash
out=""; url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w|-H|-d|-X|-m|--connect-timeout|--max-time) shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
echo "$url" >> "${FAKE_OUT}/curl.log"
if [[ "$url" == */api/pentest/enroll ]]; then
  [[ -n "$out" ]] && printf '%s' "${FAKE_ENROLL_JSON}" > "$out"
  printf '%s' "${FAKE_ENROLL_CODE:-200}"
  exit 0
fi
printf '000'
exit 0
EOF
# fake tailscaled: records argv; FAKE_TS_KERNEL_FAIL=1 makes kernel mode exit at once.
cat > "${FAKEBIN}/tailscaled" <<'EOF'
#!/bin/bash
echo "$*" >> "${FAKE_OUT}/tailscaled.args"
if [[ "${FAKE_TS_KERNEL_FAIL:-0}" == "1" && "$*" != *--tun=userspace-networking* ]]; then exit 1; fi
echo $$ > "${FAKE_OUT}/ts.pid"
exec sleep 60
EOF
# fake tailscale CLI: records any invocation (the entrypoint must never call it).
cat > "${FAKEBIN}/tailscale" <<'EOF'
#!/bin/bash
echo "$*" >> "${FAKE_OUT}/tailscale.args"
exit 0
EOF
# fake pgrep: "nothing running" so the host's own tailscaled cannot leak in.
printf '#!/bin/bash\nexit 1\n' > "${FAKEBIN}/pgrep"
chmod +x "${FAKEBIN}"/*

# sandbox PATH: symlinks to the host tools the entrypoint uses (jq optional).
mk_sandbox() { # dir with_jq(1|0) with_tailscale(1|0)
  local d="$1" t
  mkdir -p "$d"
  for t in bash sh cat rm install chmod sed mkdir id getent cut uname mktemp tar awk \
           sha256sum sleep grep head dirname readlink date env hostname node timeout; do
    command -v "$t" >/dev/null 2>&1 && ln -sf "$(command -v "$t")" "${d}/${t}"
  done
  [[ "$2" == "1" ]] && ln -sf "$(command -v jq)" "${d}/jq"
  ln -sf "${FAKEBIN}/curl" "${d}/curl"; ln -sf "${FAKEBIN}/pgrep" "${d}/pgrep"
  if [[ "$3" == "1" ]]; then
    ln -sf "${FAKEBIN}/tailscaled" "${d}/tailscaled"; ln -sf "${FAKEBIN}/tailscale" "${d}/tailscale"
  fi
}

# run_case NAME with_jq with_ts with_caido [VAR=val ...] -> sets C (case dir), RC
run_case() {
  local name="$1" wj="$2" wt="$3" wc="$4"; shift 4
  C="${WORK}/${name}"
  mkdir -p "${C}/out" "${C}/state" "${C}/app/dist/runner" "${C}/home"
  : > "${C}/app/dist/runner/cli.js"
  if [[ "$wc" == "1" ]]; then
    mkdir -p "${C}/home/caido"; printf '#!/bin/sh\n' > "${C}/home/caido/caido-cli"; chmod +x "${C}/home/caido/caido-cli"
  fi
  mk_sandbox "${C}/bin" "$wj" "$wt"
  local bash_abs; bash_abs="$(command -v bash)"
  env -i PATH="${C}/bin" HOME="${C}/home" LANG=C VACTI_LANG=en \
    APP="${C}/app" ENGINE_STATE_DIR="${C}/state" ENGINE_ID=engine-test \
    FAKE_OUT="${C}/out" FAKE_ENROLL_JSON="${FAKE_ENROLL_JSON:-}" "$@" \
    timeout 60 "$bash_abs" "$EP" "$bash_abs" -c \
      'printf "%s" "${VACTI_ENGINE_SHARED_SECRET:-}" > "$FAKE_OUT/exported-secret"; printf "%s" "${VACTI_TOKEN:-}" > "$FAKE_OUT/exported-token"; : > "$FAKE_OUT/engine-ran"' \
    > "${C}/out/log" 2>&1
  RC=$?
  [[ -f "${C}/out/ts.pid" ]] && kill "$(cat "${C}/out/ts.pid")" 2>/dev/null
  return 0
}

envfile_has() { grep -qx "$2" "$1" 2>/dev/null; }
mode_is_600() { [[ "$(stat -c '%a' "$1" 2>/dev/null)" == "600" ]]; }
log_has() { grep -qF -- "$2" "$1/out/log"; }
not_in_log() { ! grep -qF -- "$2" "$1/out/log"; }
file_eq() { [[ "$(cat "$1" 2>/dev/null)" == "$2" ]]; }

WITH_SECRET="{\"producer_token\":\"tok-prod\",\"verifier_token\":\"tok-ver\",\"gatekeeper_token\":\"tok-gate\",\"engineSharedSecret\":\"${SECRET}\"}"
NO_SECRET='{"producer_token":"tok-prod","verifier_token":"tok-ver","gatekeeper_token":"tok-gate"}'

echo "== 1. enroll (jq path): secret persisted + exported, tailscaled up, caido present =="
FAKE_ENROLL_JSON="$WITH_SECRET" run_case jq 1 1 1 VACTI_URL=https://cp.invalid VACTI_ENROLL_TOKEN=vct_enrolltoken_full_length_value
check "exit 0" test "$RC" -eq 0
check "engine.env has VACTI_TOKEN" envfile_has "${C}/state/engine.env" 'VACTI_TOKEN=tok-prod'
check "engine.env has VACTI_ENGINE_SHARED_SECRET" envfile_has "${C}/state/engine.env" "VACTI_ENGINE_SHARED_SECRET=${SECRET}"
check "engine.env mode 0600" mode_is_600 "${C}/state/engine.env"
check "secret exported into the engine env" file_eq "${C}/out/exported-secret" "$SECRET"
check "producer token exported into the engine env" file_eq "${C}/out/exported-token" "tok-prod"
check "secret value never logged" not_in_log "$C" "$SECRET"
check "tailscaled launched with state on the volume" grep -qF -- "--state=${C}/state/tailscale/tailscaled.state" "${C}/out/tailscaled.args"
check "tailscaled reported started" log_has "$C" "tailscaled=started-"
check "entrypoint never ran the tailscale CLI (engine joins)" test ! -e "${C}/out/tailscale.args"
check "breadcrumb: secret enabled + caido-cli present" log_has "$C" "engine-shared-secret=enabled tailscaled=started-"
check "breadcrumb: caido-cli=present" log_has "$C" "caido-cli=present"
check "no boot-time Caido login artifact" test ! -e "${C}/home/.caido-mcp/token.json"
check "engine exec reached" test -e "${C}/out/engine-ran"

echo "== 2. enroll (node fallback, no jq): same engine.env contract =="
FAKE_ENROLL_JSON="$WITH_SECRET" run_case node 0 1 1 VACTI_URL=https://cp.invalid VACTI_ENROLL_TOKEN=vct_enrolltoken_full_length_value
check "exit 0" test "$RC" -eq 0
check "engine.env has VACTI_TOKEN (node)" envfile_has "${C}/state/engine.env" 'VACTI_TOKEN=tok-prod'
check "engine.env has VACTI_ENGINE_SHARED_SECRET (node)" envfile_has "${C}/state/engine.env" "VACTI_ENGINE_SHARED_SECRET=${SECRET}"
check "secret exported (node)" file_eq "${C}/out/exported-secret" "$SECRET"

echo "== 3. CP omits the secret: pre-fix engine.env + loud breadcrumb =="
FAKE_ENROLL_JSON="$NO_SECRET" run_case nosecret 1 1 1 VACTI_URL=https://cp.invalid VACTI_ENROLL_TOKEN=vct_enrolltoken_full_length_value
check "exit 0" test "$RC" -eq 0
check "no VACTI_ENGINE_SHARED_SECRET line" bash -c "! grep -q '^VACTI_ENGINE_SHARED_SECRET' '${C}/state/engine.env'"
check "engine.env is exactly the pre-fix 4 lines" bash -c "[[ \"\$(cat '${C}/state/engine.env')\" == \$'VACTI_URL=https://cp.invalid\nVACTI_TOKEN=tok-prod\nVACTI_VERIFIER_TOKEN=tok-ver\nVACTI_GATEKEEPER_TOKEN=tok-gate' ]]"
check "breadcrumb says secret unset" log_has "$C" "engine-shared-secret=unset"
check "remediation warning logged" log_has "$C" "WARNING no engine-shared-secret"

echo "== 4. restart on the same state volume reuses the persisted secret =="
FAKE_ENROLL_JSON="$WITH_SECRET" run_case restart 1 1 1 VACTI_URL=https://cp.invalid VACTI_ENROLL_TOKEN=vct_enrolltoken_full_length_value
rm -f "${C}/out/exported-secret" "${C}/out/curl.log"
FIRST="${C}"
env -i PATH="${FIRST}/bin" HOME="${FIRST}/home" LANG=C VACTI_LANG=en APP="${FIRST}/app" \
  ENGINE_STATE_DIR="${FIRST}/state" ENGINE_ID=engine-test FAKE_OUT="${FIRST}/out" VACTI_URL=https://cp.invalid \
  timeout 60 "$(command -v bash)" "$EP" "$(command -v bash)" -c 'printf "%s" "${VACTI_ENGINE_SHARED_SECRET:-}" > "$FAKE_OUT/exported-secret"' \
  > "${FIRST}/out/log2" 2>&1
RC=$?; [[ -f "${FIRST}/out/ts.pid" ]] && kill "$(cat "${FIRST}/out/ts.pid")" 2>/dev/null
check "restart exit 0" test "$RC" -eq 0
check "restart did not re-enroll" bash -c "! grep -q enroll '${FIRST}/out/curl.log' 2>/dev/null"
check "restart exports the persisted secret" file_eq "${FIRST}/out/exported-secret" "$SECRET"

echo "== 5. kernel TUN mode fails -> userspace fallback =="
FAKE_ENROLL_JSON="$WITH_SECRET" run_case fallback 1 1 1 VACTI_URL=https://cp.invalid VACTI_ENROLL_TOKEN=vct_enrolltoken_full_length_value FAKE_TS_KERNEL_FAIL=1
check "exit 0" test "$RC" -eq 0
check "tailscaled started in userspace mode" log_has "$C" "tailscaled=started-userspace"
check "userspace flag passed" grep -qF -- "--tun=userspace-networking" "${C}/out/tailscaled.args"

echo "== 6. VACTI_TAILSCALED=0 opt-out =="
FAKE_ENROLL_JSON="$WITH_SECRET" run_case optout 1 1 1 VACTI_URL=https://cp.invalid VACTI_ENROLL_TOKEN=vct_enrolltoken_full_length_value VACTI_TAILSCALED=0
check "exit 0" test "$RC" -eq 0
check "tailscaled not launched" test ! -e "${C}/out/tailscaled.args"
check "breadcrumb tailscaled=disabled" log_has "$C" "tailscaled=disabled"

echo "== 7. no tailscale in the image + no caido-cli: fail-open, engine still starts =="
FAKE_ENROLL_JSON="$WITH_SECRET" run_case absent 1 0 0 VACTI_URL=https://cp.invalid VACTI_ENROLL_TOKEN=vct_enrolltoken_full_length_value
check "exit 0" test "$RC" -eq 0
check "breadcrumb tailscaled=absent caido-cli=absent" log_has "$C" "tailscaled=absent caido-cli=absent"
check "engine exec reached" test -e "${C}/out/engine-ran"

echo "== 8. enroll rejected stays FATAL (engine never starts) =="
FAKE_ENROLL_JSON='{"error":"expired"}' run_case fatal 1 1 1 VACTI_URL=https://cp.invalid VACTI_ENROLL_TOKEN=vct_enrolltoken_full_length_value FAKE_ENROLL_CODE=401
check "non-zero exit" test "$RC" -ne 0
check "engine exec NOT reached" test ! -e "${C}/out/engine-ran"
check "no engine.env written" test ! -e "${C}/state/engine.env"
check "tailscaled not started before a failed enroll" test ! -e "${C}/out/tailscaled.args"

echo
echo "RESULT: ${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]
