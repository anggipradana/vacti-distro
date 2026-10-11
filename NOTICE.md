# NOTICE

## Scope of the MIT license

The [MIT LICENSE](LICENSE) in this repository covers **our own build sources only** - the scripts,
configuration trees, branding assets, Makefile, and CI in this repo. It does **not** cover the
contents of any built image.

## The built image contains third-party components under their own licenses

An image produced from these sources (cloud qcow2/raw, installable ISO, VMware OVA, VirtualBox OVA)
bundles:

- **Debian GNU/Linux** base packages, under their respective licenses (the majority GPL / LGPL,
  plus BSD / MIT / and others per package). Debian is a trademark of **Software in the Public
  Interest, Inc. (SPI)**.
- **The pentest arsenal** (nmap, sqlmap, nuclei, ffuf, gobuster, dirsearch, feroxbuster, and the
  rest) and supporting tools, each under its own upstream license (predominantly GPL / BSD / MIT;
  a few components, such as commercial proxy tooling, carry their own redistribution terms).
- **Guest integration tooling** - `open-vm-tools` (GPL / BSD, Debian `main`) and
  `virtualbox-guest-utils` (GPLv2, Debian `contrib`). The PUEL-licensed VirtualBox Extension Pack is
  **not** bundled.
- **The vacti engine**, which remains proprietary to its owner and is **not** licensed under the MIT
  license above. The MIT grant does not extend to the engine `.deb`, its obfuscated `dist`, or the
  server-side methodology.

Build-time-only tools such as VMware `ovftool` are used under their own EULAs and are **never**
redistributed in or alongside an image.

## GPL source offer (by reference)

The built image redistributes **unmodified** Debian binary packages. The corresponding source for
every GPL / LGPL package is available from Debian's own public source infrastructure:

- `deb-src` archive entries for the pinned Debian release, and
- the Debian source mirrors / `snapshot.debian.org`.

This NOTICE serves as the written offer of source by reference to those mirrors. If a future build
**modifies** any GPL / LGPL package, the corresponding modified source for that package will be
hosted alongside the image rather than offered by reference.

## Public distribution is pending review

Public distribution of any built image is **pending**, and gated on:

1. A **per-package non-free / contrib license audit** - confirming every component outside Debian
   `main` (and any commercial tool) permits redistribution in a derivative image; and
2. A **Debian non-affiliation review** - a rename with no Debian logos in our branding, a
   non-affiliation disclaimer ("vacti is a derivative based on Debian GNU/Linux; it is not produced
   by, endorsed by, or affiliated with the Debian Project."), and an acknowledgement of SPI's
   ownership of the Debian mark, with the wording legally reviewed before any public release.

Until both land, images are internal / fleet infrastructure only.
