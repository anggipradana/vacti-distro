# GRUB branding

`splash.png` (1920x1080, rendered from `vacti-grub-1920x1080.svg`) is the boot-menu background, and
`theme/` holds the brand GRUB theme (`theme.txt` + `background.png`). `apply-branding.sh` installs
`splash.png` to `/boot/grub/splash.png`, copies `theme/` to `/boot/grub/themes/vacti/`, sets
`GRUB_THEME` (plus `GRUB_GFXMODE=auto` and `GRUB_TIMEOUT_STYLE=menu`), and runs `update-grub`. For
the ISO, `config/includes.binary/boot/grub/splash.png` is the boot-menu splash (staged by
`build-iso.sh`).

Re-render from the SVG source with `../render-assets.sh`. No Debian marks.
