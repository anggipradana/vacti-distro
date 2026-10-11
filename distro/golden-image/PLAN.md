# distro/golden-image - PLAN (Phase-1)

The golden-image is the **single source of truth** for the cloud and VM forms. Build it once with
`virt-customize` against the official Debian cloud image, then repackage it into every target
format (the convert fan-out). This keeps cloud / VMware OVA / VirtualBox OVA bit-identical.

## What lands here (Phase-1)

- `build-golden.sh` - the `virt-customize` driver:
  1. `curl` the official `debian-13-genericcloud-amd64.qcow2` (+ arm64) and **verify against
     `SHA512SUMS`**.
  2. `virt-customize -a <qcow2>` to apply **the shared appliance layer**:
     - add the vacti private apt source + `auth.conf` (build-time only; removed before finalize),
     - `apt-get install vacti-engine` (pulls the arsenal; Option A also drops in the Kali apt
       source so Kali-packaged tools resolve),
     - install the tailscale client + the scoped NOPASSWD sudoers / systemd units / OOM hardening
       the engine postinst already writes,
     - install `open-vm-tools` + `virtualbox-guest-utils` (both coexist in one rootfs),
     - install the cloud-init / NoCloud firstboot unit (from `distro/enroll/`),
     - apply branding (from `distro/branding/`),
     - **zero identity**: truncate `/etc/machine-id`, remove `ssh_host_*`, clean apt lists.
  3. Emit `vacti-engine-<ver>-golden.qcow2`.
- `convert-cloud.sh` - `qemu-img convert` golden -> cloud `qcow2` (keep) + `raw.gz`.
- `convert-vmware-ova.sh` - `qemu-img -O vmdk subformat=streamOptimized,adapter_type=lsilogic`,
  then a hand-authored OVF (`VirtualSystemType=vmx-13`, LSI Logic SCSI) + `.mf` (SHA256) + `tar`
  (`.ovf`, `.mf`, `.vmdk` in order) -> `.ova`.
- `convert-vbox-ova.sh` - `qemu-img -O vmdk` (or `-O vdi`), then a hand-authored OVF
  (`VirtualSystemType=virtualbox-2.2`, SATA/IDE) + `.mf` + `tar` -> `.ova`. (`VBoxManage export
  --ovf10` is the dev-box alternative.)
- `ovf-templates/` - the `vmx-13` and `virtualbox-2.2` OVF descriptor templates.

## Rules

- Open-source tools only in CI (`virt-customize`, `qemu-img`, `genisoimage`, `tar`);
  `ovftool` / `VBoxManage` are dev-box-only.
- **No baked secret** ever reaches the golden disk. Build-time apt creds live only in the build
  chroot and are removed before the disk is finalized.
- The package set, config overlay, branding, and firstboot unit are consumed from the shared
  `distro/` tree - identical inputs to the ISO's `live-build` chroot.
