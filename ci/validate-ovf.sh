#!/usr/bin/env bash
# validate-ovf.sh - FOSS, offline OVA/OVF structural validation gate.
#
# The two hypervisor OVAs ship a HAND-AUTHORED OVF descriptor (sed-filled from a
# template). A descriptor that tars + checksums fine can still be malformed in
# ways only a real import would surface. A full `ovftool --verifyOnly` /
# `VBoxManage import --dry-run` needs non-FOSS / kernel-module tooling (the
# dev-box lane), so this gate does the MECHANICAL checks that catch the common
# errors with nothing but xmllint + tar + qemu-img + sha256sum:
#
#   1. OVA tar member ORDER: descriptor first, then manifest, then disk
#      (.ovf, .mf, .vmdk) - importers read the descriptor streaming-first.
#   2. The .ovf is well-formed XML (xmllint), and - if an OVF envelope XSD is
#      provided via OVF_XSD - schema-valid against it.
#   3. Required OVF structure is present (References/File, DiskSection/Disk,
#      VirtualSystem, a CPU item, a memory item).
#   4. The disk is advertised as streamOptimized (the only distributable VMDK
#      subformat inside an OVA).
#   5. The advertised sizes match the REAL disk: Disk/@ovf:populatedSize (and
#      File/@ovf:size when present) == the actual VMDK byte size.
#   6. The .mf SHA256 entries match the actual file hashes.
#   7. The VMDK is a readable VMDK (qemu-img info).
#   8. Default RAM is the shipped baseline (>= MIN_RAM_MB, default 8192) - guards
#      the 8GB-box engine capacity floor from silently regressing.
#
# Open-source tools only; READ-ONLY. Exit non-zero on any violation.
#
# Usage: validate-ovf.sh <artifact.ova> [<artifact.ova> ...]
#   OVF_XSD=/path/to/dsp8023.xsd  -> also run xmllint --schema (optional)
#   MIN_RAM_MB=8192               -> minimum advertised RAM (default 8192)
set -euo pipefail

MIN_RAM_MB="${MIN_RAM_MB:-8192}"
FAIL=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

say()  { echo "[validate-ovf] $*"; }
ok()   { echo "[validate-ovf][ok]   $*"; }
bad()  { echo "[validate-ovf][FAIL] $*" >&2; FAIL=1; }

command -v xmllint  >/dev/null 2>&1 || { echo "[validate-ovf] xmllint required (apt-get install libxml2-utils)" >&2; exit 2; }
command -v qemu-img >/dev/null 2>&1 || { echo "[validate-ovf] qemu-img required (apt-get install qemu-utils)" >&2; exit 2; }

# namespace-agnostic xpath helper (local-name() so we need not register the OVF
# / RASD / VSSD namespaces on the xmllint CLI).
xp() { xmllint --xpath "$1" "$2" 2>/dev/null || true; }
# count()/number xpath -> a plain integer (strip any decimal/whitespace so a
# "2.0"-style result from some libxml2 builds can't break an arithmetic test).
xpnum() { local v; v="$(xp "$1" "$2")"; v="${v%%.*}"; v="${v//[^0-9]/}"; echo "${v:-0}"; }

