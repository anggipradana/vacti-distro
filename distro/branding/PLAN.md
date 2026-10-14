# distro/branding - Vacti OS brand layer

Branding assets applied by both drivers (`virt-customize --copy-in` for the golden image;
`includes.chroot/` + `includes.binary/` + a branding hook for the ISO). On a permissive Debian
base, branding is freely ours: a rename, no Debian logos, and a non-affiliation disclaimer.

## The vacti brand (real, not invented)

Extracted from the control-plane product (`apps/web/public/logo.svg` + the `globals.css` design
tokens):

- Logomark: a radar-shield (navy shield, cyan radar sweep, white pings, a red target blip). The
  committed `logo/svg/vacti-logomark.svg` is the product logomark verbatim.
- Wordmark: `vacti` set in Plus Jakarta Sans ExtraBold (the product display font), baked to vector
  paths so the SVG sources rasterize with any renderer and need no fonts.
- Palette: shield `#1F5BD6`..`#0E347E`, accent blue `#1E66E3`, radar cyan `#37B6FF`, alert red
  `#FF5A5A`, canvas navy `#0B1324`..`#070D1A`, light fg `#EEF2F8`, muted `#9FB0C6`. Mono = IBM Plex
  Mono.

## What lands here

- `os-release` - overlay for `/etc/os-release` (`NAME="Vacti OS"`, `ID=vacti`, `ID_LIKE=debian`,
  `LOGO=vacti`, `ANSI_COLOR`), plus the non-affiliation `VARIANT`.
- `issue` / `issue.net` / `motd` - console identity + the static MOTD fallback.
- `console/` - the dynamic MOTD: `vacti-motd` (generator) + `vacti-motd.service` (regenerates
  `/etc/motd` at boot with host/IP/enrollment), the half-block `motd-wordmark.ansi`, and the
  truecolor `fastfetch-logo.ansi`.
- `fastfetch/config.jsonc` - branded `fastfetch` over SSH (skel + root).
- `profile.d/vacti-ps1.sh` - a subtle brand PS1 for interactive login shells.
- `logo/` - the vector sources (`svg/`) + rendered rasters (`png/`): logomark, square icon, and the
  horizontal + stacked lockups.
- `wallpaper/` - desktop wallpaper at 1920x1080 and 2560x1440 (GUI SKU).
- `greeter/` - the LightDM greeter background + `lightdm-gtk-greeter.conf` (GUI SKU).
- `grub/` - `splash.png` + a brand GRUB `theme/` (background + readable menu + accent countdown).
- `plymouth/vacti/` - the Plymouth boot splash theme (navy background, centered logo, accent
  progress bar) + its artwork.
- `xfce/` - skel defaults: dark GTK theme (`xsettings.xml`), the whisker-menu panel
  (`xfce4-panel.xml`, button icon `vacti`), and a login-time wallpaper setter that adapts to any
  monitor layout.
- `apply-branding.sh` - the hook body shared by the ISO `0100-branding.hook.chroot` and the golden
  image `virt-customize --run` step. Idempotent and best-effort (GUI-only pieces skip on headless).
- `render-assets.sh` - regenerate every raster from its committed SVG source (rsvg-convert /
  inkscape / cairosvg auto-detected). Developer/CI helper, not part of the image build.

## Where each piece bakes (both SKUs)

- Boot (GUI + golden): GRUB theme + Plymouth splash.
- Desktop (GUI SKU): wallpaper, LightDM greeter, dark GTK theme, whisker-menu icon, panel,
  Calamares branding.
- Console (headless + GUI + golden): os-release, issue/issue.net, dynamic MOTD, fastfetch, PS1.

## Non-affiliation disclaimer (required wording)

> Vacti OS is a derivative based on Debian GNU/Linux; it is not produced by, endorsed by, or
> affiliated with the Debian Project. Debian is a trademark of Software in the Public Interest, Inc.

## Rules

- Ship zero Debian logos / marks in our branding; state non-affiliation and acknowledge SPI.
- No OffSec/Kali marks anywhere (Option A uses the Kali apt repo only as a package source).
- `HOME_URL` / `SUPPORT_URL` stay the operator-set placeholder until the final product URL is
  decided.
