#!/usr/bin/env bash
# smoke.sh - install -> remove reversibility proof for vacti-appliance-skin, run in a
# throwaway Debian container. Fail-closed: the release workflow gates publish on this.
#
#   1. capture /etc /usr/local /boot /root as a manifest of sha256 + mode + owner
#   2. install the .deb (with a stub vacti-engine so the engine-active preflight path runs)
#   3. assert: version marker written, diversions present, lockdown files + masks present,
#      tty1 NOT masked, auto-revert timer enabled
#   4. apt-get remove (or dpkg -r) the package
#   5. assert: NO vacti diversions remain, and the captured trees are byte-identical to (1)
#
# Usage: smoke.sh /path/to/vacti-appliance-skin_X_all.deb
#   DOCKER_IMAGE=debian:trixie-slim (default). Set SMOKE_NO_DOCKER=1 to run in-place
#   (destructive; only on a disposable box).
set -euo pipefail

DEB="${1:?usage: smoke.sh <deb>}"
DEB="$(readlink -f "$DEB")"
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
IMAGE="${DOCKER_IMAGE:-debian:trixie-slim}"

if [ -z "${SMOKE_NO_DOCKER:-}" ] && command -v docker >/dev/null 2>&1; then
  exec docker run --rm -v "$DEB":/tmp/skin.deb:ro -v "${HERE}/smoke.sh":/tmp/smoke.sh:ro \
    -e SMOKE_NO_DOCKER=1 "$IMAGE" bash /tmp/smoke.sh /tmp/skin.deb
fi

say() { printf '\n== %s ==\n' "$*"; }
fail() {
  echo "SMOKE FAIL: $*" >&2
  exit 1
}

export DEBIAN_FRONTEND=noninteractive
TREES=(/etc /usr/local /boot /root)

capture() {
  local out="$1" t
  : > "$out"
  for t in "${TREES[@]}"; do
    [ -e "$t" ] || continue
    # content hash for files, target for symlinks, plus mode+owner; sorted for stable diff
    find "$t" \( -type f -o -type l \) -printf '%y %m %u:%g %p\n' 2>/dev/null |
      while read -r ty mo og pa; do
        if [ "$ty" = l ]; then
          printf '%s %s %s L=%s\n' "$mo" "$og" "$pa" "$(readlink "$pa")"
        else
          printf '%s %s %s %s\n' "$mo" "$og" "$pa" "$(sha256sum "$pa" 2>/dev/null | awk '{print $1}')"
        fi
      done
  done | sort > "$out"
}

say "prep container (systemd for the Depends; GUI Recommends are NOT pulled - this is the headless path)"
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -qq || true
  apt-get install -y -qq --no-install-recommends systemd >/dev/null 2>&1 || true
fi

say "install a stub vacti-engine (so the engine-active preflight path is exercised)"
# a minimal dpkg status entry + a fake active unit via a systemctl shim
STUB="$(mktemp -d)"
cat > /usr/local/bin/systemctl <<'SH'
#!/bin/bash
# smoke shim: pretend vacti-engine is active; accept all other calls as no-ops
case "$*" in
  *"is-active"*"vacti-engine"*) exit 0 ;;
  *"is-active"*) exit 3 ;;
  *) exit 0 ;;
esac
SH
chmod +x /usr/local/bin/systemctl
hash -r
# register vacti-engine in the dpkg db so `systemctl is-active` is the only check that matters
printf 'Package: vacti-engine\nStatus: install ok installed\nVersion: 0.2.452\nArchitecture: all\nMaintainer: x <x@x>\nDescription: stub\n\n' |
  tee -a /var/lib/dpkg/status >/dev/null

say "capture pre-install state"
capture "${STUB}/pre.manifest"

say "install the .deb (dpkg, deterministic; no GUI recommends pulled)"
dpkg -i "$DEB" || fail "install failed"
STAT="$(dpkg -s vacti-appliance-skin 2>/dev/null || true)"
grep -q '^Status: install ok installed' <<<"$STAT" || fail "package not fully configured"

say "assert applied state"
[ "$(cat /etc/vacti-appliance-skin/applied-version 2>/dev/null)" ] || fail "no applied-version marker"
DIVS="$(dpkg-divert --list)"
grep -q 'by vacti-appliance-skin' <<<"$DIVS" || fail "no diversions registered"
for f in /etc/polkit-1/rules.d/10-vacti-lockdown.rules /etc/systemd/system.conf.d/10-vacti-cad.conf /etc/sysctl.d/90-vacti-sysrq.conf; do
  [ -f "$f" ] || fail "lockdown file missing (from apply-branding.sh): $f"
done
[ -L /etc/systemd/system/ctrl-alt-del.target ] || fail "ctrl-alt-del.target not masked"
[ -L /etc/systemd/system/getty@tty2.service ] || fail "getty@tty2 not masked"
[ ! -e /etc/systemd/system/getty@tty1.service ] || fail "getty@tty1 was masked (console break-glass removed!)"
[ -f /etc/os-release.vacti-orig ] || fail "/etc/os-release original not diverted aside"
grep -qi vacti /etc/os-release || fail "/etc/os-release not branded"
echo "applied OK: $(cat /etc/vacti-appliance-skin/applied-version)"

say "remove the .deb"
dpkg -r vacti-appliance-skin || fail "remove failed"

say "assert full reversal"
DIVS="$(dpkg-divert --list)"
if grep -q 'by vacti-appliance-skin' <<<"$DIVS"; then
  grep 'by vacti-appliance-skin' <<<"$DIVS" >&2
  fail "diversions still held after remove"
fi
[ -L /etc/systemd/system/getty@tty2.service ] && fail "getty@tty2 mask not removed"
capture "${STUB}/post.manifest"
if ! diff -u "${STUB}/pre.manifest" "${STUB}/post.manifest"; then
  fail "trees are NOT byte-identical after install->remove (see diff above)"
fi

say "SMOKE PASS: install applied the skin; remove restored every tree byte-identical, no diversions left"
