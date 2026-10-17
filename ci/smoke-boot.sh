#!/usr/bin/env bash
# smoke-boot.sh - REAL qemu boot smoke test (replaces the old TODO placeholder).
#
# Boots each built image in qemu (TCG, no KVM required - works on any runner)
# and asserts the appliance actually boots to a healthy multi-user system with
# the vacti units baked in. This is the always-on FOSS gate; it proves the
# ROOTFS boots. It does NOT prove an OVF descriptor imports into a real
# hypervisor (that is the optional ovftool/VBoxManage dev-box lane) and it does
# NOT require a staging control plane.
#
# How the disk images are asserted (qcow2 / ova):
#   A throwaway NoCloud seed (CIDATA) is attached as a second disk. cloud-init
#   runs a health probe on first boot that writes SMOKE_* markers to the serial
#   console and powers the VM off. The probe asserts, WITHOUT any enroll token:
#     - systemd reached a running/degraded (not failed) state
#     - the baked vacti units are present (vacti-firstboot/-swap, earlyoom, zram)
#     - a global IPv4 address is up (NAT user-net)
#   The vacti-firstboot unit itself is EXPECTED to fail here (no token minted),
#   so we assert its PRESENCE, never its success. Optionally, if STAGING_CP_URL +
#   STAGING_ENROLL_TOKEN are exported, the seed also drives a real enroll
#   roundtrip and asserts SMOKE_ENROLL=ok (gated on those secrets being present).
#
# ISO images are boot-only asserted (reach a login/live prompt within timeout);
# the live-build ISO has no NoCloud path.
#
# Usage: smoke-boot.sh <image-or-dir> [more...]
#   BOOT_TIMEOUT=900   per-image boot timeout seconds (default 900; TCG is slow)
#   SMOKE_MEM_MB=2048  guest RAM for the smoke boot (default 2048; just to boot)
#   STAGING_CP_URL / STAGING_ENROLL_TOKEN  optional real-enroll roundtrip
set -euo pipefail

BOOT_TIMEOUT="${BOOT_TIMEOUT:-900}"
SMOKE_MEM_MB="${SMOKE_MEM_MB:-2048}"
QEMU="${QEMU:-qemu-system-x86_64}"

FAIL=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
say()  { echo "[smoke] $*"; }
ok()   { echo "[smoke][ok]   $*"; }
bad()  { echo "[smoke][FAIL] $*" >&2; FAIL=1; }

command -v "$QEMU"  >/dev/null 2>&1 || { echo "[smoke] $QEMU required (apt-get install qemu-system-x86)" >&2; exit 2; }
command -v qemu-img >/dev/null 2>&1 || { echo "[smoke] qemu-img required" >&2; exit 2; }

