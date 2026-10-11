# distro/live-build-config - PLAN (Phase-2, scaffolded in Phase-1)

The Debian `live-build` config tree that produces the installable/live **ISO**. It consumes the
**same** package manifest, config overlay, and branding assets as the golden image (one source of
truth), so the ISO's installed rootfs matches the cloud/VM forms.

## What lands here

- `auto/config` - committed, reproducible `lb config`:
  `--distribution trixie --archive-areas "main contrib non-free non-free-firmware"
   --architectures amd64 --binary-images iso-hybrid` (BIOS + UEFI, dd-able to USB),
  `--bootappend-live "boot=live components quiet splash"`, iso application/publisher/volume = vacti.
- `config/package-lists/`:
  - `vacti-core.list.chroot` - engine + full arsenal (generated from `distro/packages/`),
  - `vacti-gui.list.chroot` - GUI SKU only: `xfce4 lightdm calamares calamares-settings-debian ...`.
- `config/archives/` - the private apt **source line + signing key** (public info; NOT the creds).
- `config/includes.chroot/` - the config overlay (same tree as the golden image overlay):
  `/etc/os-release`, `/etc/vacti-engine/` (no secrets), the first-run enroll service, GUI skel.
- `config/includes.binary/boot/grub/splash.png` - GRUB boot splash branding.
- `config/hooks/normal/`:
  - `0100-branding.hook.chroot` - plymouth/GRUB defaults, `update-grub`,
  - `0200-strip-identity.hook.chroot` - truncate machine-id, remove SSH host keys,
  - a late hook that removes the build-time apt `auth.conf` before squashfs.
- `calamares/` overlay - `settings.conf`, `modules/`, `branding/vacti/` for the GUI install-to-disk.
- `preseed/preseed.cfg` - headless SKU unattended debian-installer (partitioning, vacti user,
  late_command drops the first-run enroll service).

## SKUs (one tree, two profiles)

- **GUI** - XFCE + LightDM + Calamares install-to-disk.
- **headless** - no DE, debian-installer preseed; the engine's xvfb screenshot stack only.

## Rules

- Build host / CI: a Debian 13 trixie box or a `debian:trixie` `--privileged` container (loop
  devices). No Kali-only runner required.
- The build-time apt credential is injected into the build chroot and removed by a late hook; it
  **never** reaches the shipped rootfs. No baked enroll/engine token, no `.claude` on disk.
