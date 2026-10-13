#!/usr/bin/env bash
# no-secret-scan.sh - the MANDATORY, NON-NEGOTIABLE gate. Given any emitted
# artifact (qcow2 / raw[.gz] / ova / iso), mount or extract its rootfs and FAIL
# (exit 1) if ANY baked credential, token, key, or methodology is present. This
# is what keeps every shared image secretless and inert-without-vacti.
#
# Runs in CI on every artifact; build-golden.sh also calls it on the golden disk.
# Needs libguestfs (guestmount) for disk images, plus unsquashfs/bsdtar for ISOs.
# Open-source tools only. Scans READ-ONLY.
#
# Usage: no-secret-scan.sh <artifact> [<artifact> ...]
set -euo pipefail

FAIL=0
TMPROOT="$(mktemp -d)"
cleanup() {
  # unmount anything we guestmounted, then remove temp
  for m in "${TMPROOT}"/mnt.*; do
    [[ -d "$m" ]] && { fusermount -u "$m" 2>/dev/null || guestunmount "$m" 2>/dev/null || umount "$m" 2>/dev/null || true; }
  done
  rm -rf "$TMPROOT"
}
trap cleanup EXIT

# Forbidden PATHS (must not exist in a shipped rootfs).
FORBIDDEN_PATHS=(
  "etc/apt/auth.conf.d/vacti-engine.conf"   # build-time private-repo credential
  "etc/vacti-engine/engine.env"             # scoped engine tokens
  "etc/vacti-engine/enroll.token"           # a baked enroll token
  "var/lib/tailscale/tailscaled.state"      # a tailscale node key
  "root/.claude" "etc/vacti-engine/.claude" # methodology IP
)
# Forbidden CONTENT patterns (grepped across the rootfs, excluding huge binaries).
# High-signal secret shapes only, to avoid false positives on docs/examples.
FORBIDDEN_PATTERNS='(VACTI_PRODUCER_TOKEN=.|VACTI_VERIFIER_TOKEN=.|VACTI_GATEKEEPER_TOKEN=.|EVIDENCE_KEY=.|tskey-auth-[A-Za-z0-9]|password [A-Za-z0-9]{12,}|BEGIN (RSA|OPENSSH|EC) PRIVATE KEY)'

say()  { echo "[no-secret-scan] $*"; }
bad()  { echo "[no-secret-scan][FAIL] $*" >&2; FAIL=1; }

scan_rootfs() {
  local root="$1" label="$2"
  say "scanning rootfs of ${label} at ${root}"
  # 1. forbidden paths
  local p
  for p in "${FORBIDDEN_PATHS[@]}"; do
    if compgen -G "${root}/${p}" >/dev/null 2>&1 || ls "${root}/${p}" >/dev/null 2>&1; then
      bad "${label}: forbidden path present: /${p}"
    fi
  done
  # any stray .claude anywhere under home/root/etc
  if find "${root}/root" "${root}/home" "${root}/etc" -maxdepth 4 -name '.claude' -print 2>/dev/null | grep -q .; then
    bad "${label}: a .claude directory is present (methodology must NOT ship on disk)"
  fi
  # 2. forbidden content - scan config-ish trees, skip big binaries/caches.
  # --exclude-dir=testssl: testssl.sh (an arsenal TLS scanner) ships its own EC
  # test keys under /etc/testssl/tls_data.txt; those "BEGIN EC PRIVATE KEY" test
  # vectors are tool data, not a baked vacti secret, so they must not trip the gate.
  # --exclude-dir='ghidra*' / 'jdk-*': the baked RE engine (Ghidra 12.1.4 under
  # /opt/ghidra_12.1.4_PUBLIC) and its FULL Temurin JDK (/opt/jdk-21.0.12.1+1) ship
  # large test/sample/man trees with dummy keys/passwords as tool DATA; both are
  # pinned by SHA256 at install, so exclude them from the pattern grep (same
  # rationale as testssl - not a baked vacti secret). Globs match the versioned dirs.
  if grep -rEIl --binary-files=without-match --exclude-dir=dpkg --exclude-dir=testssl --exclude-dir='ghidra*' --exclude-dir='jdk-*' "$FORBIDDEN_PATTERNS" \
        "${root}/etc" "${root}/root" "${root}/home" "${root}/var/lib" "${root}/opt" \
        2>/dev/null | grep -q .; then
    bad "${label}: a secret-shaped pattern was found in the rootfs:"
    grep -rEIl --binary-files=without-match --exclude-dir=dpkg --exclude-dir=testssl --exclude-dir='ghidra*' --exclude-dir='jdk-*' "$FORBIDDEN_PATTERNS" \
        "${root}/etc" "${root}/root" "${root}/home" "${root}/var/lib" "${root}/opt" 2>/dev/null \
        | sed 's/^/    /' >&2 || true
  fi
}