# --- build the throwaway NoCloud health-probe seed (once) --------------------
build_seed() {
  local sd="${TMPROOT}/seed" out="${TMPROOT}/cidata.iso"
  mkdir -p "$sd"
  cat > "${sd}/meta-data" <<'META'
instance-id: vacti-smoke
local-hostname: vacti-smoke
META
  # Health probe. Writes markers to /dev/console (ttyS0 on cloud images) then
  # powers off so qemu exits well before BOOT_TIMEOUT on success.
  local enroll_block=""
  if [[ -n "${STAGING_CP_URL:-}" && -n "${STAGING_ENROLL_TOKEN:-}" ]]; then
    enroll_block=$(cat <<ENR
  - path: /run/vacti/enroll.env
    permissions: "0600"
    content: |
      vacti_enroll_token=${STAGING_ENROLL_TOKEN}
      vacti_url=${STAGING_CP_URL}
ENR
)
  fi
  cat > "${sd}/user-data" <<CFG
#cloud-config
hostname: vacti-smoke
write_files:
${enroll_block}
  - path: /usr/local/sbin/vacti-smoke-probe
    permissions: "0755"
    content: |
      #!/usr/bin/env bash
      C=/dev/console
      echo "SMOKE_BOOT_REACHED" > \$C
      # Poll until systemd settles to a terminal state. This probe is launched
      # DETACHED via systemd-run (see runcmd), so it is NOT part of the boot
      # transaction; if it ran inside cloud-final, is-system-running would stay
      # 'starting' forever (cloud-final is itself an activating job). Under qemu
      # TCG the settle is slow, so poll up to ~240s instead of sampling once.
      state="starting"
      for _ in \$(seq 1 120); do
        state="\$(systemctl is-system-running 2>/dev/null || true)"
        case "\$state" in running|degraded) break ;; esac
        sleep 2
      done
      echo "SMOKE_SYSTEMD=\${state:-unknown}" > \$C
      for u in vacti-firstboot.service vacti-swap-firstboot.service earlyoom.service; do
        en="\$(systemctl is-enabled \$u 2>/dev/null || echo missing)"
        echo "SMOKE_UNIT \$u=\${en}" > \$C
      done
      # zram swap present? (zram-generator instantiates it at boot)
      if swapon --show=NAME --noheadings 2>/dev/null | grep -q zram || systemctl list-units 2>/dev/null | grep -q 'zram'; then
        echo "SMOKE_ZRAM=present" > \$C
      else
        echo "SMOKE_ZRAM=absent" > \$C
      fi
      if command -v vacti-engine >/dev/null 2>&1 || dpkg -l vacti-engine >/dev/null 2>&1; then
        echo "SMOKE_ENGINE=present" > \$C
      else
        echo "SMOKE_ENGINE=absent" > \$C
      fi
      # headless provisioning TUI present (the console twin of the GUI kiosk)?
      if [[ -x /usr/local/sbin/vacti-netsetup ]]; then
        echo "SMOKE_NETSETUP=present" > \$C
      else
        echo "SMOKE_NETSETUP=absent" > \$C
      fi
      # Network: poll briefly for a global IPv4 (user-net DHCP can lag the
      # systemd settle under TCG). Up to ~60s.
      net="down"
      for _ in \$(seq 1 30); do
        if ip -4 addr show scope global 2>/dev/null | grep -q 'inet '; then net="up"; break; fi
        sleep 2
      done
      echo "SMOKE_NET=\${net}" > \$C
      if [[ -f /etc/vacti-engine/engine.env ]]; then
        echo "SMOKE_ENROLL=ok" > \$C
      else
        echo "SMOKE_ENROLL=none" > \$C
      fi
      echo "SMOKE_RESULT=DONE" > \$C
      sync; sleep 2; systemctl poweroff -i 2>/dev/null || poweroff -f
runcmd:
  # Start the enroll unit non-blocking (it fails loudly token-less -> systemd
  # 'degraded', an accepted terminal state), then launch the probe as a DETACHED
  # transient unit so it is not part of the boot transaction and
  # is-system-running can actually reach running/degraded.
  - [ systemctl, start, --no-block, vacti-firstboot.service ]
  - [ systemd-run, --unit=vacti-smoke-probe, --collect, /usr/local/sbin/vacti-smoke-probe ]
CFG
  if command -v genisoimage >/dev/null 2>&1; then
    genisoimage -quiet -output "$out" -volid CIDATA -joliet -rock "${sd}/user-data" "${sd}/meta-data"
  elif command -v xorriso >/dev/null 2>&1; then
    xorriso -as mkisofs -quiet -o "$out" -V CIDATA -J -r "${sd}/user-data" "${sd}/meta-data"
  else
    echo "[smoke] need genisoimage or xorriso to build the NoCloud seed" >&2; exit 2
  fi
  echo "$out"
}

# --- turn any supported artifact into a bootable qcow2 -----------------------
to_qcow2() {
  local art="$1" out="$2"
  case "$art" in
    *.qcow2) cp -f "$art" "$out" ;;
    *.raw|*.img) qemu-img convert -O qcow2 "$art" "$out" ;;
    *.raw.gz) gzip -dc "$art" > "${out}.raw"; qemu-img convert -O qcow2 "${out}.raw" "$out"; rm -f "${out}.raw" ;;
    *.ova)
      local od; od="$(mktemp -d "${TMPROOT}/ova.XXXX")"
      # tar -C: $art may be a RELATIVE path, which a `cd "$od"` would break.
      tar -C "$od" -xf "$art"
      local vmdk; vmdk="$(find "$od" -maxdepth 1 -name '*.vmdk' | head -1)"
      [[ -n "$vmdk" ]] || { echo "[smoke] no vmdk in $art" >&2; return 1; }
      qemu-img convert -O qcow2 "$vmdk" "$out"; rm -rf "$od" ;;
    *) return 1 ;;
  esac
}

