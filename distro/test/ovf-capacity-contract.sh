#!/usr/bin/env bash
# distro/test/ovf-capacity-contract.sh - EMPIRICAL regression test for the OVA
# descriptors (P0-1 capacity, P1-6 arm64 hardware). Builds a tiny SPARSE 100G qcow2
# (a few MB on disk, so the qcow2 FILE size is nowhere near the VIRTUAL size, exactly
# like the real 5.6GB-file/100GB-virtual golden), runs the REAL convert-vbox-ova.sh +
# convert-vmware-ova.sh for amd64 AND arm64, and asserts:
#   1. ci/validate-ovf.sh PASSES on all four OVAs (incl. the new capacity check 9 and
#      the arm64 hardware check 10);
#   2. every Disk/@ovf:capacity is the 100G virtual size (107374182400), not a file size;
#   3. arm64 VMware = SATA AHCI + firmware=efi + vmx-20, no lsilogic; amd64 VMware keeps
#      lsilogic + bios + vmx-13; VBox carries vbox:OSType Debian_arm64 / Debian_64;
#   4. NEGATIVE: an OVA whose capacity was rewritten to the qcow2 FILE size (the shipped
#      bug), with a re-computed .mf so only the capacity is wrong, FAILS validate-ovf.sh.
# Needs qemu-img + xmllint + python3 (CI installs them); LOUD SKIP when absent so
# `make lint` stays runnable anywhere. Offline; writes only to a temp dir.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GI="${ROOT}/distro/golden-image"
VALIDATE="${ROOT}/ci/validate-ovf.sh"

for t in qemu-img xmllint python3 tar sha256sum; do
  command -v "$t" >/dev/null 2>&1 || { echo "  !!! SKIP: ${t} not available - OVF capacity contract NOT executed !!!"; exit 0; }
done

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0
pass() { echo "  ok: $*"; }
bad()  { echo "  FAIL: $*" >&2; fail=1; }

VSIZE=107374182400
REL="0.2.999"

xp() { xmllint --xpath "$1" "$2" 2>/dev/null || true; }

