# GRUB branding

Drop `splash.png` (640x480 or 1920x1080 PNG, no Debian marks) in this directory
and an optional GRUB theme under `theme/` (a `theme.txt` + assets). `apply-branding.sh`
installs `splash.png` to `/boot/grub/splash.png`, copies `theme/` to
`/boot/grub/themes/vacti/`, sets `GRUB_THEME`, and runs `update-grub`. For the ISO,
`config/includes.binary/boot/grub/splash.png` is the boot-menu splash.

Placeholder: no binary asset is committed (see `.gitignore` image-asset rules);
the operator supplies the final artwork before a release build.
