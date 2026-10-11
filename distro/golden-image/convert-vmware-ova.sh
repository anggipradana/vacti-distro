#!/usr/bin/env bash
# convert-vmware-ova.sh - golden qcow2 -> streamOptimized VMDK -> hand-authored
# OVF (VirtualSystemType=vmx-13, LSI Logic SCSI) -> .mf (SHA256) -> tar -> .ova.
# Fully open-source toolchain (qemu-img + tar); ovftool is NOT used/shipped.
# HEAVY-ish - runs in CI, not on prod.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISTRO_DIR="$(cd "${HERE}/.." && pwd)"
# shellcheck source=/dev/null
source "${DISTRO_DIR}/vacti-appliance.env"
OUT="${OUT_DIR:-${DISTRO_DIR}/out}"
# Resolve OUT to an ABSOLUTE path: OUT_DIR is often a relative "out" (set in the
# CI env), and the final `tar -cf "${OUT}/..."` runs inside a `cd "$WORK"`
# subshell where a relative path would point at the (empty) temp dir and fail
# with "Cannot open: No such file or directory".
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
GOLDEN="${GOLDEN:-${OUT}/vacti-engine-${VACTI_RELEASE}-golden.qcow2}"
TMPL="${HERE}/ovf-templates/vmware-vmx13.ovf.tmpl"
[[ -f "$GOLDEN" ]] || { echo "golden disk not found: $GOLDEN" >&2; exit 1; }

NAME="vacti-engine-${VACTI_RELEASE}-vmware"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
VMDK="${NAME}-disk1.vmdk"

echo "[vmware] qemu-img -> streamOptimized VMDK (lsilogic)"
qemu-img convert -p -f qcow2 -O vmdk \
  -o subformat=streamOptimized,adapter_type=lsilogic \
  "$GOLDEN" "${WORK}/${VMDK}"

# OVF descriptor from template: substitute disk file, capacity, sizes.
POP_BYTES="$(stat -c%s "${WORK}/${VMDK}")"
CAP_BYTES="$(qemu-img info --output=json "$GOLDEN" | sed -n 's/.*"virtual-size": *\([0-9]*\).*/\1/p' | head -1)"
OVF="${NAME}.ovf"
sed -e "s|@VMDK@|${VMDK}|g" \
    -e "s|@DISK_CAPACITY@|${CAP_BYTES:-21474836480}|g" \
    -e "s|@DISK_POPULATED@|${POP_BYTES}|g" \
    -e "s|@PRODUCT@|${VACTI_PRODUCT_PRETTY}|g" \
    -e "s|@VERSION@|${VACTI_RELEASE}|g" \
    "$TMPL" > "${WORK}/${OVF}"

echo "[vmware] manifest (.mf, SHA256)"
( cd "$WORK" && printf 'SHA256(%s)= %s\n' "$OVF"  "$(sha256sum "$OVF"  | cut -d' ' -f1)"  >  "${NAME}.mf"
                printf 'SHA256(%s)= %s\n' "$VMDK" "$(sha256sum "$VMDK" | cut -d' ' -f1)"  >> "${NAME}.mf" )

echo "[vmware] tar -> .ova (.ovf, .mf, .vmdk in order)"
( cd "$WORK" && tar -cf "${OUT}/${NAME}.ova" "$OVF" "${NAME}.mf" "$VMDK" )
( cd "$OUT" && sha256sum "${NAME}.ova" > "${NAME}.ova.sha256" )
echo "[vmware] done: ${OUT}/${NAME}.ova"