validate_one() {
  local ova="$1" base; base="$(basename "$ova")"
  say "validating ${base}"
  [[ -f "$ova" ]] || { bad "${base}: file not found"; return; }

  # --- 1. tar member order ---------------------------------------------------
  local members; mapfile -t members < <(tar -tf "$ova")
  [[ "${#members[@]}" -ge 3 ]] || { bad "${base}: OVA has <3 members (${members[*]:-none})"; return; }
  local m_ovf="" m_mf="" m_vmdk="" i=0 pos_ovf=-1 pos_mf=-1 pos_vmdk=-1
  for m in "${members[@]}"; do
    case "$m" in
      *.ovf)  [[ -z "$m_ovf"  ]] && { m_ovf="$m";  pos_ovf=$i; } ;;
      *.mf)   [[ -z "$m_mf"   ]] && { m_mf="$m";   pos_mf=$i; } ;;
      *.vmdk) [[ -z "$m_vmdk" ]] && { m_vmdk="$m"; pos_vmdk=$i; } ;;
    esac
    i=$((i+1))
  done
  [[ -n "$m_ovf"  ]] || bad "${base}: no .ovf member"
  [[ -n "$m_vmdk" ]] || bad "${base}: no .vmdk member"
  [[ "$pos_ovf" -eq 0 ]] && ok "${base}: descriptor is first tar member (${m_ovf})" \
                         || bad "${base}: .ovf is NOT the first member (importers read it streaming-first)"
  if [[ -n "$m_mf" ]]; then
    { [[ "$pos_ovf" -lt "$pos_mf" && "$pos_mf" -lt "$pos_vmdk" ]] \
        && ok "${base}: member order ovf < mf < vmdk"; } \
      || bad "${base}: member order should be .ovf, .mf, .vmdk (got pos ovf=$pos_ovf mf=$pos_mf vmdk=$pos_vmdk)"
  fi

  # --- extract for the content checks ---------------------------------------
  local d; d="$(mktemp -d "${TMPROOT}/ova.XXXX")"
  # tar -C (not `cd "$d" && tar xf "$ova"`): $ova is often a RELATIVE path
  # (out/*.ova from the workflow glob), which would resolve against $d after a cd.
  tar -C "$d" -xf "$ova"
  local ovf="${d}/${m_ovf}" vmdk="${d}/${m_vmdk}"

  # --- 2. well-formed (+ optional schema) -----------------------------------
  if xmllint --noout "$ovf" 2>/dev/null; then ok "${base}: .ovf is well-formed XML"
  else bad "${base}: .ovf is NOT well-formed XML"; fi
  if [[ -n "${OVF_XSD:-}" && -f "${OVF_XSD}" ]]; then
    if xmllint --noout --schema "${OVF_XSD}" "$ovf" >/dev/null 2>&1; then ok "${base}: .ovf is schema-valid (${OVF_XSD##*/})"
    else bad "${base}: .ovf FAILS schema validation against ${OVF_XSD}"; fi
  fi

  # --- 3. required structure ------------------------------------------------
  local n_file n_disk n_vs n_cpu n_mem
  n_file="$(xpnum "count(//*[local-name()='References']/*[local-name()='File'])" "$ovf")"
  n_disk="$(xpnum "count(//*[local-name()='DiskSection']/*[local-name()='Disk'])" "$ovf")"
  n_vs="$(xpnum   "count(//*[local-name()='VirtualSystem'])" "$ovf")"
  n_cpu="$(xpnum  "count(//*[local-name()='Item'][*[local-name()='ResourceType']='3'])" "$ovf")"
  n_mem="$(xpnum  "count(//*[local-name()='Item'][*[local-name()='ResourceType']='4'])" "$ovf")"
  [[ "$n_file" -ge 1 ]] && ok "${base}: References/File present" || bad "${base}: no References/File"
  [[ "$n_disk" -ge 1 ]] && ok "${base}: DiskSection/Disk present" || bad "${base}: no DiskSection/Disk"
  [[ "$n_vs"   -ge 1 ]] && ok "${base}: VirtualSystem present"    || bad "${base}: no VirtualSystem"
  [[ "$n_cpu"  -ge 1 ]] && ok "${base}: CPU item present"         || bad "${base}: no CPU (ResourceType=3) item"
  [[ "$n_mem"  -ge 1 ]] && ok "${base}: memory item present"      || bad "${base}: no memory (ResourceType=4) item"

  # --- 4. streamOptimized ----------------------------------------------------
  local fmt; fmt="$(xp "string(//*[local-name()='Disk']/@*[local-name()='format'])" "$ovf")"
  case "$fmt" in
    *streamOptimized*) ok "${base}: disk advertised streamOptimized" ;;
    *) bad "${base}: disk format is not streamOptimized (got '${fmt:-unset}') - not distributable in an OVA" ;;
  esac

  # --- 5. advertised sizes == real VMDK size --------------------------------
  local real_sz pop_sz file_sz
  real_sz="$(stat -c%s "$vmdk")"
  pop_sz="$(xp "string(//*[local-name()='Disk']/@*[local-name()='populatedSize'])" "$ovf")"
  file_sz="$(xp "string(//*[local-name()='References']/*[local-name()='File']/@*[local-name()='size'])" "$ovf")"
  if [[ -n "$pop_sz" ]]; then
    [[ "$pop_sz" == "$real_sz" ]] && ok "${base}: Disk/@populatedSize == real VMDK size (${real_sz})" \
                                  || bad "${base}: Disk/@populatedSize (${pop_sz}) != real VMDK size (${real_sz})"
  else
    say "${base}: no Disk/@populatedSize to check (ok for some descriptors)"
  fi
  if [[ -n "$file_sz" ]]; then
    [[ "$file_sz" == "$real_sz" ]] && ok "${base}: File/@ovf:size == real VMDK size (${real_sz})" \
                                   || bad "${base}: File/@ovf:size (${file_sz}) != real VMDK size (${real_sz})"
  fi

  # --- 6. .mf SHA256 entries match actual files -----------------------------
  if [[ -n "$m_mf" && -f "${d}/${m_mf}" ]]; then
    local line algo fref want got
    local mfre='^([A-Za-z0-9]+)\(([^)]+)\)=[[:space:]]*([0-9a-fA-F]+)$'
    while IFS= read -r line; do
      [[ "$line" =~ $mfre ]] || continue
      algo="${BASH_REMATCH[1]}"; fref="${BASH_REMATCH[2]}"; want="${BASH_REMATCH[3]}"
      [[ "$algo" == "SHA256" ]] || { say "${base}: .mf uses ${algo} for ${fref} (expected SHA256) - noting"; }
      [[ -f "${d}/${fref}" ]] || { bad "${base}: .mf references missing file ${fref}"; continue; }
      got="$(sha256sum "${d}/${fref}" | cut -d' ' -f1)"
      [[ "${got,,}" == "${want,,}" ]] && ok "${base}: .mf hash OK for ${fref}" \
                                      || bad "${base}: .mf hash MISMATCH for ${fref} (want ${want}, got ${got})"
    done < "${d}/${m_mf}"
  else
    say "${base}: no .mf manifest present"
  fi

  # --- 7. VMDK is a readable VMDK -------------------------------------------
  # Use the human-readable "file format: vmdk" line, not --output=json: modern
  # qemu-img JSON lists a "children" file-protocol node whose "format":"file"
  # sorts first, so a naive first-match parse misreads the real disk format.
  local qfmt; qfmt="$(qemu-img info "$vmdk" 2>/dev/null | sed -n 's/^file format: *//p' | head -1)"
  [[ "$qfmt" == "vmdk" ]] && ok "${base}: VMDK readable by qemu-img (format=vmdk)" \
                          || bad "${base}: qemu-img could not read the VMDK as vmdk (got '${qfmt:-none}')"

  # --- 8. RAM floor ----------------------------------------------------------
  local ram; ram="$(xp "string((//*[local-name()='Item'][*[local-name()='ResourceType']='4']/*[local-name()='VirtualQuantity'])[1])" "$ovf")"
  if [[ "$ram" =~ ^[0-9]+$ ]]; then
    [[ "$ram" -ge "$MIN_RAM_MB" ]] && ok "${base}: default RAM ${ram}MB >= floor ${MIN_RAM_MB}MB" \
                                   || bad "${base}: default RAM ${ram}MB is BELOW the ${MIN_RAM_MB}MB engine floor"
  else
    bad "${base}: could not read a numeric memory VirtualQuantity (got '${ram:-unset}')"
  fi

  rm -rf "$d"
}

[[ $# -ge 1 ]] || { echo "usage: $0 <artifact.ova> [...]" >&2; exit 2; }
for a in "$@"; do validate_one "$a"; done

if [[ "$FAIL" -ne 0 ]]; then
  echo "[validate-ovf] RESULT: FAIL - an OVA/OVF structural check failed. Build must NOT publish." >&2
  exit 1
fi
say "RESULT: PASS - all OVA/OVF structural checks passed."
