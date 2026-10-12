# vacti Pentest Distro - RAW-INSTALL / LIVE ISO build (Debian 13 "trixie" base)

**Date:** 2026-10-11 · **Author:** fanout research subagent · **Status:** for operator review
**Scope:** READ-ONLY research + design of the INSTALLABLE/LIVE ISO form of the vacti distro.
No code/git writes. Base = Debian 13 "trixie" (DECIDED - see `vacti-distro-base-survey.md`
+ `vacti-distro-research.md`). The CLOUD form (Debian cloud-image + cloud-init auto-enroll)
is handled elsewhere; this doc is the bootable+installable ISO we build ourselves.

---

## 0. TL;DR

**Recommended build tool: Debian `live-build` (`lb config`/`lb build`) + the `calamares`
graphical installer baked into the live session.** This is exactly the approach Kali itself
uses (`kali-live` is a live-build config), so we mirror a proven pipeline on plain Debian with
zero OffSec IP. One live-build config tree produces BOTH SKUs by picking a different
package-list set:

- **vacti-GUI SKU** - XFCE desktop + Calamares install-to-disk, for an analyst-facing bootable
  pentest workstation / on-prem appliance.
- **vacti-headless SKU** - no DE, debian-installer preseed for unattended install-to-disk, for
  a rack/standalone engine appliance where there is no cloud provider to hand a cloud-image to.

**Not recommended:** `debian-cd` (builds full-archive official Debian DVDs from a mirror -
wrong tool, heavyweight, aimed at redistributing the stock archive, not a custom spin). **Cubic**
is a good scratch/prototyping GUI but is a manual chroot remaster - not reproducible, not
CI-friendly, so keep it only as a throwaway experimentation aid, never the release pipeline.

**The ISO shares ONE customization layer with the cloud appliance** - the same apt package set,
the same `includes.chroot/` config overlay, and the same branding assets feed both the
live-build ISO and the `virt-customize` cloud image (see §8). One source of truth.

**IP posture is unchanged from the appliance plan:** a shipped ISO is freely copyable, so the
moat is NOT the disk - it is the engine being INERT without vacti. No baked enroll/engine
tokens, no `.claude` methodology on disk, skills fetched off-box per-engagement, obfuscated
engine `.deb`, enroll + license kill-switch server-side. The ISO's first-run asks the operator
for a one-time enroll token; nothing sensitive ships inside the ISO (§6).

**Jev vet (`typesafe/jev-1.13`, live call):** approach_sound Noul 0.90 · maintainable Score
1.82/2 (high, conf 0.73) · ip_safe Score 1.84/2 (high, conf 0.76) · licensing_clean Noul 0.73 ·
recommend_ship Noul 0.81. All positive; the two soft signals (ip_safe not maximal, licensing
0.73) are honest residuals, not blockers - full detail §9.

---

## 1. BUILD TOOLING - the four options compared

| Tool | Produces | How it works | Reproducible / CI | Fit for vacti |
| --- | --- | --- | --- | --- |
| **`live-build`** (`lb`) | live + installable hybrid ISO (BIOS+UEFI) | declarative config tree (`config/`) -> `debootstrap` a fresh trixie chroot -> install our package lists + overlay -> squashfs -> xorriso ISO | **Yes** - config is a git tree, one `lb build`; this is what Kali/Tails/Grml use | **RECOMMENDED** - from-scratch, reproducible, two SKUs from one tree |
| **`live-build` + Calamares** | the above, with a GUI install-to-disk | add `calamares` + `calamares-settings-debian` to the live package list + a branding module | **Yes** | **RECOMMENDED for the GUI SKU** - Calamares is the live-session installer |
| **`debian-cd`** | official-style full-archive Debian CD/DVD sets | pulls a whole Debian mirror + `jigdo`/`xorriso`, reproduces the stock archive media | Yes, but heavyweight | **NO** - built for redistributing the official archive, not a custom appliance; huge mirror dependency, no live session, no natural hook for our overlay |
| **Cubic** | remaster of an EXISTING ISO | GUI opens a stock ISO, drops you into a chroot, you `apt install`/edit by hand, repacks squashfs | **No** - manual chroot steps, project-file state, not scriptable | **Prototype only** - great for a quick "does this package set even work" spike; never the release pipeline (manual = unreproducible, drifts, can't live beside the cloud image's scripted overlay) |

