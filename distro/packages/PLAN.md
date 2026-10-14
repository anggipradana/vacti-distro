# distro/packages - PLAN (Phase-1)

The **arsenal package manifest** consumed by both build drivers: `virt-customize --install` for the
golden image, and `config/package-lists/vacti-core.list.chroot` for the ISO's `live-build` chroot.

## Source of truth

The engine-arsenal package set is **DERIVED from the engine's generated manifest**
`packaging/arsenal-manifest.json` (itself emitted from the one declarative module
`packaging/arsenal.env`). The manifest ships inside the `vacti-engine` .deb at
`/usr/lib/vacti-engine/packaging/arsenal-manifest.json`; a vendored snapshot lives beside the
generator as `arsenal-manifest.json`. `gen-live-build-list.sh` reads the manifest (installed .deb
first, vendored snapshot as fallback) and emits the arsenal set; the distro no longer transcribes
the engine's apt arrays. `ci/arsenal-sync-check.sh` FAILS the build on any drift between the
vendored snapshot / the generator and the engine manifest at the pinned `VACTI_ENGINE_REF`.

## What lands here

- `arsenal-manifest.json` - the vendored snapshot of the engine manifest (the ENGINE-ARSENAL
  source of truth: `apt.core` + `apt.verticals.*` + `apt.ctf` + the pipx/npm/dotnet `tools`). Kept
  in sync with the engine by `ci/arsenal-sync-check.sh`; never hand-edited.
- `distro-owned.list` - the NON-arsenal base the distro owns (Chromium shared-lib closure, anti-OOM
  backstops, `fastfetch` banner, `sslscan`/`testssl.sh`, `wget`/`python3-full`/`netcat-openbsd`).
  The GUI desktop set (XFCE / Calamares / Plymouth / LightDM / whisker) lives in the ISO's
  `vacti-gui.list.chroot.in`.
- `manifest.yml` - documentation-of-record / pointer to the engine manifest.
- `gen-live-build-list.sh` - emits `vacti-core.list.chroot` (and the OVA `arsenal.list`) by
  deriving the arsenal half from the manifest and appending `distro-owned.list`.
- `kali-repo/` - the Option A Kali apt source line + pin (priority 100) as a **package source** for
  the ~6 tools absent from Debian `main` (nuclei, httpx, naabu, feroxbuster, seclists, commix);
  flip `VACTI_NO_KALI_REPO=1` for the Option B fully-Kali-free path (seclists via `git clone
  SecLists`, feroxbuster via GitHub release, commix via git).

## Notes

- Baked default = lean `web,infra` (smallest image); a heavier SKU can bake a wider capability set.
- The one CORE Debian-missing item needing care is **seclists** (weak `dirb` fallback) - a CI
  assertion must confirm a content-discovery wordlist resolves on the built image.