# --- disk-image smoke (qcow2/ova/raw): boot + cloud-init health probe --------
smoke_disk() {
  local art="$1" base; base="$(basename "$art")"
  say "disk smoke: ${base}"
  local disk="${TMPROOT}/boot.qcow2" log="${TMPROOT}/serial.log"
  : > "$log"
  if ! to_qcow2 "$art" "$disk"; then bad "${base}: could not prepare a bootable disk"; return; fi
  local seed; seed="$(build_seed)"
  say "${base}: booting in qemu (TCG, timeout ${BOOT_TIMEOUT}s)"
  # qemu64 CPU => no host virt needed. virtio disk/net to match genericcloud.
  timeout "${BOOT_TIMEOUT}" "$QEMU" \
      -cpu qemu64 -smp 2 -m "${SMOKE_MEM_MB}" \
      -drive file="${disk}",format=qcow2,if=virtio,snapshot=on \
      -drive file="${seed}",format=raw,if=virtio,readonly=on \
      -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
      -nographic -serial "file:${log}" -monitor none -display none \
      -no-reboot < /dev/null > /dev/null 2>&1 || true

  # The guest serial console emits CRLF, so every marker lands as "VALUE\r".
  # Strip the CR before parsing, or string compares fail ("up\r" != "up",
  # "enabled\r" misses the case arm, "starting\r" misses, etc.). This is the fix
  # for the disk-image smoke FPs: it makes the probe read the TRUE guest state,
  # it does NOT blind any check.
  if [[ -s "$log" ]]; then tr -d '\r' < "$log" > "${log}.nocr" && mv -f "${log}.nocr" "$log"; fi

  if ! grep -q 'SMOKE_RESULT=DONE' "$log"; then
    bad "${base}: health probe did not complete (no SMOKE_RESULT; boot hang or timeout)"
    say "--- last 40 serial lines (${base}) ---"; tail -40 "$log" >&2 || true
    return
  fi
  ok "${base}: reached cloud-init health probe"
  # systemd state: running (clean) or degraded (a non-blocking unit failed, e.g.
  # the token-less firstboot) are both acceptable; "failed"/offline are not.
  local st; st="$(sed -n 's/^SMOKE_SYSTEMD=//p' "$log" | tail -1)"
  case "$st" in
    running|degraded) ok "${base}: systemd state=${st}" ;;
    *) bad "${base}: systemd state=${st:-unknown} (expected running/degraded after settle)" ;;
  esac
  local net; net="$(sed -n 's/^SMOKE_NET=//p' "$log" | tail -1)"
  [[ "$net" == "up" ]] && ok "${base}: network up" || bad "${base}: network ${net:-unknown}"
  # required baked units present (enabled/static/alias are all "present")
  local u en
  for u in vacti-firstboot.service vacti-swap-firstboot.service earlyoom.service; do
    en="$(sed -n "s|^SMOKE_UNIT ${u}=||p" "$log" | tail -1)"
    case "$en" in
      enabled|enabled-runtime|static|alias|linked|indirect|generated) ok "${base}: unit ${u}=${en}" ;;
      *) bad "${base}: baked unit ${u} missing/not-installed (=${en:-?})" ;;
    esac
  done
  local zr; zr="$(sed -n 's/^SMOKE_ZRAM=//p' "$log" | tail -1)"
  [[ "$zr" == "present" ]] && ok "${base}: zram swap present" || say "${base}: zram=${zr:-?} (non-blocking)"
  local eng; eng="$(sed -n 's/^SMOKE_ENGINE=//p' "$log" | tail -1)"
  [[ "$eng" == "present" ]] && ok "${base}: vacti-engine present" || say "${base}: vacti-engine=${eng:-?} (non-blocking: runtime self-heal covers gaps)"
  # headless pre-login provisioning TUI must be baked (the console twin of the
  # GUI activation kiosk). Golden/cloud images are headless and ship vacti-netsetup.
  local ns; ns="$(sed -n 's/^SMOKE_NETSETUP=//p' "$log" | tail -1)"
  [[ "$ns" == "present" ]] && ok "${base}: vacti-netsetup (headless provisioning TUI) present" || bad "${base}: vacti-netsetup missing (=${ns:-?}) - headless pre-login provisioning path absent"
  # optional enroll roundtrip (only when staging secrets were provided)
  if [[ -n "${STAGING_CP_URL:-}" && -n "${STAGING_ENROLL_TOKEN:-}" ]]; then
    local er; er="$(sed -n 's/^SMOKE_ENROLL=//p' "$log" | tail -1)"
    [[ "$er" == "ok" ]] && ok "${base}: staging enroll roundtrip ok" || bad "${base}: staging enroll roundtrip failed (=${er:-?})"
  fi
}

