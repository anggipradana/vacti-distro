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
# Resolve OUT to an ABSOLUTE path: OUT_DIR is often a relative "out" (set in the
# CI env), and the final `tar -cf "${OUT}/..."` runs inside a `cd "$WORK"`
# subshell where a relative path would point at the (empty) temp dir and fail
# with "Cannot open: No such file or directory".
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
GOLDEN="${GOLDEN:-${OUT}/vacti-engine-${VACTI_RELEASE}${VACTI_ARCH_SUFFIX}${VACTI_FLAVOR_SUFFIX}-golden.qcow2}"
TMPL="${HERE}/ovf-templates/virtualbox-2.2.ovf.tmpl"
[[ -f "$GOLDEN" ]] || { echo "golden disk not found: $GOLDEN" >&2; exit 1; }

# VirtualBox guest OS type, arch-keyed. The disk block-copies regardless of arch;
# the descriptor advertises the guest so the host picks the right firmware/CPU on
# import. An arm64 OVA imports on an arm64-host VirtualBox (7.1+ on Apple Silicon
# / Linux arm64); the real-import check stays the dev-box VBoxManage lane.
case "$DEBIAN_ARCH" in
  arm64|aarch64) VBOX_OSTYPE="Debian_arm64" ;;
  *)             VBOX_OSTYPE="Debian_64" ;;
esac

NAME="vacti-engine-${VACTI_RELEASE}${VACTI_ARCH_SUFFIX}${VACTI_FLAVOR_SUFFIX}-virtualbox"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
VMDK="${NAME}-disk1.vmdk"

echo "[vbox] qemu-img -> streamOptimized VMDK"
qemu-img convert -p -f qcow2 -O vmdk -o subformat=streamOptimized \
  "$GOLDEN" "${WORK}/${VMDK}"

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
GOLDEN_VSIZE="$(qemu_virtual_size "$GOLDEN")" || { echo "[vbox] cannot read the golden virtual size" >&2; exit 1; }
CAP_BYTES="$(qemu_virtual_size "${WORK}/${VMDK}")" || { echo "[vbox] cannot read the VMDK virtual size" >&2; exit 1; }
# The descriptor advertises the disk INSIDE the package (the VMDK). It must not be
# smaller than the golden it came from, and it must exceed the compressed
# populated size (capacity <= populated is exactly the file-size-for-capacity bug).
[[ "$CAP_BYTES" -ge "$GOLDEN_VSIZE" ]] || { echo "[vbox] VMDK virtual size ${CAP_BYTES} < golden virtual size ${GOLDEN_VSIZE}" >&2; exit 1; }
[[ "$CAP_BYTES" -gt "$POP_BYTES" ]] || { echo "[vbox] capacity ${CAP_BYTES} <= populated ${POP_BYTES}: refusing a file-size-as-capacity OVF" >&2; exit 1; }
echo "[vbox] disk capacity ${CAP_BYTES} bytes (virtual), populated ${POP_BYTES} bytes"
OVF="${NAME}.ovf"
sed -e "s|@VMDK@|${VMDK}|g" \
    -e "s|@DISK_CAPACITY@|${CAP_BYTES}|g" \
    -e "s|@DISK_POPULATED@|${POP_BYTES}|g" \
    -e "s|@PRODUCT@|${VACTI_PRODUCT_PRETTY}|g" \
    -e "s|@VERSION@|${VACTI_RELEASE}|g" \
    -e "s|@VBOX_OSTYPE@|${VBOX_OSTYPE}|g" \
    "$TMPL" > "${WORK}/${OVF}"

echo "[vbox] manifest (.mf, SHA256)"
( cd "$WORK" && printf 'SHA256(%s)= %s\n' "$OVF"  "$(sha256sum "$OVF"  | cut -d' ' -f1)"  >  "${NAME}.mf"
                printf 'SHA256(%s)= %s\n' "$VMDK" "$(sha256sum "$VMDK" | cut -d' ' -f1)"  >> "${NAME}.mf" )

echo "[vbox] tar -> .ova"
( cd "$WORK" && tar -cf "${OUT}/${NAME}.ova" "$OVF" "${NAME}.mf" "$VMDK" )
( cd "$OUT" && sha256sum "${NAME}.ova" > "${NAME}.ova.sha256" )
echo "[vbox] done: ${OUT}/${NAME}.ova"
