#!/usr/bin/env bash
# slice-cap-contract.sh - static + behavioural contract test for the OVA's
# firstboot slice-cap reconcile (distro/enroll/firstboot/vacti-slice-cap[.service])
# AND the docker-entrypoint's documented systemd-less path.
#
# Why this exists: the engine .deb postinst writes
# /etc/systemd/{user,system}/vacti.slice.d/10-memmax.conf from the then-current
# /proc/meminfo MemTotal. On a FAT-OVA that postinst runs inside the
# virt-customize chroot (BUILD host's MemTotal, not the guest's), so the baked
# drop-in is wrong for the shipped guest. The firstboot reconcile corrects it
# against the LIVE /proc/meminfo before vacti-engine starts. This test asserts:
#   (a) the reconcile unit + script are present, ordered Before=vacti-engine,
#       gated to non-container environments, and wired into build-golden.sh /
#       build-iso.sh for both OVA and ISO paths.
#   (b) running the script against a fake /proc/meminfo produces a drop-in whose
#       body matches the postinst formula exactly for several box sizes
#       (10GB vacti-arp observed; 8GB predominant fleet; 4GB small).
#   (c) the docker-entrypoint documents the systemd-less path so a regression
#       can't silently delete the context (engine readSliceMemory=null + the
#       MemAvailable fallback is the container contract).
#
# Static + offline; no systemd, no network, safe in ci/lint.sh.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
ENR="${ROOT}/distro/enroll"
SLICECAP_SH="${ENR}/firstboot/vacti-slice-cap"
SLICECAP_UNIT="${ENR}/firstboot/vacti-slice-cap.service"
BUILD_GOLDEN="${ROOT}/distro/golden-image/build-golden.sh"
BUILD_ISO="${ROOT}/distro/live-build-config/build-iso.sh"
DOCKER_ENTRY="${ROOT}/distro/golden-image/docker-entrypoint.sh"
POSTINST_SOURCE="packaging/maintainer/postinst"

pass=0; fail=0
ok()   { printf 'PASS  %s\n' "$1"; pass=$((pass+1)); }
no()   { printf 'FAIL  %s\n' "$1"; fail=$((fail+1)); }
check(){ # description  test-command...
  local desc="$1"; shift
  if "$@"; then ok "$desc"; else no "$desc"; fi
}
has() { grep -Eq "$2" "$1" 2>/dev/null; }

echo "== files present =="
for f in "$SLICECAP_SH" "$SLICECAP_UNIT" "$BUILD_GOLDEN" "$BUILD_ISO" "$DOCKER_ENTRY"; do
  check "exists: ${f#"$ROOT"/}" test -f "$f"
done

echo "== unit ordering + condition + install =="
check "vacti-slice-cap.service Before=vacti-engine.service" \
  has "$SLICECAP_UNIT" '^Before=vacti-engine\.service$'
check "vacti-slice-cap.service After=local-fs.target" \
  has "$SLICECAP_UNIT" '^After=local-fs\.target$'
check "vacti-slice-cap.service ConditionVirtualization=!container (docker skip)" \
  has "$SLICECAP_UNIT" '^ConditionVirtualization=!container$'
check "vacti-slice-cap.service Type=oneshot" \
  has "$SLICECAP_UNIT" '^Type=oneshot$'
check "vacti-slice-cap.service WantedBy=multi-user.target" \
  has "$SLICECAP_UNIT" '^WantedBy=multi-user\.target$'
check "vacti-slice-cap.service ExecStart=/usr/local/sbin/vacti-slice-cap" \
  has "$SLICECAP_UNIT" '^ExecStart=/usr/local/sbin/vacti-slice-cap$'

echo "== build-golden.sh stages + enables the unit =="
check "build-golden.sh copies the script into /usr/local/sbin" \
  has "$BUILD_GOLDEN" 'firstboot/vacti-slice-cap"[[:space:]]+"\$\{STAGE\}/usr/local/sbin/vacti-slice-cap"'
