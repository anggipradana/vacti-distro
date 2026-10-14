# vacti-distro

Build sources for the **vacti pentest OS / distro**: a Debian-based appliance that ships the
vacti pentest engine pre-provisioned, in multiple distribution forms (cloud image, installable
ISO, and VM appliances for VMware and VirtualBox).

This repository holds **our build sources only** (scripts, config trees, branding, CI). It does
not vendor the Debian base, the arsenal packages, or the engine `.deb`; those are pulled at build
time. See [NOTICE.md](NOTICE.md) for the licensing posture of the built image.

The design research behind this plan is preserved verbatim under [`docs/`](docs/) (five research
passes: base survey, Debian re-plan, cloud/appliance research, installable-ISO build, and the
unified VM pipeline). This README is the synthesis.

---

## 1. Base OS: Debian 13 "trixie"

The base is **Debian 13 "trixie"**, headless `genericcloud` variant, amd64 primary (arm64
available natively for the same variant).

Why Debian, and not Kali or an Ubuntu derivative:

- **Permissive derivative policy.** Debian (SPI) welcomes derivatives with only a rename, no
  Debian logos in our branding, and a non-affiliation disclaimer. There is **no written-permission
  blocker** - unlike OffSec/Kali (redistribution of unmodified Kali only; written permission for
  anything modified) or Canonical/Ubuntu (modified branded redistribution needs a paid licence or
  a mark-strip + recompile).
- **Engine is already Debian-native.** The engine `.deb` targets Debian + Node 22, and the
  packaging bootstrap already has a first-class Debian-family code path (`ID=debian`/`ID_LIKE`
  mapped to a supported mode). The pivot off Kali is mostly a re-label of the base image, not a
  toolchain rebuild.
- **Full arsenal installs at parity.** The apt arsenal resolves on Debian; the small set absent
  from Debian `main` (nuclei, httpx, naabu, feroxbuster, seclists, commix) is covered by the
  existing go-install / release / git fallbacks already wired into the runtime self-heal, with the
  Kali apt repo available as an ordinary package source (Option A) and a fully Kali-free path
  (Option B) as a fast-follow.
- **Official cloud images, glibc + systemd.** Debian publishes official cloud images with
  cloud-init baked in; it is glibc (Playwright/Chromium need it) and systemd by default (the engine
  ships systemd units + timers). Kali and the Ubuntu family are avoided; musl/non-systemd bases
  (Alpine, antiX, Devuan) are disqualified on stack compatibility.

Pin the exact base image version (and its `SHA512SUMS`) per release in the build manifest. Keep
bookworm (Debian 12) only as a conservative fallback if a provider lacks a trixie image.

---

## 2. Distribution forms

One source tree produces four distribution forms, plus a universal first-boot seed:

| Form | Artifact | Target |
| --- | --- | --- |
| **Cloud** | `qcow2` + `raw.gz` | idcloudhost / biznet / DigitalOcean provisioning |
| **Installable ISO** | hybrid BIOS+UEFI `.iso` (live + install-to-disk) | on-prem / standalone appliance, GUI + headless SKUs |
| **VMware OVA** | `.ova` (streamOptimized VMDK, `vmx-13` OVF) | Workstation / Player / Fusion / ESXi |
| **VirtualBox OVA** | `.ova` (VMDK, `virtualbox-2.2` OVF) | VirtualBox desktop |

**Two OVAs, not one.** A single "universal" OVA is not reliable: VirtualBox stamps
`VirtualSystemType=virtualbox-2.2`, which VMware/ovftool rejects (imports only under `--lax` with a
warning). The disk (streamOptimized VMDK) is portable; only the OVF descriptor is
hypervisor-flavoured, so we ship two OVAs built from the same VMDK - one authored for VMware
(`vmx-13`), one for VirtualBox (`virtualbox-2.2`).

---

## 3. Build architecture: ONE source tree, a golden image, a convert fan-out

All forms are built from a single [`distro/`](distro/) source tree feeding two drivers:

### (a) Installable ISO - Debian `live-build` + Calamares

`live-build` (`lb config` / `lb build`) debootstraps a fresh trixie chroot, installs our package
lists + config overlay + branding, and emits a hybrid BIOS+UEFI ISO with a live session. This is
the same engine Kali's own `kali-live` wraps, now on a permissive Debian base. One config tree, two
SKUs by package-list selection:

- **GUI SKU** - XFCE + LightDM + **Calamares** graphical install-to-disk, analyst-facing.
- **headless SKU** - no desktop, debian-installer **preseed** for unattended rack install.

`debian-cd` (full-archive DVDs) and Cubic (manual chroot remaster, unreproducible) are rejected for
the release pipeline; Cubic is a throwaway prototyping aid only.