# --- ISO smoke: boot-only, assert a login/live prompt appears ----------------
smoke_iso() {
  local art="$1" fw="${2:-bios}" base; base="$(basename "$art")"
  say "iso smoke (${fw}): ${base}"
  local log="${TMPROOT}/iso-${fw}.log"; : > "$log"
  local ovmf=""
  if [[ "$fw" == "uefi" ]]; then
    for c in /usr/share/OVMF/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd /usr/share/qemu/OVMF.fd; do
      [[ -f "$c" ]] && { ovmf="$c"; break; }
    done
    [[ -n "$ovmf" ]] || { say "${base}: no OVMF firmware found; skipping UEFI leg"; return; }
  fi
  # commas in `user,id=n0` are qemu option syntax, not array separators.
  # shellcheck disable=SC2054
  local args=( -cpu qemu64 -smp 2 -m "${SMOKE_MEM_MB}"
      -cdrom "$art" -boot d
      -netdev user,id=n0 -device virtio-net-pci,netdev=n0
      -nographic -serial "file:${log}" -monitor none -display none -no-reboot )
  [[ -n "$ovmf" ]] && args=( -bios "$ovmf" "${args[@]}" )
  # ISO boot never powers itself off; rely on a bounded watch for a prompt
  # marker. TCG boots a live-build squashfs slowly, so inherit the generous disk
  # budget unless ISO_WATCH overrides; the loop still breaks the instant a marker
  # appears (so a healthy ISO exits in minutes, not the full budget).
  local watch="${ISO_WATCH:-${BOOT_TIMEOUT}}"
  ( timeout "${watch}" "$QEMU" "${args[@]}" < /dev/null > /dev/null 2>&1 || true ) &
  local qpid=$!
  local waited=0 found=0
  while [[ "$waited" -lt "$watch" ]]; do
    if grep -qiE 'login:|vacti|live session|systemd\[1\]|reached target|Welcome to' "$log" 2>/dev/null; then found=1; break; fi
    kill -0 "$qpid" 2>/dev/null || break
    sleep 5; waited=$((waited+5))
  done
  kill "$qpid" 2>/dev/null || true; wait "$qpid" 2>/dev/null || true
  if [[ "$found" -eq 1 ]]; then ok "${base} (${fw}): reached a boot/login prompt"
  else bad "${base} (${fw}): no login/boot marker within ${watch}s"; tail -30 "$log" >&2 || true; fi
}