for arch in amd64 arm64; do
  out="${T}/out-${arch}"; mkdir -p "$out"
  suffix=""; [[ "$arch" == "arm64" ]] && suffix="-arm64"
  golden="${out}/vacti-engine-${REL}${suffix}-gui-golden.qcow2"
  qemu-img create -q -f qcow2 "$golden" 100G
  # A little real data so populatedSize > 0 and the VMDK is not all-zero.
  qemu-io -f qcow2 -c "write -P 0x5a 0 4M" "$golden" >/dev/null 2>&1 || true
  fsize="$(stat -c%s "$golden")"
  for form in vbox vmware; do
    ( export DEBIAN_ARCH="$arch" VACTI_RELEASE="$REL" VACTI_FLAVOR=gui OUT_DIR="$out" GOLDEN="$golden"
      bash "${GI}/convert-${form}-ova.sh" >"${T}/conv-${arch}-${form}.log" 2>&1 ) \
      || { bad "convert-${form}-ova.sh (${arch}) failed: $(tail -3 "${T}/conv-${arch}-${form}.log")"; continue; }
  done
  shopt -s nullglob
  ovas=("${out}"/*.ova)
  shopt -u nullglob
  [[ "${#ovas[@]}" -eq 2 ]] || { bad "${arch}: expected 2 OVAs, got ${#ovas[@]}"; continue; }
  if bash "$VALIDATE" "${ovas[@]}" >"${T}/val-${arch}.log" 2>&1; then
    pass "${arch}: validate-ovf.sh PASS on both OVAs"
  else
    bad "${arch}: validate-ovf.sh FAILED: $(grep FAIL "${T}/val-${arch}.log" | head -5)"
  fi
  for ova in "${ovas[@]}"; do
    d="${T}/x-$(basename "$ova" .ova)"; mkdir -p "$d"; tar -C "$d" -xf "$ova"
    ovf="$(ls "$d"/*.ovf)"
    cap="$(xp "string(//*[local-name()='Disk']/@*[local-name()='capacity'])" "$ovf")"
    [[ "$cap" == "$VSIZE" ]] && pass "$(basename "$ova"): capacity ${cap} == 100G virtual (qcow2 file is ${fsize} bytes)" \
                             || bad "$(basename "$ova"): capacity '${cap}' != ${VSIZE} (qcow2 file ${fsize})"
    case "$(basename "$ova")" in
      *-vmware.ova)
        hw="$(xp "string(//*[local-name()='VirtualSystemType'])" "$ovf")"
        fw="$(xp "string(//*[local-name()='Config'][@*[local-name()='key']='firmware']/@*[local-name()='value'])" "$ovf")"
        sub="$(xp "string(//*[local-name()='Item'][*[local-name()='InstanceID']='3']/*[local-name()='ResourceSubType'])" "$ovf")"
        if [[ "$arch" == "arm64" ]]; then
          [[ "$hw" == "vmx-20" && "$fw" == "efi" && "$sub" == "vmware.sata.ahci" ]] \
            && pass "arm64 vmware: vmx-20 + efi + SATA AHCI" || bad "arm64 vmware: hw=${hw} fw=${fw} ctrl=${sub}"
          # grep -c (not -q): -q exits early, SIGPIPEs head, and pipefail turns a match into a failure.
          [[ "$(head -c 65536 "$d"/*.vmdk | grep -ac 'adapterType = "ide"')" -ge 1 ]] \
            && pass "arm64 vmware: VMDK adapterType ide (SATA)" || bad "arm64 vmware: VMDK adapterType is not ide"
        else
          [[ "$hw" == "vmx-13" && "$fw" == "bios" && "$sub" == "lsilogic" ]] \
            && pass "amd64 vmware: vmx-13 + bios + lsilogic (unchanged)" || bad "amd64 vmware: hw=${hw} fw=${fw} ctrl=${sub}"
        fi ;;
      *-virtualbox.ova)
        os="$(xp "string(//*[local-name()='OSType'])" "$ovf")"
        want="Debian_64"; [[ "$arch" == "arm64" ]] && want="Debian_arm64"
        [[ "$os" == "$want" ]] && pass "${arch} vbox: vbox:OSType ${os}" || bad "${arch} vbox: vbox:OSType '${os}' != ${want}"
        ;;
    esac
  done

  # --- NEGATIVE: the shipped bug (capacity = qcow2 FILE size) must fail the gate ---
  src="${ovas[0]}"; n="${T}/neg-${arch}"; mkdir -p "$n"; tar -C "$n" -xf "$src"
  ovf="$(cd "$n" && ls *.ovf)"; mf="$(cd "$n" && ls *.mf)"; vmdk="$(cd "$n" && ls *.vmdk)"
  sed -i -E "s/ovf:capacity=\"[0-9]+\"/ovf:capacity=\"${fsize}\"/" "${n}/${ovf}"
  ( cd "$n" && printf 'SHA256(%s)= %s\n' "$ovf" "$(sha256sum "$ovf" | cut -d' ' -f1)" > "$mf"
               printf 'SHA256(%s)= %s\n' "$vmdk" "$(sha256sum "$vmdk" | cut -d' ' -f1)" >> "$mf"
               tar -cf "${T}/neg-${arch}-$(basename "$src")" "$ovf" "$mf" "$vmdk" )
  if bash "$VALIDATE" "${T}/neg-${arch}-$(basename "$src")" >"${T}/neg-${arch}.log" 2>&1; then
    bad "${arch}: validate-ovf.sh PASSED an OVA with capacity=file size (${fsize}) - capacity gate is not fail-closed"
  elif grep -q "capacity" "${T}/neg-${arch}.log"; then
    pass "${arch}: file-size-as-capacity OVA rejected by the capacity gate"
  else
    bad "${arch}: negative OVA failed, but not on the capacity check: $(grep FAIL "${T}/neg-${arch}.log" | head -3)"
  fi
done

[[ "$fail" -eq 0 ]] && echo "  ovf-capacity-contract: PASS" || { echo "  ovf-capacity-contract: FAIL" >&2; exit 1; }
