# distro/branding - PLAN (Phase-1)

Branding assets applied by both drivers (`virt-customize --copy-in` for the golden image;
`includes.chroot/` + `includes.binary/` + a branding hook for the ISO). On a permissive Debian
base, branding is freely ours - no mark-stripping of an upstream, only a rename + no Debian logos +
a non-affiliation disclaimer.

## What lands here

- `os-release` - the overlay for `/etc/os-release` (`NAME` / `PRETTY_NAME` / `ID` / `HOME_URL` =
  the vacti product name), plus the non-affiliation disclaimer line.
- `issue` / `motd` - `/etc/issue` + `/etc/motd` with product name + non-affiliation disclaimer.
- `grub/` - GRUB theme + `splash.png` (goes to `includes.binary/boot/grub/`).
- `plymouth/` - the vacti Plymouth boot-splash theme (`plymouth-set-default-theme` wired by the
  branding hook).
- `wallpaper/` - desktop wallpaper for the GUI SKU (`/usr/share/backgrounds/vacti/`, defaulted via
  `/etc/skel`), and the LightDM greeter theme.
- `apply-branding.sh` - the hook body shared by the ISO `0100-branding.hook.chroot` and the golden
  image `virt-customize --run` step (sets Plymouth/GRUB defaults, `update-grub`).

## Non-affiliation disclaimer (required wording)

> vacti is a derivative based on Debian GNU/Linux; it is not produced by, endorsed by, or
> affiliated with the Debian Project. Debian is a trademark of Software in the Public Interest, Inc.

## Rules

- Ship **zero Debian logos / marks** in our branding; state non-affiliation and acknowledge SPI.
- No OffSec/Kali marks anywhere (Option A uses the Kali apt repo only as a package source, which
  puts no Kali branding in the image).
- Final product name + exact disclaimer wording are an operator decision (see the open questions in
  `docs/vacti-distro-iso-build.md` and `docs/vacti-distro-debian-replan.md`).