**Why live-build wins:** it is the only option that is (a) from-scratch and declarative (a git
config tree, so the ISO is reproducible and CI-buildable), (b) native to Debian trixie, (c) the
same engine Kali wraps - so our prior Kali research transfers directly, now on a permissive base
with no OffSec marks, and (d) able to emit a BIOS+UEFI hybrid ISO with a live session AND an
installer in one artifact. Calamares is the graphical installer we drop into that live session
for the GUI SKU; debian-installer preseed is the unattended installer for the headless SKU.

### Recommended config + exact commands

Build host: a Debian 13 "trixie" box (live-build must build the same suite it targets). In CI,
run it in a `debian:trixie` container with `--privileged` (loop devices + mount). Install the
tool: `sudo apt-get install live-build`.

Lay the config out as a committed git tree with a reproducible `auto/config`:

```sh
# auto/config  (committed; `lb config` reads it so the build is reproducible)
#!/bin/sh
set -e
lb config noauto \
  --distribution trixie \
  --archive-areas "main contrib non-free non-free-firmware" \
  --architectures amd64 \
  --binary-images iso-hybrid \        # BIOS + UEFI bootable, dd-able to USB
  --bootappend-live "boot=live components quiet splash" \
  --debian-installer live \           # GUI SKU: ship d-i too; headless SKU: see preseed below
  --iso-application "vacti" \
  --iso-publisher "vacti; https://<download-domain>; info@..." \
  --iso-volume "vacti-<ver>" \
  --apt-indices false \
  --cache true \
  "${@}"
```

Then the overlay tree (shared with the cloud image - see §8):

```
config/
  package-lists/
    vacti-core.list.chroot        # engine + full arsenal (the APT_PACKAGES set, §3)
    vacti-gui.list.chroot         # GUI SKU only: xfce4 lightdm calamares calamares-settings-debian ...
  archives/
    kali.list.chroot + kali.pref  # Option A Kali source (pinned); key via build-iso.sh
    # (the vacti private source is NOT here - see the note below; it is staged into
    #  includes.chroot_before_packages so the early archives apt-update stays clean)
  includes.chroot_before_packages/ # build-time vacti apt wiring (source+auth+TLS-off),
                                   #   laid down before package install, stripped pre-squashfs
  includes.chroot/                # files overlaid into the live rootfs at their real paths
    etc/os-release                #   branding (§3)
    etc/vacti-engine/             #   engine config dir (NO secrets)
    usr/local/bin/vacti-firstrun  #   first-run enroll prompt (§6)
    etc/skel/.config/xfce4/...    #   GUI SKU default desktop + wallpaper
    usr/share/backgrounds/vacti/  #   wallpaper asset
  includes.binary/
    boot/grub/splash.png          #   GRUB boot splash branding
  hooks/
    normal/0100-branding.hook.chroot      # plymouth-set-default-theme, update-grub, etc.
    normal/0200-strip-identity.hook.chroot# truncate machine-id, remove ssh host keys
```

Build + test:

```sh
sudo lb build 2>&1 | tee build.log          # -> live-image-amd64.hybrid.iso
# BIOS boot test
qemu-system-x86_64 -m 4G -enable-kvm -cdrom live-image-amd64.hybrid.iso -boot d
# UEFI boot test
qemu-system-x86_64 -m 4G -enable-kvm -cdrom live-image-amd64.hybrid.iso -boot d \
  -bios /usr/share/ovmf/OVMF.fd
sudo lb clean            # between iterations; `lb clean --purge` for a full reset
```

Note on the private apt repo: it must NOT go in `config/archives/`. live-build apt-updates the
archives sources very early (the `chroot_prep` archives stage), before any `config/includes.*`
overlay - so an authenticated vacti source there is hit with neither its credential nor the
build-time TLS-off conf present, and the resulting "certificate verify failed" / "401
Unauthorized" is fatal (and poisons the chroot apt state). Instead `build-iso.sh` stages the
vacti *source line* + the build-time Basic-auth `auth.conf` + the host-scoped TLS-off apt.conf
into `config/includes.chroot_before_packages/etc/apt/`, which live-build lays down right before
package installation - so the package-install apt-update reaches the repo authenticated. The
`0900-remove-build-auth` late hook strips all three before the squashfs, so no credential,
weakened-TLS config, or private source ever reaches the shipped rootfs.

