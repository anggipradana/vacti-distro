# Desktop wallpaper (GUI SKU)

`vacti-wallpaper-1920x1080.png` and `vacti-wallpaper-2560x1440.png` are the brand wallpapers
(rendered from the `.svg` sources here: radar-shield lockup + mono tagline on the navy canvas).
`apply-branding.sh` stages them to `/usr/share/backgrounds/vacti/`. The XFCE skel sets the wallpaper
on every connected monitor at login via `/usr/local/bin/vacti-set-wallpaper` (adapts to any display
layout), and the LightDM greeter uses the `greeter/` background.

Re-render from the SVG sources with `../render-assets.sh`. No Debian marks.