check "build-golden.sh copies the unit into /etc/systemd/system" \
  has "$BUILD_GOLDEN" 'firstboot/vacti-slice-cap\.service"[[:space:]]+"\$\{STAGE\}/etc/systemd/system/vacti-slice-cap\.service"'
check "build-golden.sh chmod 0755 includes the script" \
  has "$BUILD_GOLDEN" 'usr/local/sbin/vacti-slice-cap"'
check "build-golden.sh enables the unit (systemctl enable)" \
  has "$BUILD_GOLDEN" '^systemctl enable vacti-slice-cap\.service'

echo "== build-iso.sh stages + wants-wires the unit =="
check "build-iso.sh install -D the script" \
  has "$BUILD_ISO" 'firstboot/vacti-slice-cap"'
check "build-iso.sh install -D the unit" \
  has "$BUILD_ISO" 'firstboot/vacti-slice-cap\.service"'
check "build-iso.sh wires the multi-user.target.wants symlink" \
  has "$BUILD_ISO" 'multi-user\.target\.wants/vacti-slice-cap\.service'

echo "== docker-entrypoint documents the systemd-less slice-cap path =="
check "docker-entrypoint.sh carries a SLICE-CAP NOTE comment block" \
  has "$DOCKER_ENTRY" '^# SLICE-CAP NOTE'
check "docker-entrypoint.sh names the null-slice fail-open contract" \
  has "$DOCKER_ENTRY" 'readSliceMemory|null-slice|MemAvailable'

echo "== script body matches the postinst formula =="
# Make sure shellcheck -S warning will not refuse the script.
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -S warning "$SLICECAP_SH" >/dev/null 2>&1; then
    ok "shellcheck -S warning clean on vacti-slice-cap"
  else
    shellcheck -S warning "$SLICECAP_SH" >&2 || true
    no "shellcheck -S warning clean on vacti-slice-cap"
  fi
else
  echo "  shellcheck not installed; skipping (CI covers it)"
fi

# Behavioural: mock /proc/meminfo, run the script into a sandbox, assert the
# drop-in body matches the postinst formula literally.
TMP="$(mktemp -d 2>/dev/null)"
if [ -z "$TMP" ] || [ ! -d "$TMP" ]; then
  echo "  mktemp failed; skipping behavioural subtest" >&2
else
  trap 'rm -rf "$TMP"' EXIT
  USER_DROPIN="$TMP/etc/systemd/user/vacti.slice.d/10-memmax.conf"
  SYS_DROPIN="$TMP/etc/systemd/system/vacti.slice.d/10-memmax.conf"

  # Case 1: vacti-arp observed (MemTotal=10189312kB). The postinst and this script
  # both use bash integer division: 10189312/1024=9950, so SLICE_MAX_MB=8150 and
  # SLICE_HIGH_MB=8150*95/100=7742. (The engine's TS reconcile uses Math.round
  # which yields 9951->8151 for the same input; a 1MB spread stays well within
  # the 15% drift tolerance so the engine's rewrite is a no-op on the normal
  # path - the two writers agree on the FORMULA, differ only on sub-MB rounding.)
  cat > "$TMP/meminfo.10gb" <<'EOF'
