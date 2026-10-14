# Plymouth boot-splash theme

`vacti/` holds the Plymouth theme: a `vacti.plymouth` descriptor, the `vacti.script` animation
(navy background, centered radar-shield lockup, a thin accent progress bar, LUKS/sudo password
prompt), and the artwork (`background.png`, `logo.png`, `progress_box.png`, `progress_bar.png`).
`apply-branding.sh` copies it to `/usr/share/plymouth/themes/vacti`, runs
`plymouth-set-default-theme vacti`, and rebuilds the initramfs. The GUI SKU installs `plymouth` +
`plymouth-themes`; headless images have no Plymouth and skip this cleanly.

The theme is intentionally lightweight (one static background image plus a progress bar, no GPU
effects) so it renders in a plain framebuffer on any hardware. Re-render the artwork from the `.svg`
sources with `../render-assets.sh`.
