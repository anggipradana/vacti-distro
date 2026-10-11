# distro/packages - PLAN (Phase-1)

The **arsenal package manifest** consumed by both build drivers: `virt-customize --install` for the
golden image, and `config/package-lists/vacti-core.list.chroot` for the ISO's `live-build` chroot.

## Source of truth

The package set is **sourced from the engine's `packaging/bootstrap-apt.sh`** (`APT_PACKAGES` +
`APT_PKGS_*` per-vertical sets), cross-checked against `src/runner/arsenal-check.ts`
(`REQUIRED_TOOLS`, `TOOL_APT_PACKAGES`, `TOOL_GO_PACKAGES`). Do not hand-maintain a divergent list;
regenerate this manifest from the engine bootstrap so the image arsenal always matches what the
runtime asserts and self-heals against.

## What lands here

- `manifest.yml` (or `.env`) - the canonical package set + capability gating:
  - **CORE (baked on every image):** `nmap nuclei httpx-toolkit naabu subfinder ffuf gobuster
    dirsearch sqlmap weevely whatweb commix dnsx katana trufflehog feroxbuster` + wordlists
    `seclists dirb` + base/runtime (`nftables jq curl git build-essential ca-certificates xvfb
    fonts-noto* pipx golang-go ripgrep fd-find default-mysql-client openssh-server socat binutils
    python3-venv default-jre-headless unzip`) + VPN clients (`openconnect
    globalprotect-openconnect openfortivpn openvpn wireguard-tools strongswan strongswan-swanctl`)
    + screenshot/evidence (`imagemagick xdotool x11-xserver-utils qterminal sshpass tmux`).
  - **Pinned Chromium:** `vacti-engine-chromium` (build 1228) from the vacti repo, not Debian's, to
    match Playwright.
  - **Per-vertical, capability-gated** (install only when the image's baked `ENGINE_CAPABILITIES`
    advertises the vertical; else fetched post-boot by the runtime self-heal via the
    `vacti-engine-arsenal-apt` NOPASSWD grant): mobile / iOS / RE / source / AD / cloud sets.
- `gen-live-build-list.sh` - emits `vacti-core.list.chroot` from `manifest.yml`.
- `kali-repo/` - the Option A Kali apt source line + pin (priority 100) as a **package source** for
  the ~6 tools absent from Debian `main` (nuclei, httpx, naabu, feroxbuster, seclists, commix);
  flip `VACTI_NO_KALI_REPO=1` for the Option B fully-Kali-free path (seclists via `git clone
  SecLists`, feroxbuster via GitHub release, commix via git).

## Notes

- Baked default = lean `web,infra` (smallest image); a heavier SKU can bake a wider capability set.
- The one CORE Debian-missing item needing care is **seclists** (weak `dirb` fallback) - a CI
  assertion must confirm a content-discovery wordlist resolves on the built image.