MemTotal:       10189312 kB
MemFree:          500000 kB
EOF
  rm -rf "${TMP:?}/etc"
  VACTI_SLICE_CAP_ROOT="$TMP" VACTI_SLICE_CAP_MEMINFO="$TMP/meminfo.10gb" VACTI_SLICE_CAP_NO_RELOAD=1 \
    bash "$SLICECAP_SH" >/dev/null 2>&1 || true
  if [ -f "$USER_DROPIN" ] && [ -f "$SYS_DROPIN" ]; then
    ok "10GB box: both drop-ins written"
  else
    no "10GB box: both drop-ins written"
  fi
  want_10="$(printf '[Slice]\nMemoryMax=8150M\nMemoryHigh=7742M\n')"
  got_u="$(cat "$USER_DROPIN" 2>/dev/null || true)"
  got_s="$(cat "$SYS_DROPIN"  2>/dev/null || true)"
  if [ "$got_u" = "$want_10" ]; then ok "10GB box: user drop-in body matches postinst (8150M/7742M)"
  else no "10GB box: user drop-in body matches postinst (got: $got_u)"; fi
  if [ "$got_s" = "$want_10" ]; then ok "10GB box: system drop-in body matches postinst (8150M/7742M)"
  else no "10GB box: system drop-in body matches postinst (got: $got_s)"; fi

  # Case 2: predominant 8GB fleet box (MemTotal=8132608kB). Exact division:
  # 8132608/1024=7942 -> cap=6142M -> high=6142*95/100=5834M (postinst+this agree).
  cat > "$TMP/meminfo.8gb" <<'EOF'
MemTotal:        8132608 kB
MemFree:          500000 kB
EOF
  rm -rf "${TMP:?}/etc"
  VACTI_SLICE_CAP_ROOT="$TMP" VACTI_SLICE_CAP_MEMINFO="$TMP/meminfo.8gb" VACTI_SLICE_CAP_NO_RELOAD=1 \
    bash "$SLICECAP_SH" >/dev/null 2>&1 || true
  want_8="$(printf '[Slice]\nMemoryMax=6142M\nMemoryHigh=5834M\n')"
  got_u="$(cat "$USER_DROPIN" 2>/dev/null || true)"
  if [ "$got_u" = "$want_8" ]; then ok "8GB fleet box: user drop-in body matches postinst (6142M/5834M)"
  else no "8GB fleet box: user drop-in body matches postinst (got: $got_u)"; fi

  # Case 3: 4GB small box (MemTotal=3900000kB -> 3808MB -> would cap at 2008, but
  # the 2048M floor kicks in -> cap=2048M -> high=2048*95/100=1945M).
  cat > "$TMP/meminfo.4gb" <<'EOF'