# --- GUI ISO pre-login gate smoke: verify the activation kiosk + fail-open -----
# Boots the GUI ISO with -vga none (no framebuffer/GPU). The vacti-activate
# kiosk's display pre-flight then fails DETERMINISTICALLY, which FORCES the
# fail-open path: the kiosk exits, systemd runs vacti-activate-fallback.service,
# which drops a getty so the box stays reachable. This exercises the REAL
# fail-open behavior (a display-less / broken-GPU box must never brick) with no
# contrived crash injection. Serial (console=ttyS0) carries the two gate markers
# plus the getty login prompt. Asserts (without weakening the boot check):
#   - the GUI boot REACHES the vacti-activate kiosk (not a bare login)
#   - fail-open engages (kiosk unavailable -> fallback getty)
#   - the box is reachable (a boot/login marker appears)
smoke_iso_gate() {
  local art="$1" base; base="$(basename "$art")"
  say "iso GATE smoke (gui, pre-login activation): ${base}"
  local log="${TMPROOT}/iso-gate.log"; : > "$log"
  # commas in `user,id=n0` are qemu option syntax, not array separators.
  # shellcheck disable=SC2054
  local args=( -cpu qemu64 -smp 2 -m "${SMOKE_MEM_MB}"
      -cdrom "$art" -boot d -vga none
      -netdev user,id=n0 -device virtio-net-pci,netdev=n0
      -nographic -serial "file:${log}" -monitor none -display none -no-reboot )
  local watch="${ISO_WATCH:-${BOOT_TIMEOUT}}"
  ( timeout "${watch}" "$QEMU" "${args[@]}" < /dev/null > /dev/null 2>&1 || true ) &
  local qpid=$!
  local waited=0 seen_kiosk=0 seen_fallback=0 seen_login=0
  while [[ "$waited" -lt "$watch" ]]; do
    if [[ -s "$log" ]]; then
      grep -q 'VACTI_ACTIVATE_KIOSK=start' "$log" 2>/dev/null && seen_kiosk=1
      grep -q 'VACTI_ACTIVATE_FALLBACK=' "$log" 2>/dev/null && seen_fallback=1
      grep -qiE 'login:|reached target|Welcome to|systemd\[1\]' "$log" 2>/dev/null && seen_login=1
    fi
    [[ "$seen_kiosk" -eq 1 && "$seen_fallback" -eq 1 && "$seen_login" -eq 1 ]] && break
    kill -0 "$qpid" 2>/dev/null || break
    sleep 5; waited=$((waited+5))
  done
  kill "$qpid" 2>/dev/null || true; wait "$qpid" 2>/dev/null || true
  if [[ -s "$log" ]]; then tr -d '\r' < "$log" > "${log}.nocr" && mv -f "${log}.nocr" "$log"; fi
  if [[ "$seen_kiosk" -eq 1 ]]; then ok "${base} (gui): reached the vacti-activate kiosk (pre-login gate, not a bare login)"
  else bad "${base} (gui): never reached the vacti-activate kiosk (no VACTI_ACTIVATE_KIOSK marker)"; tail -40 "$log" >&2 || true; fi
  if [[ "$seen_fallback" -eq 1 ]]; then ok "${base} (gui): FAIL-OPEN engaged (display-less kiosk -> fallback getty; box reachable)"
  else bad "${base} (gui): fail-open fallback did not engage (no VACTI_ACTIVATE_FALLBACK marker)"; tail -40 "$log" >&2 || true; fi
  if [[ "$seen_login" -eq 1 ]]; then ok "${base} (gui): box reachable (boot/login marker present)"
  else bad "${base} (gui): no boot/login marker within ${watch}s (box may be hung)"; fi
}

# --- discover + dispatch -----------------------------------------------------
declare -a TARGETS=()
for arg in "$@"; do
  if [[ -d "$arg" ]]; then
    while IFS= read -r f; do TARGETS+=("$f"); done < <(find "$arg" -type f \( -name '*.qcow2' -o -name '*.ova' -o -name '*.iso' \) ! -name '*golden*' | sort)
  else
    TARGETS+=("$arg")
  fi
done
[[ "${#TARGETS[@]}" -ge 1 ]] || { echo "[smoke] no bootable artifacts found in: $*" >&2; exit 2; }

for t in "${TARGETS[@]}"; do
  case "$t" in
    *.iso)
      # The GUI ISO additionally runs the pre-login activation GATE leg (kiosk +
      # fail-open); the headless ISO has no GUI kiosk, so it keeps bios+uefi boot.
      case "$(basename "$t")" in
        *gui*) smoke_iso_gate "$t"; smoke_iso "$t" uefi ;;
        *)     smoke_iso "$t" bios; smoke_iso "$t" uefi ;;
      esac
      ;;
    *.qcow2|*.ova|*.raw|*.raw.gz|*.img) smoke_disk "$t" ;;
    *) say "skipping unsupported artifact: $(basename "$t")" ;;
  esac
done

if [[ "$FAIL" -ne 0 ]]; then
  echo "[smoke] RESULT: FAIL - an image failed its boot/health smoke test." >&2
  exit 1
fi
say "RESULT: PASS - every image booted and passed its smoke assertions."
