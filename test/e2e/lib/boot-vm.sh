#!/usr/bin/env bash
# boot-vm.sh - OVA -> qcow2, then boot headless under qemu for the e2e harness.
# Mirrors the arch/UEFI/TCG handling proven in ci/smoke-boot.sh, adding a VNC
# display (GUI flavor input via vncdotool) and a serial PTY (headless flavor
# input via expect). qemu user-net (SLIRP) gives the guest outbound NAT and maps
# the host loopback to 10.0.2.2, so the guest reaches a mock CP bound on the host.
#
# Two sub-commands:
#   convert <ova> <qcow2-out>        extract the VMDK from the OVA tar, convert to qcow2
#   boot    <qcow2> <vnc-port> <serial-pty-link> [pidfile]
#                                     boot headless; KVM if available (E2E_NO_KVM=1 forces TCG)
#
# Every artifact lands under the caller's workspace; nothing persists outside it.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test/e2e/lib/assert.sh
. "${HERE}/assert.sh"

ARCH="${E2E_ARCH:-amd64}"
MEM_MB="${E2E_MEM_MB:-4096}"

qemu_bin() {
  if [[ "$ARCH" == "arm64" ]]; then echo "qemu-system-aarch64"; else echo "qemu-system-x86_64"; fi
}

find_uefi_fw() { # echoes a firmware CODE blob path, or nothing
  local c
  if [[ "$ARCH" == "arm64" ]]; then
    for c in /usr/share/AAVMF/AAVMF_CODE.fd /usr/share/qemu-efi-aarch64/QEMU_EFI.fd \
             /usr/share/qemu/edk2-aarch64-code.fd; do
      [[ -f "$c" ]] && { echo "$c"; return 0; }
    done
  else
    for c in /usr/share/OVMF/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd /usr/share/qemu/OVMF.fd; do
      [[ -f "$c" ]] && { echo "$c"; return 0; }
    done
  fi
  return 0
}

cmd_convert() { # ova qcow2-out
  local ova="$1" out="$2"
  require_cmd qemu-img tar
  [[ -f "$ova" ]] || cp_fail "convert" "OVA not found: $ova"
  local work; work="$(mktemp -d)"
  e2e_log "extracting VMDK from OVA tar"
  tar -xf "$ova" -C "$work"
  local vmdk; vmdk="$(find "$work" -maxdepth 1 -name '*.vmdk' | head -n1)"
  [[ -n "$vmdk" ]] || { rm -rf "$work"; cp_fail "convert" "no .vmdk inside OVA"; }
  e2e_log "qemu-img convert vmdk -> qcow2"
  qemu-img convert -p -O qcow2 "$vmdk" "$out" || { rm -rf "$work"; cp_fail "convert" "qemu-img convert failed"; }
  rm -rf "$work"
  e2e_ok "qcow2 ready: $out"
}

cmd_boot() { # qcow2 vnc-port serial-pty-link [pidfile]
  local disk="$1" vnc_port="$2" pty_link="$3" pidfile="${4:-}"
  local qemu; qemu="$(qemu_bin)"
  require_cmd "$qemu"

  # VNC display number is port - 5900.
  local vnc_disp=$(( vnc_port - 5900 ))
  [[ "$vnc_disp" -ge 0 ]] || cp_fail "boot" "vnc-port must be >= 5900"

  local accel=() machine=() cpu=()
  if [[ "$ARCH" == "arm64" ]]; then
    machine=(-machine virt); cpu=(-cpu "${E2E_QEMU_CPU:-cortex-a72}")
  else
    cpu=(-cpu "${E2E_QEMU_CPU:-qemu64}")
  fi
  if [[ "${E2E_NO_KVM:-0}" != "1" && -w /dev/kvm ]]; then
    accel=(-enable-kvm); [[ "$ARCH" == "amd64" ]] && cpu=(-cpu host)
    e2e_log "KVM available: using hardware acceleration"
  else
    e2e_log "KVM unavailable or disabled: using TCG (slower)"
  fi

  local fw; fw="$(find_uefi_fw)"
  local fw_args=()
  if [[ -n "$fw" ]]; then
    fw_args=(-drive "if=pflash,format=raw,readonly=on,file=${fw}")
  elif [[ "$ARCH" == "arm64" ]]; then
    cp_fail "boot" "arm64 requires UEFI firmware (install qemu-efi-aarch64)"
  fi

  e2e_log "booting ${disk} (arch=${ARCH}, vnc=:${vnc_disp}, serial pty)"
  # -serial pty prints "char device redirected to /dev/pts/N"; capture it so the
  # caller can attach expect. We symlink that pts to $pty_link for a stable path.
  local serial_log; serial_log="$(mktemp)"
  "$qemu" "${accel[@]}" "${machine[@]}" "${cpu[@]}" \
    -m "$MEM_MB" -smp "${E2E_SMP:-2}" \
    "${fw_args[@]}" \
    -drive "file=${disk},if=virtio,format=qcow2" \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -display none -vnc "127.0.0.1:${vnc_disp}" \
    -serial pty -serial "file:${disk}.console.log" \
    ${pidfile:+-pidfile "$pidfile"} \
    -daemonize 2>"$serial_log" || { cat "$serial_log" >&2; rm -f "$serial_log"; cp_fail "boot" "qemu failed to start"; }

  local pts; pts="$(sed -n 's/.*redirected to \(\/dev\/pts\/[0-9]*\).*/\1/p' "$serial_log" | head -n1)"
  rm -f "$serial_log"
  if [[ -n "$pts" && -n "$pty_link" ]]; then
    ln -sf "$pts" "$pty_link"
    e2e_ok "serial console at ${pty_link} -> ${pts}"
  fi
  e2e_ok "VM booting; VNC on 127.0.0.1:${vnc_port}"
}

case "${1:-}" in
  convert) shift; cmd_convert "$@" ;;
  boot)    shift; cmd_boot "$@" ;;
  *) echo "usage: boot-vm.sh {convert <ova> <qcow2>|boot <qcow2> <vnc-port> <pty-link> [pidfile]}" >&2; exit 2 ;;
esac
