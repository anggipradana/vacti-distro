# Plymouth boot-splash theme

`vacti/` holds the Plymouth theme (a `vacti.plymouth` descriptor + a script +
artwork). `apply-branding.sh` copies it to `/usr/share/plymouth/themes/vacti`,
runs `plymouth-set-default-theme vacti`, and rebuilds the initramfs. Headless
images have no Plymouth and skip this cleanly.

Placeholder: the `.plymouth` descriptor below is a stub; final artwork is supplied
before a release build.
