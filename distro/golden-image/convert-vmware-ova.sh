#!/usr/bin/env bash
# convert-vmware-ova.sh - golden qcow2 -> streamOptimized VMDK -> hand-authored
# OVF (amd64: vmx-13 + LSI Logic SCSI + BIOS; arm64: vmx-20 + SATA AHCI + EFI)
# -> .mf (SHA256) -> tar -> .ova.
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
GOLDEN="${GOLDEN:-${OUT}/vacti-engine-${VACTI_RELEASE}${VACTI_ARCH_SUFFIX}${VACTI_FLAVOR_SUFFIX}-golden.qcow2}"
TMPL="${HERE}/ovf-templates/vmware-vmx13.ovf.tmpl"
[[ -f "$GOLDEN" ]] || { echo "golden disk not found: $GOLDEN" >&2; exit 1; }

# VMware guest OS identifier, arch-keyed. The disk block-copies regardless of arch;
# the descriptor advertises the guest so the host selects arm firmware/CPU on
# import. An arm64 OVA imports on an arm64-host VMware (Fusion 13 on Apple Silicon);
# the real-import check stays the dev-box ovftool lane.
# P1-6: the arm64 hardware must be what VMware Fusion on Apple Silicon can run:
# Fusion's arm64 VMs have NO LSI Logic SCSI (SATA AHCI / NVMe only) and are UEFI-only,
# and arm guests need the Fusion 13 hardware family (vmx-20). The arm64 golden boots
# from its EFI system partition, so the descriptor must ask for EFI explicitly. amd64
# keeps the long-proven vmx-13 + lsilogic + BIOS set (Workstation/Player/ESXi).
# The VMDK adapter type follows the controller (VMware SATA disks use "ide").
case "$DEBIAN_ARCH" in
  arm64|aarch64)
    VMW_OSTYPE="arm-debian12-64"; VMW_HWVER="vmx-20"; VMW_FIRMWARE="efi"
    VMW_CTRL_NAME="SATA Controller 0"; VMW_CTRL_RTYPE="20"; VMW_CTRL_SUBTYPE="vmware.sata.ahci"
    VMDK_ADAPTER="ide" ;;
  *)
    VMW_OSTYPE="debian12_64Guest"; VMW_HWVER="vmx-13"; VMW_FIRMWARE="bios"
    VMW_CTRL_NAME="SCSI Controller 0"; VMW_CTRL_RTYPE="6"; VMW_CTRL_SUBTYPE="lsilogic"
    VMDK_ADAPTER="lsilogic" ;;
esac

NAME="vacti-engine-${VACTI_RELEASE}${VACTI_ARCH_SUFFIX}${VACTI_FLAVOR_SUFFIX}-vmware"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
VMDK="${NAME}-disk1.vmdk"

echo "[vmware] qemu-img -> streamOptimized VMDK (${VMDK_ADAPTER})"
qemu-img convert -p -f qcow2 -O vmdk \
  -o "subformat=streamOptimized,adapter_type=${VMDK_ADAPTER}" \
  "$GOLDEN" "${WORK}/${VMDK}"

# OVF descriptor from template: substitute disk file, capacity, sizes.
# P0-1: the OVF ovf:capacity MUST be the VIRTUAL disk size (100G), never the image
# FILE size. Modern `qemu-img info --output=json` nests a "children" file-protocol
# node that sorts BEFORE the top-level keys and carries its own "virtual-size" (=
# the ~5.6GB qcow2 file length), so a first-match sed/grep read the file size and
# shipped capacity=5.8GB on a 100GB disk (VirtualBox refuses to boot it). Parse the
# TOP-LEVEL key with a real JSON parser; fall back to the human "virtual size: ...
# (N bytes)" line (the first one is always the top-level node). Fail-closed.
qemu_virtual_size() { # <image> -> bytes on stdout, or non-zero
  local img="$1" v=""
  if command -v python3 >/dev/null 2>&1; then
    v="$(qemu-img info --output=json "$img" 2>/dev/null \
         | python3 -I -c 'import json,sys; print(int(json.load(sys.stdin)["virtual-size"]))' 2>/dev/null || true)"
  fi
  if ! [[ "$v" =~ ^[0-9]+$ ]]; then
    v="$(qemu-img info "$img" 2>/dev/null | sed -n 's/^virtual size:.*(\([0-9]*\) bytes).*/\1/p' | head -1)"
  fi
  [[ "$v" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$v"
}
POP_BYTES="$(stat -c%s "${WORK}/${VMDK}")"
GOLDEN_VSIZE="$(qemu_virtual_size "$GOLDEN")" || { echo "[vmware] cannot read the golden virtual size" >&2; exit 1; }
CAP_BYTES="$(qemu_virtual_size "${WORK}/${VMDK}")" || { echo "[vmware] cannot read the VMDK virtual size" >&2; exit 1; }
# The descriptor advertises the disk INSIDE the package (the VMDK). It must not be
# smaller than the golden it came from, and it must exceed the compressed
# populated size (capacity <= populated is exactly the file-size-for-capacity bug).
[[ "$CAP_BYTES" -ge "$GOLDEN_VSIZE" ]] || { echo "[vmware] VMDK virtual size ${CAP_BYTES} < golden virtual size ${GOLDEN_VSIZE}" >&2; exit 1; }
[[ "$CAP_BYTES" -gt "$POP_BYTES" ]] || { echo "[vmware] capacity ${CAP_BYTES} <= populated ${POP_BYTES}: refusing a file-size-as-capacity OVF" >&2; exit 1; }
echo "[vmware] disk capacity ${CAP_BYTES} bytes (virtual), populated ${POP_BYTES} bytes"
OVF="${NAME}.ovf"
sed -e "s|@VMDK@|${VMDK}|g" \
    -e "s|@DISK_CAPACITY@|${CAP_BYTES}|g" \
    -e "s|@DISK_POPULATED@|${POP_BYTES}|g" \
    -e "s|@PRODUCT@|${VACTI_PRODUCT_PRETTY}|g" \
    -e "s|@VERSION@|${VACTI_RELEASE}|g" \
    -e "s|@VMW_OSTYPE@|${VMW_OSTYPE}|g" \
    -e "s|@VMW_HWVER@|${VMW_HWVER}|g" \
    -e "s|@VMW_FIRMWARE@|${VMW_FIRMWARE}|g" \
    -e "s|@VMW_CTRL_NAME@|${VMW_CTRL_NAME}|g" \
    -e "s|@VMW_CTRL_RTYPE@|${VMW_CTRL_RTYPE}|g" \
    -e "s|@VMW_CTRL_SUBTYPE@|${VMW_CTRL_SUBTYPE}|g" \
    "$TMPL" > "${WORK}/${OVF}"

echo "[vmware] manifest (.mf, SHA256)"
( cd "$WORK" && printf 'SHA256(%s)= %s\n' "$OVF"  "$(sha256sum "$OVF"  | cut -d' ' -f1)"  >  "${NAME}.mf"
                printf 'SHA256(%s)= %s\n' "$VMDK" "$(sha256sum "$VMDK" | cut -d' ' -f1)"  >> "${NAME}.mf" )

echo "[vmware] tar -> .ova (.ovf, .mf, .vmdk in order)"
( cd "$WORK" && tar -cf "${OUT}/${NAME}.ova" "$OVF" "${NAME}.mf" "$VMDK" )
( cd "$OUT" && sha256sum "${NAME}.ova" > "${NAME}.ova.sha256" )
echo "[vmware] done: ${OUT}/${NAME}.ova"