MemTotal:        3900000 kB
MemFree:          500000 kB
EOF
  rm -rf "${TMP:?}/etc"
  VACTI_SLICE_CAP_ROOT="$TMP" VACTI_SLICE_CAP_MEMINFO="$TMP/meminfo.4gb" VACTI_SLICE_CAP_NO_RELOAD=1 \
    bash "$SLICECAP_SH" >/dev/null 2>&1 || true
  want_4="$(printf '[Slice]\nMemoryMax=2048M\nMemoryHigh=1945M\n')"
  got_u="$(cat "$USER_DROPIN" 2>/dev/null || true)"
  if [ "$got_u" = "$want_4" ]; then ok "4GB small box: floor 2048M applied, body matches postinst"
  else no "4GB small box: floor 2048M applied (got: $got_u)"; fi

  # Case 4: VACTI_SLICE_RESERVE_MB operator override (10GB box, reserve=2500):
  # 9950-2500=7450 -> high=7450*95/100=7077M (postinst+this agree).
  rm -rf "${TMP:?}/etc"
  VACTI_SLICE_RESERVE_MB=2500 VACTI_SLICE_CAP_ROOT="$TMP" VACTI_SLICE_CAP_MEMINFO="$TMP/meminfo.10gb" \
    VACTI_SLICE_CAP_NO_RELOAD=1 bash "$SLICECAP_SH" >/dev/null 2>&1 || true
  want_or="$(printf '[Slice]\nMemoryMax=7450M\nMemoryHigh=7077M\n')"
  got_u="$(cat "$USER_DROPIN" 2>/dev/null || true)"
  if [ "$got_u" = "$want_or" ]; then ok "operator reserve override honoured (2500MB -> cap 7450M)"
  else no "operator reserve override honoured (got: $got_u)"; fi

  # Case 5: FAIL-OPEN - unreadable /proc/meminfo -> no drop-in, exit 0.
  rm -rf "${TMP:?}/etc"
  if VACTI_SLICE_CAP_ROOT="$TMP" VACTI_SLICE_CAP_MEMINFO="$TMP/does-not-exist" VACTI_SLICE_CAP_NO_RELOAD=1 \
    bash "$SLICECAP_SH" >/dev/null 2>&1; then
    ok "unreadable /proc/meminfo: script exits 0 (fail-open)"
  else
    no "unreadable /proc/meminfo: script exits 0 (fail-open)"
  fi
  if [ ! -f "$USER_DROPIN" ] && [ ! -f "$SYS_DROPIN" ]; then
    ok "unreadable /proc/meminfo: no drop-ins written (no guess)"
  else
    no "unreadable /proc/meminfo: no drop-ins written (no guess)"
  fi

  # Case 6: idempotent re-run against a current drop-in -> no rewrite.
  rm -rf "${TMP:?}/etc"
  VACTI_SLICE_CAP_ROOT="$TMP" VACTI_SLICE_CAP_MEMINFO="$TMP/meminfo.10gb" VACTI_SLICE_CAP_NO_RELOAD=1 \
    bash "$SLICECAP_SH" >/dev/null 2>&1 || true
  mt1="$(stat -c '%Y' "$USER_DROPIN" 2>/dev/null || echo 0)"
  sleep 1
  VACTI_SLICE_CAP_ROOT="$TMP" VACTI_SLICE_CAP_MEMINFO="$TMP/meminfo.10gb" VACTI_SLICE_CAP_NO_RELOAD=1 \
    bash "$SLICECAP_SH" >/dev/null 2>&1 || true
  mt2="$(stat -c '%Y' "$USER_DROPIN" 2>/dev/null || echo 0)"
  if [ "$mt1" = "$mt2" ] && [ "$mt1" != "0" ]; then
    ok "idempotent: a re-run against a matching drop-in does not rewrite the file"
  else
    no "idempotent: a re-run against a matching drop-in does not rewrite the file (mt1=$mt1 mt2=$mt2)"
  fi
fi

echo "== postinst formula cross-reference (if engine source is present) =="
# Belt-and-braces: when the engine repo is co-located, confirm the formula
# literals the script uses match the postinst's. Soft-skip when the engine repo
# is not on disk (CI boxes may only check out one repo at a time).
ENGINE_POSTINST=""
for candidate in \
  "${VACTI_ENGINE_REPO:-}/${POSTINST_SOURCE}" \
  "$(dirname "$ROOT")/vacti-pentest-engine/${POSTINST_SOURCE}" \
  "${HOME:-/root}/vacti-pentest-engine/${POSTINST_SOURCE}"; do
  if [ -n "$candidate" ] && [ -f "$candidate" ]; then
    ENGINE_POSTINST="$candidate"
    break
  fi
done
if [ -n "$ENGINE_POSTINST" ]; then
  check "postinst uses SLICE_RESERVE_MB=1800 default" \
    has "$ENGINE_POSTINST" '"\$\{VACTI_SLICE_RESERVE_MB:-1800\}"'
  check "postinst floors SLICE_MAX_MB at 2048" \
    has "$ENGINE_POSTINST" 'SLICE_MAX_MB=2048'
  check "postinst SLICE_HIGH_MB uses 95 percent" \
    has "$ENGINE_POSTINST" 'SLICE_MAX_MB \* 95 / 100'
  check "postinst writes both /etc/systemd/user + /etc/systemd/system drop-ins" \
    has "$ENGINE_POSTINST" '/etc/systemd/user /etc/systemd/system'
else
  echo "  engine postinst not reachable (set VACTI_ENGINE_REPO to point at it); skipping cross-reference"
fi

echo
echo "== slice-cap-contract summary: pass=${pass} fail=${fail} =="
[ "$fail" -eq 0 ] || exit 1
exit 0
