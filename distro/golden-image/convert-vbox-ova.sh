#!/usr/bin/env bash
# convert-vbox-ova.sh - golden qcow2 -> streamOptimized VMDK -> hand-authored
# OVF (VirtualSystemType=virtualbox-2.2, SATA) -> .mf -> tar -> .ova. Same VMDK
# as the VMware OVA, different (VBox-flavoured) OVF descriptor - that is why we
# ship TWO OVAs, not one "universal" file. VBoxManage is NOT required in CI;
# `VBoxManage export --ovf10` is the dev-box alternative.
# HEAVY-ish - runs in CI, not on prod.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISTRO_DIR="$(cd "${HERE}/.." && pwd)"
# shellcheck source=/dev/null
source "${DISTRO_DIR}/vacti-appliance.env"
OUT="${OUT_DIR:-${DISTRO_DIR}/out}"
GOLDEN="${GOLDEN:-${OUT}/vacti-engine-${VACTI_RELEASE}-golden.qcow2}"
TMPL="${HERE}/ovf-templates/virtualbox-2.2.ovf.tmpl"
[[ -f "$GOLDEN" ]] || { echo "golden disk not found: $GOLDEN" >&2; exit 1; }

NAME="vacti-engine-${VACTI_RELEASE}-virtualbox"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
VMDK="${NAME}-disk1.vmdk"

echo "[vbox] qemu-img -> streamOptimized VMDK"
qemu-img convert -p -f qcow2 -O vmdk -o subformat=streamOptimized \
  "$GOLDEN" "${WORK}/${VMDK}"

POP_BYTES="$(stat -c%s "${WORK}/${VMDK}")"
CAP_BYTES="$(qemu-img info --output=json "$GOLDEN" | sed -n 's/.*"virtual-size": *\([0-9]*\).*/\1/p' | head -1)"
OVF="${NAME}.ovf"
sed -e "s|@VMDK@|${VMDK}|g" \
    -e "s|@DISK_CAPACITY@|${CAP_BYTES:-21474836480}|g" \
    -e "s|@DISK_POPULATED@|${POP_BYTES}|g" \
    -e "s|@PRODUCT@|${VACTI_PRODUCT_PRETTY}|g" \
    -e "s|@VERSION@|${VACTI_RELEASE}|g" \
    "$TMPL" > "${WORK}/${OVF}"

echo "[vbox] manifest (.mf, SHA256)"
( cd "$WORK" && printf 'SHA256(%s)= %s\n' "$OVF"  "$(sha256sum "$OVF"  | cut -d' ' -f1)"  >  "${NAME}.mf"
                printf 'SHA256(%s)= %s\n' "$VMDK" "$(sha256sum "$VMDK" | cut -d' ' -f1)"  >> "${NAME}.mf" )

echo "[vbox] tar -> .ova"
( cd "$WORK" && tar -cf "${OUT}/${NAME}.ova" "$OVF" "${NAME}.mf" "$VMDK" )
( cd "$OUT" && sha256sum "${NAME}.ova" > "${NAME}.ova.sha256" )
echo "[vbox] done: ${OUT}/${NAME}.ova"