### (b) Cloud + VM OVAs - golden image + deterministic conversion fan-out

Rather than run separate builders per format (which drift), build **one golden artifact** and
repackage it into every VM/cloud form:

```
ONE config (distro/ package manifest + overlay + branding + enroll)
  |
[1] fetch + verify official Debian 13 genericcloud qcow2 (SHA512SUMS)
  |
[2] virt-customize (THE shared appliance layer):
  |    add vacti apt source + auth.conf; apt-get install vacti-engine (+ arsenal);
  |    install tailscale client + scoped sudoers/systemd/OOM hardening (postinst writes them);
  |    install open-vm-tools + virtualbox-guest-utils; install the cloud-init firstboot unit;
  |    branding (/etc/os-release, issue, MOTD); zero identity (machine-id, ssh_host_*, apt lists)
  v
  === GOLDEN DISK: vacti-engine-<ver>-golden.qcow2 (single source of truth) ===
  |
  +-- [cloud]  qemu-img convert -> qcow2 (keep) + raw.gz .......... idcloudhost/biznet/DO
  +-- [vmware] qemu-img -O vmdk subformat=streamOptimized -> OVF(vmx-13) + .mf + tar -> .ova
  +-- [vbox]   qemu-img -O vmdk (or vdi) -> OVF(virtualbox-2.2) + .mf + tar -> .ova
  +-- [seed]   genisoimage NoCloud cidata.iso TEMPLATE (no token baked - operator fills per boot)
  |
[3] manifest: sha256 of every artifact + component versions (reproducibility record)
[4] smoke-boot each in its hypervisor with a throwaway enroll token vs a staging CP;
    assert enroll + claim-a-job; then publish to a non-app download domain
```

Every format is a repackaging of the same rootfs, so cloud / ISO / VMware OVA / VBox OVA are
provably the **same engine** (same packages, same config, same branding, same `.deb`). All packaging
steps use open-source tools (`libguestfs`/`virt-customize`, `qemu-img`, `genisoimage`, `tar`);
`ovftool`/`VBoxManage` stay dev-box-only (hand-authored OVF + tar is the CI-friendly path).

The ISO's `live-build` chroot and the golden image's `virt-customize` consume the **same** package
manifest, config overlay, and branding assets from `distro/` - one source of truth, two thin
drivers.

---

## 4. Universal first-boot enrollment (no baked secret)

A booted image auto-registers with the control plane **without any long-lived secret baked into a
shared image**. The shared image carries **zero** credentials: no enroll token, no engine token, no
tailscale key, no `EVIDENCE_KEY`. The firstboot *mechanism* is baked; the *secret* arrives
per-instance.

The unifying channel is a **NoCloud seed** - a tiny `cidata.iso` (volume label `CIDATA`) carrying
`user-data` + `meta-data` with a short-lived per-boot enroll token. NoCloud works identically on
cloud, VMware, VirtualBox, and the installed-ISO system. Native datasources (cloud provider
metadata; VMware `guestinfo`) are optional enhancements layered on the **same** firstboot unit.

Flow: the operator mints a 30-minute, single-use enroll token, drops it into a `user-data`
template, `genisoimage`s a `cidata.iso`, attaches it, and boots. The existing enroll path
(single-use, 30-min expiry, server-deletes the token) obtains the scoped tokens and writes the
engine env; tailscale joins with the server-served reusable key on normal startup. If the token
expires before boot, firstboot fails loudly and the operator re-mints - there is **no** longer-lived
baked fallback. The `cidata.iso` ships as a **template + `make-seed.sh`**, never pre-filled.

---

## 5. IP moat

An image (especially a downloadable OVA/ISO) is more copyable than a `.deb`, so the moat is
architectural, not at-rest cryptographic. The image is engineered to carry **no more IP than the
current `.deb`, and no secret at all**:

1. **0 `.claude` on disk.** The baked `.deb` ships 0 `.claude` entries by default; methodology is
   fetched per-engagement into `/dev/shm` (RAM), sha256 fail-closed, wiped on teardown. The image
   inherits this - the crown-jewel methodology is never at rest on the image.
2. **Obfuscated engine `.deb`.** Skill prose + orchestrator prompts are stripped and the `dist` is
   obfuscated at build; the image carries exactly that hardened artifact.
3. **Skills off-box.** Per-engagement skill bundles are fetched from the control plane, trust-gated
   (403 when `trusted=false` or the engine is disabled).
4. **Inert-without-vacti kill-switch.** A copied image cannot run an engagement without a valid
   enrollment (no baked token), the per-engagement trust-gated skill-bundle fetch, and the control
   plane for jobs/findings/creds. A stolen image is a bricked Debian box with an obfuscated runner
   that fetches nothing.