mount_disk() {
  # guestmount a disk image read-only and scan each inspected OS root.
  #
  # guestmount on GitHub-hosted runners is intermittently flaky (supermin
  # appliance build / libguestfs backend hiccups), so RETRY a bounded number of
  # times before giving up. This only suppresses TRANSIENT infrastructure
  # failures - the gate stays FAIL-CLOSED: if every attempt still cannot mount
  # the artifact, we call bad() and the build FAILS (an unscanned artifact is
  # never allowed to pass as "secretless"). A genuine mount failure is reported
  # with a distinct [infra] diagnostic so it is distinguishable in the logs from
  # an actual secret/credential being found - but both still block publish.
  local img="$1" label="$2" m attempt rc
  command -v guestmount >/dev/null 2>&1 || { bad "guestmount not available to scan ${label}"; return; }
  local tries="${GUESTMOUNT_RETRIES:-3}"
  for (( attempt=1; attempt<=tries; attempt++ )); do
    m="$(mktemp -d "${TMPROOT}/mnt.XXXX")"
    if LIBGUESTFS_BACKEND="${LIBGUESTFS_BACKEND:-direct}" guestmount --ro -a "$img" -i "$m" 2>/dev/null; then
      scan_rootfs "$m" "$label"
      guestunmount "$m" 2>/dev/null || fusermount -u "$m" 2>/dev/null || true
      return
    fi
    rc=$?
    rmdir "$m" 2>/dev/null || true
    if [[ "$attempt" -lt "$tries" ]]; then
      echo "[no-secret-scan][infra] guestmount attempt ${attempt}/${tries} failed (rc=${rc}) for ${label}; retrying..." >&2
      sleep $(( attempt * 5 ))
    fi
  done
  # Fail-closed: exhausted retries -> treat as a blocking failure (never a pass).
  bad "[infra] could not guestmount ${label} (${img}) after ${tries} attempts - artifact is UNSCANNED, refusing to pass (fail-closed)"
}

scan_artifact() {
  local art="$1" base; base="$(basename "$art")"
  [[ -e "$art" ]] || { bad "artifact not found: $art"; return; }
  case "$art" in
    *.qcow2|*.raw|*.img)
      mount_disk "$art" "$base" ;;
    *.raw.gz)
      local raw; raw="${TMPROOT}/$(basename "${art%.gz}")"
      gzip -dc "$art" > "$raw"; mount_disk "$raw" "$base"; rm -f "$raw" ;;
    *.ova)
      local d; d="$(mktemp -d "${TMPROOT}/ova.XXXX")"
      # tar -C: $art may be a RELATIVE path, which a `cd "$d"` would break.
      tar -C "$d" -xf "$art"
      local vmdk; vmdk="$(find "$d" -maxdepth 1 -name '*.vmdk' | head -1)"
      [[ -n "$vmdk" ]] || { bad "${base}: no VMDK inside OVA"; return; }
      local raw="${d}/disk.raw"
      qemu-img convert -O raw "$vmdk" "$raw"
      mount_disk "$raw" "${base} (vmdk)"
      rm -f "$raw" ;;
    *.iso)
      local d; d="$(mktemp -d "${TMPROOT}/iso.XXXX")"
      if command -v bsdtar >/dev/null 2>&1; then bsdtar -C "$d" -xf "$art";
      elif command -v xorriso >/dev/null 2>&1; then xorriso -osirrox on -indev "$art" -extract / "$d" 2>/dev/null;
      else bad "${base}: need bsdtar or xorriso to extract the ISO"; return; fi
      # scan the ISO tree itself (branding/boot), then the live squashfs rootfs
      scan_rootfs "$d" "${base} (iso tree)"
      local sq; sq="$(find "$d" -name 'filesystem.squashfs' | head -1)"
      if [[ -n "$sq" ]] && command -v unsquashfs >/dev/null 2>&1; then
        local sr="${d}/squashfs-root"; unsquashfs -d "$sr" "$sq" >/dev/null 2>&1 || true
        [[ -d "$sr" ]] && scan_rootfs "$sr" "${base} (squashfs rootfs)"
      elif [[ -n "$sq" ]]; then
        bad "${base}: unsquashfs not available to scan the live rootfs"
      fi ;;
    *)
      say "skipping unknown artifact type: $base" ;;
  esac
}

[[ $# -ge 1 ]] || { echo "usage: $0 <artifact> [...]" >&2; exit 2; }
for a in "$@"; do scan_artifact "$a"; done

if [[ "$FAIL" -ne 0 ]]; then
  echo "[no-secret-scan] RESULT: FAIL - a secret/credential/methodology was found. Build must NOT publish." >&2
  exit 1
fi
say "RESULT: PASS - no baked secret, token, key, or methodology found in any artifact."