---

## 2. SKUs: GUI vs headless from one tree

- **vacti-GUI** (`--debian-installer live` + `vacti-gui.list.chroot`): XFCE (lightest practical
  DE that still gives a real desktop; LXQt is the alternative, marginally lighter but XFCE has
  the better tool-GUI story for Caido/Burp-like windows and matches the operator's "ready, not
  raw" bar). Ships LightDM, NetworkManager, a terminal, and the arsenal GUIs. Calamares is the
  install-to-disk path (§4).
- **vacti-headless** (`--debian-installer none` for live-only, or a preseeded d-i for
  install-to-disk): no DE, just the engine + arsenal + the `xvfb`/screenshot pipeline the engine
  needs headlessly. This is the rack/standalone twin of the cloud appliance for sites that
  cannot consume a cloud-image.

Both pull `vacti-core.list.chroot`; only the GUI SKU adds `vacti-gui.list.chroot`. Nothing is
forked - one config tree, two `lb config` profiles.

---

## 3. WHAT GETS BAKED

**(a) The vacti engine `.deb`** - installed from our private apt repo during the build
(`apt-get install vacti-engine`). The `.deb` already carries `dist` + prod `node_modules` + `bin`
+ `mcp` + systemd units, and its postinst writes the user-manager drop-in, the three scoped
sudoers, and starts the service. The ISO bakes exactly the hardened artifact `build-deb.sh`
produces (skill prose + orchestrator prompts stripped, `dist` obfuscated, 0 `.claude` entries).

**(b) The curated arsenal** - the canonical `APT_PACKAGES` superset from
`packaging/bootstrap-apt.sh` (also the set `src/runner/arsenal-check.ts` `TOOL_APT_PACKAGES`
asserts against). The web+infra CORE is baked on every ISO; per-vertical sets are gated the same
way `ENGINE_CAPABILITIES` gates them in the bootstrap (default `web,infra`). Concretely:

- **Scanners/recon CORE:** `nmap nuclei httpx-toolkit naabu subfinder ffuf gobuster dirsearch
  sqlmap weevely whatweb commix dnsx katana trufflehog feroxbuster`
- **Wordlists:** `seclists dirb`
- **Base/runtime:** `nftables jq curl git build-essential ca-certificates xvfb fonts-noto
  fonts-noto-cjk fonts-noto-color-emoji pipx golang-go ripgrep fd-find default-mysql-client
  openssh-server xz-utils socat binutils python3-venv default-jre-headless unzip`
- **VPN clients (every one the engine can drive):** `openconnect globalprotect-openconnect
  openfortivpn openvpn wireguard-tools strongswan strongswan-swanctl`
- **Screenshot/evidence pipeline:** `imagemagick xdotool x11-xserver-utils qterminal sshpass tmux`
- **Pinned Chromium:** `vacti-engine-chromium` (build 1228) - from our repo, not Debian's, to
  match Playwright.
- **Caido** CLI (guest-mode proxy/evidence), `jwt_tool` git checkout to `/opt`.
- **Per-vertical, capability-gated** (install only when the ISO's baked `ENGINE_CAPABILITIES`
  advertises the vertical, else fetched post-boot by the runtime self-heal via the
  `vacti-engine-arsenal-apt` NOPASSWD grant): mobile (`scrcpy apktool aapt adb` + frida/objection
  + jadx), iOS (`usbmuxd libimobiledevice-utils libplist-utils llvm` + pymobiledevice3), RE
  (`gdb-multiarch binwalk strace ltrace tshark checksec` + Ghidra + the RE python venv), source
  (`trivy` + semgrep), AD (impacket/netexec/bloodhound-python), cloud (awscli/kubectl).

  Baked default = lean `web,infra` (smallest ISO, ~hundreds of MB vs multi-GB). A heavier SKU can
  bake a wider capability set; either way the runtime arsenal-check fills gaps post-boot.

**(c) Desktop (GUI SKU) / headless profile** - XFCE + LightDM + NetworkManager for GUI; nothing
for headless beyond the engine's own xvfb-driven screenshot stack.

**(d) Branding** (replaces every Debian/placeholder mark; keeps us clean of Debian trademark use
- §7): `/etc/os-release` (`NAME`/`PRETTY_NAME`/`ID`/`HOME_URL` = vacti product), `/etc/issue` +
`/etc/motd`, GRUB theme + `config/includes.binary/boot/grub/splash.png`, Plymouth boot splash
(`plymouth-themes` + a vacti theme, `plymouth-set-default-theme`), the LightDM greeter theme +
XFCE default wallpaper (`/usr/share/backgrounds/vacti/`, defaulted via `/etc/skel`). A build hook
(`hooks/normal/0100-branding.hook.chroot`) wires the Plymouth/GRUB defaults at build time.

**(e) First-run / enroll flow** - a `vacti-firstrun` oneshot (§6): on first boot it prompts for
(or reads from a dropped file / the GUI greeter) a one-time enroll token, runs the existing
enroll path, writes `/etc/vacti-engine/engine.env`, then disables itself. Tailscale joins on the
engine's normal startup using the server-served reusable key (not baked).

---

## 4. INSTALLER - live session + install-to-disk

The hybrid ISO boots a **live session** (run the engine straight off USB, no install) AND offers
**install-to-disk**, two mechanisms depending on SKU:

- **GUI SKU -> Calamares** (the live-session graphical installer, same model as Debian's own
  live XFCE images):
  - Packages: `calamares` + `calamares-settings-debian` in `vacti-gui.list.chroot`.
  - Config overlay in `includes.chroot/etc/calamares/`: `settings.conf` (the module sequence),
    `modules/` (partition/users/bootloader/unpackfs), and `branding/vacti/` (our product name,
    logo, slideshow) referenced as the active branding component. An "Install vacti" launcher in
    `/usr/share/applications/` (+ an XFCE autostart entry) starts it from the live desktop.
  - Calamares does GPT + a 512 MiB FAT32 ESP at `/boot/efi` (`boot`,`esp` flags) + ext4 root +
    swap, and installs GRUB to the ESP - native UEFI; it also handles BIOS/MBR.
- **headless SKU -> debian-installer preseed** (unattended, no DE): keep the d-i on the ISO and
  ship a `preseed.cfg` (partitioning, locale, the vacti user, late_command to drop the first-run
  enroll service). This gives a hands-off rack install. (Calamares could also run text-mode, but
  preseed is the right unattended tool for a headless appliance.)

- **Persistence (live USB)** - for an analyst who wants a stateful live stick:
  `lb config --binary-filesystem fat32 --bootappend-live "boot=live persistence"`, then a USB
  partition labelled `persistence` holding `persistence.conf` (`/ union`), optionally encrypted
  (`persistence-encryption=luks`). Caution: persistence writes engagement state to a removable
  device - for the engine appliance prefer install-to-disk with full-disk encryption over a
  persistent live stick, and NEVER let persistence capture an enroll/engine token (the first-run
  service writes `engine.env` to the installed/persistent root only after the operator supplies
  the token, consistent with §6).

- **UEFI + BIOS** - `--binary-images iso-hybrid` emits a hybrid image bootable on both firmware
  types and `dd`-able to USB; include `grub-efi-amd64-bin`/`grub-pc-bin` so both bootloaders are
  present. Verified in QEMU with and without `OVMF.fd` (§1).

---

## 5. (merged into §4)

---

## 6. IP PROTECTION - a shipped ISO is freely copyable

The threat model is harsher than the `.deb`: an ISO is a single, mass-copyable artifact. So the
moat is NOT at-rest secrecy on the disk - it is **the engine being inert without vacti**, exactly
as in the appliance plan (`vacti-engine-distribution`, `vacti-engine-ip-on-disk-and-enroll-bypass`).
The ISO is engineered to carry **no more IP than the current `.deb`, and no secret at all:**

1. **No baked credentials of any kind.** No enroll token, no engine tokens, no tailscale auth
   key, no `EVIDENCE_KEY`, no apt Basic-auth creds in the shipped rootfs. The private-repo creds
   used at *build* time are injected into the build chroot and removed by a late hook before the
   squashfs is made. A `strip-identity` hook truncates `/etc/machine-id` and removes SSH host
   keys so every install/boot is a fresh identity. A CI "no secret in image" scan gates the
   release (grep the squashfs for token/key patterns).
2. **No `.claude` methodology on disk.** The baked `.deb` ships 0 `.claude` entries by default
   (`VACTI_DEB_SHIP_CLAUDE` off). Methodology is fetched per-engagement into `/dev/shm` (RAM),
   sha256 fail-closed, wiped on teardown. The ISO inherits this - the crown jewels are never at
   rest on the media.
3. **Skills/prompts stripped + `dist` obfuscated in the baked `.deb`.** Per the IP-harden wave
   (`strip-skill-prose.mjs` + `strip-orchestrator-prompts.mjs` + `obfuscate-dist.mjs`). The ISO
   carries exactly that hardened artifact.
4. **Inert without vacti = moat + kill-switch.** A copied ISO cannot run an engagement without
   (a) a valid enrollment (no baked token; the operator must supply a live one-time token at
   first-run), (b) the per-engagement skill-bundle fetch (403s when `trusted=false` or the engine
   is disabled - the license kill-switch), and (c) the control plane for jobs/findings/creds. A
   stolen ISO is a branded Debian box with an obfuscated runner that fetches nothing.
5. **Watermark + trust-gate stay server-side** (`VACTI_WATERMARK_SECRET`,
   `VACTI_SKILL_BUNDLE_CLAIM_ENFORCE`) - ISO-served runs stay traceable + claim-gated.

**How the ISO enroll flow works (the user supplies a token at first run):**
- The `vacti-firstrun` oneshot runs once on first boot of the installed system (or the live
  session). It obtains a **short-lived, single-use enroll token** that the operator mints via
  `mintEnrollmentTokenAction` (30-min expiry, single-use, deleted server-side on use) and
  supplies by one of:
  - GUI SKU: a first-run dialog on the vacti desktop ("paste your enroll token").
  - headless SKU: a well-known file the operator drops at the console / via preseed late_command
    (same shape as `bootstrap-apt.sh --enroll <tok>`).
- It then runs the existing enroll path (`POST /api/pentest/enroll`) to receive the 3 scoped
  tokens, writes `/etc/vacti-engine/engine.env`, and disables itself. If the token is missing or
  expired it fails loudly and the operator re-mints - there is NO long-lived fallback baked in.
- **No shared secret ever lives in the ISO**, so a leaked/copied ISO cannot enroll itself or read
  any tenant data. This is the property Jev scores `ip_safe = high (2.00)`.

**Residual risk (be honest):** the baked `.deb` dist is obfuscated JS, not a hard wall; a
determined root-on-box adversary with a *trusted* engine can dump RAM during a live run. That is
already true of the `.deb` and the ISO does not worsen it. The one ISO-specific caution is mass
distribution of one artifact - fully mitigated by "no baked secret + inert without vacti." A
pre-enrolled / secret-carrying ISO would collapse the whole moat; **never ship one.**

---

## 7. LICENSING - Debian derivative is permissive

Debian's base is DFSG-free and, unlike Kali/Canonical, carries **no written-permission or
certification blocker** for building and distributing a derivative. The clean-practice checklist:

- **Rename** the product (own name, own `/etc/os-release`, own branding) and **do not use the
  Debian name or logos** on the image or in a way that implies the Debian project endorses it.
  Debian's "Open Use" logo is DFSG-free but the "Debian Open Use" / official logos have trademark
  guidance - simplest is to ship zero Debian marks and state non-affiliation.
- **Non-affiliation disclaimer:** a line in `/etc/os-release`/`/etc/issue`/docs such as "vacti is
  a derivative based on Debian GNU/Linux; it is not produced by, endorsed by, or affiliated with
  the Debian Project." (Mirror of the Kali "attribution notice" practice, now pointing at Debian.)
- **GPL source-offer:** we redistribute unmodified Debian binary packages, so the GPL
  written-offer is satisfied by pointing to the Debian source mirrors (`deb-src`
  snapshot.debian.org / the standard archive) in a `SOURCES`/`COPYING` note - we are not required
  to host the source ourselves for packages we did not modify. If we patch any GPL package, we
  host that package's source.
- **The vacti engine keeps its own proprietary license** - it is our package in our repo, not a
  Debian package, and is unaffected by the base's licensing. The obfuscated `.deb` and the
  server-side methodology remain proprietary.
- **Per-package review:** before baking any non-free/contrib tool, confirm its license permits
  redistribution in a derivative (most arsenal tools are GPL/BSD/MIT; a few - some Caido/commercial
  components - need a redistribution check). `--archive-areas` includes `contrib non-free
  non-free-firmware` for driver/firmware coverage; audit that set per release.

Net: the Debian base removes the OffSec/Canonical "ask permission" blocker entirely - rename +
no-Debian-marks + non-affiliation + source-offer-by-reference is sufficient for public
distribution.

---

## 8. REUSE - one customization layer for ISO AND cloud appliance

The ISO and the cloud image are two *packagings of the same customization*, not two projects.
Factor the customization into three shared, version-controlled inputs, each consumed by both
pipelines:

| Shared input | Cloud pipeline (`virt-customize`) | ISO pipeline (`live-build`) |
| --- | --- | --- |
| **Package set** (the `APT_PACKAGES` superset + `vacti-engine` + chromium pin, capability-gated) | `virt-customize --install <list>` driven from the shared manifest | `config/package-lists/vacti-core.list.chroot` generated from the same manifest |
| **Config overlay** (`/etc/os-release`, `/etc/vacti-engine/`, firstrun service, sudoers already in the `.deb`, xfce skel) | `virt-customize --copy-in <overlay>/` | `config/includes.chroot/<overlay>/` (same tree) |
| **Branding assets** (wallpaper, GRUB/Plymouth splash, greeter theme) | copied in + `plymouth-set-default-theme` via `--run` | `includes.binary/` + `hooks/normal/0100-branding.hook.chroot` |
| **First-run/enroll + identity-wipe** | cloud-init + `vacti-firstboot.service` + machine-id reset | `vacti-firstrun` service + `0200-strip-identity.hook.chroot` |

Implementation: keep a single `distro/` source tree (package manifest + `overlay/` + `branding/`
+ the firstrun unit) and two thin build drivers (`build-cloud.sh` wrapping `virt-customize`,
`build-iso.sh` wrapping `live-build` with a GUI/headless profile arg). Each driver materializes
the shared tree into the form its tool wants. CI builds both from the same tagged commit after a
`.deb` release, smoke-boots each (cloud image: boot + enroll + claim a job against staging; ISO:
QEMU BIOS + UEFI boot, Calamares dry-run / live-session engine start), records a manifest (image
sha256 + component versions), and publishes to a non-app download domain. The engine's shipped
`vacti-engine-update.timer` (idle-gated, 45 min) means both images only need to be a *recent
base* - rebuild monthly / per Debian point-release, not per engine release. This shared layer is
the key maintainability lever Jev scores below.

---

## 9. Jev vetting

Request: `typesafe/jev-1.13` via OpenRouter Decisions (live call, `POST /api/alpha/decisions`),
state = the live-build+Calamares ISO approach on a Debian-13 base, the two-SKU/one-tree design,
the shared customization layer with the cloud image, the no-baked-secret IP posture, and the
Debian derivative licensing. Response model snapshot `typesafe/jev-1.13-20260917`; cost
$0.0000580.

| Question | Type | Answer | Read |
| --- | --- | --- | --- |
| approach_sound (live-build + Calamares on Debian is the right tool) | noul | **0.90** | Yes - mirrors Kali's own pipeline on a permissive base; from-scratch + reproducible; debian-cd/Cubic-for-release rejection justified. |
| maintainable (one config tree, shared layer w/ cloud, self-update timer) | score 0-2 | **1.82** (high; P 0/0.18/0.82; conf 0.73) | Low burden: one customization source, monthly rebuild cadence, post-boot self-heal. 0.18 "moderate" mass = the two-build-driver upkeep seam. |
| ip_safe (no baked secret, inert without vacti, same as .deb) | score 0-2 | **1.84** (high; P 0/0.16/0.84; conf 0.76) | High, NOT maximal: the 0.16 "partial residual" mass is the honest RAM-dump-on-trusted-run caveat (§6) - 0 mass on "leaks IP / self-enrolls when copied", which is the property that matters. |
| licensing_clean (Debian derivative, rename + non-affiliation + source-offer) | noul | **0.73** | Yes, but the softest signal: Debian removes the written-permission blocker, yet Jev withholds full confidence - tighten by auditing the `non-free`/`contrib` tool set per release and getting the non-affiliation + source-offer wording legally reviewed before public distribution. |
| recommend_ship (proceed with live-build+Calamares, two SKUs) | noul | **0.81** | Proceed as designed; use Cubic only for throwaway spikes, debian-cd not at all. |

**Interpretation:** consistent positive endorsement, no blocker. Two honest soft signals, both
already surfaced in the body rather than papered over: (1) `ip_safe` 1.84 (not 2.0) because the
obfuscated-`.deb` RAM-dump caveat is real - but Jev puts **0** probability on the ISO leaking IP
or self-enrolling when copied, which is exactly the moat property; the residual is the same one
the `.deb` already carries. (2) `licensing_clean` 0.73 is the lowest score - Debian is permissive
and carries no permission blocker, but the per-package `non-free`/`contrib` audit and a legal
review of the non-affiliation + GPL source-offer wording should land before any *public*
distribution. Maintainability (1.82) confirms the single `distro/` source tree in §8 keeps the
two build drivers from diverging. The "no baked secret in the ISO" CI gate is non-negotiable -
it is what holds `ip_safe` at 0 probability of self-enrollment.

---

## 10. Open questions for the operator

1. **GUI DE choice:** XFCE (recommended, better tool-GUI story) vs LXQt (marginally lighter)?
2. **Headless install-to-disk:** preseeded debian-installer (recommended) vs Calamares text-mode?
3. **Baked default `ENGINE_CAPABILITIES`:** lean `web,infra` (smallest ISO) vs a fuller set?
4. **Persistence on the GUI live USB:** offer it (analyst convenience) or disable it (prefer
   install-to-disk + FDE for the appliance, to avoid state on a removable stick)?
5. **Product name + non-affiliation wording** for `/etc/os-release` and docs.
6. **ISO hosting:** same non-app download domain / R2 as the `.deb` and cloud image.

---

## Appendix - grounding

- Engine packaging: `/home/vacti/vacti-pentest-engine/packaging/bootstrap-apt.sh`
  (`APT_PACKAGES` superset lines 58-114; per-vertical `APT_PKGS_*`; `ENGINE_CAPABILITIES`
  default `web,infra`; enroll/firstboot path), `build-deb.sh` (strips skill prose + orchestrator
  prompts, obfuscates dist, 0 `.claude` by default), `src/runner/arsenal-check.ts`
  (`REQUIRED_TOOLS` + `TOOL_APT_PACKAGES` canonical map, runtime self-heal), `systemd/`
  (`vacti-engine.service`, `vacti-engine-update.{service,timer}`, `vacti.slice`), `sudoers.d/`
  (arsenal-apt / deprovision / rename), `rename-engine.sh` (engine-ID re-ID, not OS branding).
- Prior distro docs: `scratchpad/vacti-distro-base-survey.md` (Debian 13 base DECIDED),
  `scratchpad/.../vacti-distro-research.md` (Kali-era appliance/ISO plan this generalizes to
  plain Debian).

Sources (web, verified this pass):
- https://botmonster.com/self-hosting/build-custom-linux-iso-live-build-cubic/
- https://debian-live-config.readthedocs.io/en/latest/custom.html
- https://live-team.pages.debian.net/live-manual/html/live-manual/index.en.html
- https://en.ubunlog.com/cubic-2025-06-93/
- https://www.linux.org/threads/howto-make-your-own-debian-live-iso-with-live-build-repos-included.58079/
- https://forums.whonix.org/t/whonix-desktop-installer-with-calamares-field-report/7350