5. **No baked secret** (see section 4) - the single most important image rule. A CI
   **no-secret scan** gates every emitted artifact (grep the rootfs/squashfs for token/key patterns).

Honest residual: the obfuscated `.deb` dist is not a hard wall; a determined root-on-box adversary
with a *trusted* engine can dump RAM during a live run. That is already true of the `.deb`; the
image does not worsen it. The one image-specific amplifier is mass distribution of a single
artifact, fully mitigated by "no baked secret + inert without vacti." A pre-enrolled or
secret-carrying image would collapse the moat - **never ship one.**

---

## 6. Phased plan

| Phase | Deliverable | Notes |
| --- | --- | --- |
| **Phase 1 (committed primary)** | **Headless cloud engine appliance** (qcow2 + raw.gz) + NoCloud/cloud-init auto-enroll + CI build/smoke | Lowest effort, highest ROI; reuses the proven `.deb` + apt repo + enroll + tailscale + hardening. Fleet provisioning becomes "boot + token". The two OVAs follow from the same golden disk in the first image release. |
| **Phase 2** | **Branded installable ISO** (live-build + Calamares, GUI + headless SKUs) | Builds on plain Debian / an ordinary Debian CI container - no Kali-only runner. For offline / on-prem / standalone appliances. |
| **Phase 3 (optional)** | Product SKUs: `generic` (bare-metal) image, GUI SKU polish, WSL rootfs, ARM/rpi | Situational; only with a commercial driver. |

The engine's shipped idle-gated self-update timer brings any booted engine to the latest `.deb`
within one cycle, so images only need to be a *recent base*: rebuild monthly / per Debian
point-release / on a first-boot-affecting `.deb` change, not per engine release.

---

## 7. Layout

```
vacti-distro/
  README.md                    # this synthesis
  LICENSE                      # MIT, for OUR build sources
  NOTICE.md                    # licensing of the BUILT IMAGE (GPL/Debian + third-party)
  Makefile                     # targets: golden, cloud, vmware-ova, vbox-ova, iso, iso-gui, seed, scan, all
  ci/
    no-secret-scan.sh          # MANDATORY gate: fail on ANY baked secret/key/methodology
    lint.sh                    # light shellcheck + yaml/xml sanity (no image build)
  .github/workflows/build.yml  # CI build matrix: golden -> fan-out + iso, scan, smoke, PRIVATE release
  docs/                        # the five research passes, verbatim
  distro/
    vacti-appliance.env        # the ONE config (base pin, engine ver, capabilities, Kali on/off)
    live-build-config/         # live-build config tree (ISO) + build-iso.sh driver
    golden-image/              # build-golden.sh (virt-customize) + convert-*.sh + fanout.sh + OVF templates
    packages/                  # web-lean.list / full.list + manifest.yml + gen + Kali Option-A source/pin
    branding/                  # Vacti OS brand: logo + os-release/issue/dynamic MOTD + fastfetch + grub + plymouth + wallpaper + greeter + xfce + apply-branding.sh + render-assets.sh
    enroll/                    # firstboot unit+script + NoCloud template + make-seed.sh + guestinfo notes
```

Each `distro/` subdirectory carries a `PLAN.md` describing what lands there; the Phase-1 build
sources are now implemented alongside those plans.

---

## 8. Status

**Phase-1 build sources implemented.** The `distro/` tree now holds working build sources (not
stubs): `golden-image/build-golden.sh` applies the shared appliance layer with `virt-customize`;
`convert-*.sh` + `fanout.sh` repackage the one golden disk into the cloud qcow2/raw and the two
OVAs; `live-build-config/` + `build-iso.sh` build the installable ISO (headless + GUI SKUs) from
the SAME package manifest, branding, and enroll overlay (one source of truth); `enroll/` bakes the
no-secret first-boot mechanism and ships the NoCloud seed as a template + `make-seed.sh`; the
`Makefile` and `.github/workflows/build.yml` wire it together. **The heavy image build runs in CI
(GitHub Actions), OFF the prod control plane** - these scripts are authored to run on a GitHub
runner, not on the prod box.

A **mandatory `ci/no-secret-scan.sh` gate** fails the build on any baked secret/key/methodology in
any emitted artifact. Public distribution of any built image is still **pending** a per-package
non-free/contrib license audit and a Debian non-affiliation review (see [NOTICE.md](NOTICE.md)).

**Next step (not done here):** trigger the FIRST actual CI image build (`workflow_dispatch` on
`build-images`), after setting the repo `vars`/`secrets` it reads (`VACTI_APT_URL`,
`VACTI_APT_PRODUCER_TOKEN`, optionally `STAGING_CP_URL`/`STAGING_ENROLL_TOKEN`). This commit only
authors + pushes the sources and workflow; it does not run a heavy build.
