# vacti distro - VM-appliance images + UNIFIED multi-format build pipeline (RESEARCH PASS)

Date: 2026-10-11 · Author: fanout research subagent · Status: for operator review
Scope: READ-ONLY research + design. No code/git writes. Base-OS decision is already made
(Debian 13 "trixie" headless `genericcloud` - see `scratchpad/vacti-distro-debian-replan.md`).
This doc covers the VM-APPLIANCE forms (VMware OVA/VMDK + VirtualBox OVA/VDI) and the single
source-of-truth pipeline that emits ALL formats (cloud qcow2/raw, installable ISO, VMware OVA,
VBox OVA) from ONE config, reusing the same appliance customization layer. The installable ISO
is a sibling agent's deliverable; this doc coordinates with it conceptually, it does not own it.

---

## 0. TL;DR

**Recommendation: do NOT run four separate Packer builders. Build ONE golden artifact - the
already-customized Debian `genericcloud` qcow2 (the shared appliance layer from the replan doc) -
then run a deterministic CONVERSION FAN-OUT to every target format.** This is the single most
important finding: a multi-builder tool (Packer) boots a *separate base per format* and *re-runs
provisioning per format*, so the four outputs can silently DRIFT (different package versions,
different timestamps, different random state). The golden-image + convert fan-out guarantees a
**bit-identical rootfs** across cloud / ISO / VMware OVA / VBox OVA, because every format is a
repackaging of the same disk. It also reuses the exact `virt-customize` layer the replan already
committed to, so there is near-zero new tooling.

- **VMware OVA** = `qemu-img convert` the golden qcow2 -> **streamOptimized VMDK**, then `ovftool`
  (or a hand-written OVF descriptor + `tar`) wraps it as an OVA. Bake **open-vm-tools** (Debian
  main). Importable to Workstation/Player/Fusion/ESXi.
- **VirtualBox OVA** = convert golden qcow2 -> VMDK (VBox's OVA default) or VDI (VBox native
  on-disk), then `VBoxManage export` with **OVF 1.0** for widest compatibility. Bake
  **virtualbox-guest-utils** (Debian contrib).
- **A single OVA for BOTH hypervisors is NOT reliable** (VirtualBox stamps
  `VirtualSystemType=virtualbox-2.2`, which VMware/ovftool reject or only import under `--lax` with
  a warning+Retry). **Ship TWO OVAs** (one authored for VMware, one for VBox) from the one golden
  disk. The cost of two OVAs is one extra convert+package step, not a second build.
- **First-boot enroll, unified:** a **NoCloud seed ISO** (a tiny `cidata.iso`, volume label
  `CIDATA`, carrying `user-data`+`meta-data` with the per-boot enroll token) is the **lingua franca
  that works on cloud, VMware, VirtualBox AND the installed-ISO system**. Native datasources (cloud
  provider metadata; VMware `guestinfo`) are optional enhancements layered on top of the same
  firstboot unit. No secret is ever baked into any shared image.
- **IP-protection/licensing: unchanged** from the appliance/ISO design - no baked creds, no
  `.claude` on disk, skills off-box, obfuscated `.deb` dist, inert without a vacti enrollment. A VM
  image (an OVA a human downloads) is MORE copyable than a cloud qcow2, which makes the "no baked
  secret + inert without vacti" rule even more load-bearing - it is the license kill-switch.

**Jev vet (live `typesafe/jev-1.13-20260917`, cost $0.00007):** `unified_feasible` **Score 1.55/2
-> high but soft** (p: low 0.01, med 0.42, high 0.57; conf 0.34) · `maintainable` **Score 1.81/2 ->
high** (p.high 0.81, conf 0.71) · `two_ova_right` (ship two OVAs not one) **Noul 0.91** (yes) ·
`recommend` (adopt fan-out as backbone) **Noul 0.91** (yes). The direction is endorsed (recommend +
two-OVA both 0.91; maintainable high); the one caution is feasibility *confidence* (0.34 with 0.42
mass on "medium") - Jev is flagging the real integration unknowns (the ISO hand-off + authoring two
hypervisor OVF descriptors), not design soundness. Resolve those before calling it routine. Full
detail in §7.

---

## 1. VMWARE image (OVA containing VMDK)

### 1.1 Disk conversion (golden qcow2 -> VMDK)

The golden disk is the customized `debian-13-genericcloud-amd64.qcow2`. VMware needs a VMDK, and
**the VMDK that goes INSIDE an OVA must be the `streamOptimized` subformat** (a single
compressed, append-only stream - the only subformat the OVF/OVA container accepts; the flat/sparse
subformats are for a VM running directly off a datastore, not for distribution).

```sh
qemu-img convert -p -f qcow2 -O vmdk \
  -o subformat=streamOptimized,adapter_type=lsilogic \
  vacti-engine-golden.qcow2 vacti-engine-disk.vmdk
```

- `adapter_type=lsilogic` is the safe default for a Linux guest on VMware (virtio is not a VMware
  bus; the Debian genericcloud kernel has the LSI/`mptspi` + the `vmw_pvscsi` drivers). `pvscsi`
  (paravirtual) is faster but `lsilogic` imports everywhere without extra driver fuss.
- `qemu-img` reading/writing streamOptimized VMDK is stable (qemu >= 1.2). This is one command, no
  VMware software required on the build host.

### 1.2 Packaging the OVA

Two ways, pick by whether a VMware binary is acceptable on the build host:

- **`ovftool` (VMware's own, most correct).** Feed it a `.vmx` (a minimal VM definition pointing at
  the VMDK) or convert an existing packaging; `ovftool source.vmx vacti-engine-vmware.ova` emits a
  spec-clean OVA with a correct manifest (`.mf`, SHA hashes) and `ovf:VirtualSystemType=vmx-NN`.
  Caveat: ovftool is a Broadcom/VMware download with its own EULA - fine to run in our CI, but it
  is not redistributable, so it stays a build-time tool, never shipped.
- **Hand-authored OVF + `tar` (no VMware binary).** Author a small OVF 1.0 descriptor
  (`VirtualSystemType=vmx-13` for a modern ESXi/Workstation baseline, an LSI Logic SCSI controller,
  the VMDK as `ovf:href`), compute the `.mf` manifest (SHA256 of the `.ovf` + `.vmdk`), then
  `tar` the three in order (`.ovf` first, then `.mf`, then `.vmdk`) into a `.ova`. This is fully
  open-source-toolchain and is what we should prefer in CI to avoid the ovftool EULA/download.
  `genisoimage`/`tar` + a templated OVF is all it needs.

### 1.3 Guest integration + first boot

- **open-vm-tools** (Debian `main`, headless - do NOT pull `open-vm-tools-desktop`) gives time sync,
  clean guest shutdown, and IP reporting to the hypervisor. Bake it in the `virt-customize` layer.
- **First-boot enroll on VMware:** two supported channels, same firstboot unit behind both:
  1. **VMware `guestinfo` datasource** (cloud-init `DataSourceVMwareGuestInfo`). cloud-init reads
     `guestinfo.metadata` + `guestinfo.userdata` from VMware's extraconfig (not a CD-ROM), each
     with a matching `*.encoding` key of `base64` or `gzip+base64`. Set them via OVF vApp
     properties (`ovftool --prop:...` / an OVF `ProductSection`) for ESXi, or directly in the
     `.vmx` (`guestinfo.userdata = "..."`) for Workstation/Player, or with `govc`/`vmrun`.
  2. **NoCloud seed ISO** (the universal fallback, §5) - attach a `cidata.iso` as a second CD-ROM;
     works identically on Workstation/Player/ESXi with no guestinfo plumbing.
- **Targets covered:** VMware Workstation, Player, Fusion, and ESXi/vSphere all import a
  spec-clean OVA. For a direct-to-vCenter build, Packer's `vsphere-iso`/`vsphere-clone` is an
  optional add-on (§4), but the OVA already covers every desktop + standalone ESXi case.

---

## 2. VIRTUALBOX image (OVA containing VMDK/VDI)

### 2.1 Disk format: VMDK vs VDI

- **VDI** is VirtualBox's *native on-disk* format. **VMDK** is what VirtualBox puts *inside an OVA*
  by default (stream-optimized), for portability. So: convert golden qcow2 -> **VMDK** for the OVA
  we distribute; VDI is only relevant if we also want to hand someone a raw attachable native disk.
- Conversion options (any of):
  - `qemu-img convert -O vdi golden.qcow2 disk.vdi` (direct to VDI), or `-O vmdk` for VMDK.
  - `VBoxManage convertfromraw golden.raw disk.vdi --format VDI` (needs a raw intermediate;
    `qemu-img convert -O raw` first - the raw is large, ~size of the virtual disk, so prefer the
    direct `qemu-img -O vdi/vmdk` path).
  - `VBoxManage clonehd in.vmdk out.vdi --format VDI` to cross-convert.

### 2.2 Packaging the OVA

```sh
# register a throwaway VM pointing at the disk, then export OVF 1.0 (widest import compatibility)
VBoxManage export vacti-engine-vbox --output vacti-engine-vbox.ova --ovf10
```

- **`--ovf10`** (OVF 1.0) is the most broadly importable; OVF 2.0 is fine for recent VBox but 1.0
  avoids edge rejections. VBox writes a stream-optimized VMDK into the OVA automatically.
- This needs VirtualBox (`VBoxManage`) on the build host - headless `virtualbox` package is enough;
  it can run in CI but wants `/dev/vboxdrv` (kernel module) for a running VM. For a pure
  export-of-an-existing-disk we can instead **hand-author the VBox OVF** the same way as the VMware
  one (set `VirtualSystemType=virtualbox-2.2`, SATA/IDE controller) + `tar`, avoiding the kernel
  module in CI. Hand-authoring is the CI-friendly path; `VBoxManage export` is the dev-box path.

### 2.3 Guest integration + first boot

- **VirtualBox Guest Additions:** for a headless engine appliance, the Debian `virtualbox-guest-utils`
  package (contrib) provides time sync + guest control without X; `virtualbox-guest-x11` is only
  for a GUI SKU. Bake `virtualbox-guest-utils` alongside open-vm-tools so ONE golden rootfs has
  both hypervisors' tools (they coexist; each is inert on the other's hardware).
- **First-boot enroll on VirtualBox:** cloud-init has **no first-class VirtualBox datasource** (its
  VMware datasource reads the VMware backdoor, which VBox does not expose). Two options:
  1. **NoCloud seed ISO (RECOMMENDED, §5)** - attach `cidata.iso` as a second optical drive;
     cloud-init NoCloud auto-detects the `CIDATA` label. Clean and cross-hypervisor.
  2. **`VBoxManage guestproperty set`** feeding a tiny custom firstboot reader - works but is
     VBox-specific glue we would have to maintain; use only if attaching an ISO is impossible.
  The NoCloud ISO makes the VBox first-boot path identical to every other form.

---

## 3. Can ONE OVA import into BOTH VMware and VirtualBox?

**Short answer: not reliably. Ship two OVAs.**

- OVF is a shared standard, but VMware and VirtualBox write/accept **different dialects**:
  - VirtualBox stamps `ovf:VirtualSystemType` as **`virtualbox-2.2`**; VMware/ovftool does **not**
    accept that value and wants a `vmx-NN` (e.g. `vmx-13`). Importing a VBox-authored OVA into
    VMware throws an "failed OVF specification" warning; it *sometimes* works on **Retry** or under
    ovftool **`--lax`** (best-effort hardware mapping), but that is a fragile, warning-laden path,
    not a shippable guarantee.
  - Controller/NIC hardware hints differ (VBox SATA/Intel PRO/1000 vs VMware LSI/vmxnet3); the
    importer on the "wrong" side substitutes defaults, occasionally mis-mapping the boot disk.
- The disk itself (stream-optimized VMDK) IS portable - it is only the **OVF descriptor** that is
  hypervisor-flavoured. So the cost of two OVAs is tiny: **same VMDK, two different descriptors**.
  The fan-out authors one VMware-flavoured OVF (`vmx-13`) and one VBox-flavoured OVF
  (`virtualbox-2.2`) around the same (or a per-target) VMDK and tars each.

**Decision: two purpose-built OVAs, not one "universal" OVA.** A single file that imports with a
scary warning on one platform is worse UX for an appliance a customer/analyst boots than two clean
files. (Jev `two_ova_right` = Noul 0.91.)

---

## 4. UNIFIED BUILD PIPELINE (the key ask)

### 4.1 The three candidate architectures, compared

| Architecture | How it makes N formats | Drift risk | New tooling vs today | Verdict |
| --- | --- | --- | --- | --- |
| **A. Golden image + convert fan-out** (RECOMMENDED) | `virt-customize` the official Debian cloud qcow2 ONCE -> golden disk; then `qemu-img`/`ovftool`/`VBoxManage`/`genisoimage` repackage that one disk into every format | **None** - every format is the same rootfs | **~zero** - replan already uses `virt-customize`; add convert+package steps | **Ship this** |
| **B. HashiCorp Packer, multi-builder** | one HCL file, builders `qemu` + `virtualbox-iso` + `vmware-iso`/`vsphere-iso`, each boots its own base + re-provisions | **High** - each builder installs independently; versions/time/entropy diverge across the 4 outputs | High - learn+maintain 4 plugins (`packer-plugin-qemu/-virtualbox/-vmware/-vsphere`, `packer init`), a Kali/Debian build VM per builder | Not as primary; keep for vSphere-direct only |
| **C. `debos` / `mkosi` declarative build** | one YAML/recipe builds a rootfs from debootstrap and emits disk images | Low rootfs drift, BUT rebuilds the base from scratch instead of the *official* cloud image | High - reimplements the appliance layer `virt-customize` already does; still needs ovftool/VBoxManage for OVA packaging | Not recommended |

**Why A wins decisively:** the replan already commits to `virt-customize` on the official Debian
cloud image as the appliance layer. Making the *other* formats mere repackagings of that one output
means the cloud qcow2, the ISO's installed rootfs, the VMware OVA and the VBox OVA are provably the
same engine - same package set, same config, same branding, same `.deb`. Packer's model
(each builder re-provisions its own base) is the opposite: it optimises for "build each target from
its native source", which is exactly the drift we must avoid for a security appliance where "all
four are identical" is a correctness property. Packer also adds a heavy multi-plugin surface for a
problem that is really "convert one disk to four containers".

### 4.2 Recommended pipeline - one source of truth, a convert fan-out

```
 ONE config  (vacti-appliance.env: Debian ver + pin, vacti-engine ver, ENGINE_CAPABILITIES,
  |           arsenal set, branding, Kali-repo on/off)  - the SAME inputs the cloud/ISO use
  v
[1] fetch + verify official Debian 13 genericcloud qcow2 (SHA512SUMS)
  |
[2] virt-customize  (THE shared appliance layer - identical to cloud/ISO):
  |    add vacti apt source + auth.conf; apt-get install vacti-engine (+ arsenal);
  |    install tailscale client + scoped sudoers/systemd/OOM hardening (postinst already writes);
  |    install open-vm-tools + virtualbox-guest-utils; install the cloud-init firstboot unit;
  |    branding (/etc/os-release, issue, MOTD); zero identity (machine-id, ssh_host_*, apt lists)
  v
  === GOLDEN DISK: vacti-engine-<ver>-golden.qcow2  (single source of truth) ===
  |
  +--[cloud]    qemu-img convert -> qcow2 (keep) + raw.gz  ............ idcloudhost/biznet/DO
  +--[ISO]      hand golden rootfs to the ISO agent's live-build/debootstrap OR
  |             (coordinate) the ISO installs the same vacti-engine from the same apt source
  +--[vmware]   qemu-img -O vmdk subformat=streamOptimized -> OVF(vmx-13) + .mf + tar -> .ova
  +--[vbox]     qemu-img -O vmdk (or vdi) -> OVF(virtualbox-2.2) + .mf + tar -> .ova
  +--[seed]     genisoimage NoCloud cidata.iso TEMPLATE (no token baked - operator fills per boot)
  v
[3] manifest: sha256 of every artifact + component versions  (reproducibility record)
[4] smoke: boot each in its hypervisor (qemu / VBox headless / ESXi or vmplayer) with a throwaway
    enroll token vs a staging CP; assert enroll + claim-a-job; then publish to R2/non-app domain
```

- **Orchestration:** a `Makefile` (or a `build-images.sh`) with a target per format, driven in CI by
  a matrix job sibling to `release-deb.yml`, triggered AFTER a `.deb` publish. All open-source
  tools (`libguestfs`/`virt-customize`, `qemu-img`, `genisoimage`, `tar`); `ovftool`/`VBoxManage`
  optional on dev boxes only. This is the "most maintainable + CI-buildable" answer the task asks
  for: one recipe, standard Linux tools, no VMware/VBox binary required in CI.
- **Where Packer still earns a place:** a single **optional** `vsphere-clone`/`vsphere-iso` lane for
  teams that want the appliance pushed straight into a vCenter as a template. It is additive, not
  the backbone. Everything a desktop user needs is the two OVAs from fan-out A.
- **Reuse of the cloud-appliance customization layer:** step [2] IS the cloud image's customization
  step - same `vacti-appliance.env`, same package set, same `virt-customize` script, same branding
  and the same firstboot unit. The VM forms add only a conversion/packaging tail. Nothing about the
  engine, arsenal, hardening or IP posture is re-specified per format.

### 4.3 Image staleness / cadence (maintainability lever, carried over)

The shipped `vacti-engine-update.timer` (idle-gated, 45 min) self-updates any booted engine to the
latest `.deb`, so all image forms only need to be a *recent base*. Rebuild the whole fan-out
monthly / on a Debian point-release / on a first-boot-affecting `.deb` change - not per engine
release. One rebuild produces all four formats in lockstep.

---

## 5. FIRST-BOOT / ENROLL per format (unified via NoCloud)

**Principle (unchanged, non-negotiable): the shared image carries ZERO credentials** - no enroll
token, engine token, tailscale key or `EVIDENCE_KEY`. The firstboot *mechanism* is baked; the
*secret* arrives per-instance. A copied image is inert.

**The unifying trick: NoCloud is the lingua franca.** cloud-init's NoCloud datasource reads a
`user-data`+`meta-data` pair from a filesystem labelled `CIDATA` (or `cidata`). A ~400 KB
`cidata.iso` built with `genisoimage` and attached as a second CD-ROM works **identically** on
VMware, VirtualBox, bare-metal/USB and the installed-ISO system. One firstboot unit, one code path.

| Format | Primary enroll channel (operator supplies token) | Notes |
| --- | --- | --- |
| **Cloud (qcow2/raw)** | cloud-init **provider metadata / user-data** (idcloudhost `POST /vm`, biznet `POST /neolites`, DO droplet `user_data`) | existing design; NoCloud also works if a provider lacks user-data |
| **Installable ISO** | **NoCloud seed** on a labelled USB/partition, OR debian-installer **preseed** that drops the token file; live-only can take it on the **kernel cmdline** or the firstboot **file-drop** fallback | coordinate exact mechanism with the ISO agent; the installed system runs the SAME firstboot unit |
| **VMware OVA** | **guestinfo** (`guestinfo.userdata`/`.metadata`, base64/gzip+base64, via OVF vApp prop / `.vmx` / `govc`), OR **NoCloud `cidata.iso`** | ESXi: set as OVF property at deploy; Workstation/Player: `.vmx` line or attach the ISO |
| **VirtualBox OVA** | **NoCloud `cidata.iso`** (attach as 2nd optical drive), OR `VBoxManage guestproperty` + a small reader | no native VBox cloud-init datasource; NoCloud is the clean path |

**Operator flow (all non-cloud forms):** mint a 30-min single-use enroll token
(`mintEnrollmentTokenAction`), drop it into a `user-data` template, `genisoimage` a `cidata.iso`,
attach it, boot. The existing `do_enroll` -> `POST /api/pentest/enroll` path (single-use, 30-min
expiry, server-deletes the token) obtains the 3 scoped tokens and writes
`/etc/vacti-engine/engine.env`; tailscale joins with the server-served reusable key on normal
startup. If the token expires before boot, firstboot **fails loudly** and the operator re-mints -
never bake a longer-lived fallback.

**We ship the `cidata.iso` as a TEMPLATE + a one-liner, not pre-filled.** The published artifact is
a `user-data.example` + a `make-seed.sh` that genisoimages the operator's freshly-minted token.
The OVA/qcow2 themselves stay secretless.

---

## 6. IP-PROTECTION + LICENSING (carried over, with the VM-specific caution)

Identical posture to the appliance/ISO (replan §5 / research §5), re-stated for the VM forms
because an OVA a human downloads is the MOST copyable artifact we produce:

1. **No `.claude` on disk** - `build-deb.sh` ships 0 `.claude` by default; methodology fetched
   per-engagement into `/dev/shm`, wiped on teardown. The golden disk bakes that same `.deb`, so the
   VMDK/VDI inside every OVA has no methodology at rest.
2. **Skills/prompts stripped + obfuscated** in the baked `.deb` (`strip-skill-prose.mjs`,
   `strip-orchestrator-prompts.mjs`, `obfuscate-dist.mjs`). The OVA carries exactly that hardened
   artifact.
3. **Inert without vacti = the moat + kill-switch** - the image cannot run an engagement without a
   valid enrollment (no baked token), the per-engagement trust-gated skill-bundle fetch (403 when
   `trusted=false`/engine disabled), and the control plane. A copied OVA is a bricked Debian box with
   an obfuscated runner that fetches nothing.
4. **No baked secret** (§5) - the single most important VM-image rule. Every secret arrives
   per-instance (seed ISO / guestinfo / provider metadata) or per-engagement.
5. **Watermark + trust-gate stay server-side** (`VACTI_WATERMARK_SECRET`,
   `VACTI_SKILL_BUNDLE_CLAIM_ENFORCE`).

**Licensing:** Debian derivative = permissive (SPI trademark policy: rename, no Debian logos in our
branding, non-affiliation disclaimer, acknowledge SPI; no written permission). open-vm-tools is
Debian `main` (GPL/BSD, redistributable). **VirtualBox Guest Additions** base is GPLv2
(redistributable); the PUEL-licensed VBox *Extension Pack* is NOT needed and must not be baked -
`virtualbox-guest-utils` from Debian contrib is the clean guest-tools source. **`ovftool` is a
Broadcom download under its own EULA** - build-time only, never shipped. `VBoxManage` is GPLv2
(fine). GPL/mixed source obligation satisfied by pointing to Debian's public source mirrors; our
own engine `.deb` keeps its proprietary/obfuscated license.

**Residual risk (honest):** root-on-box beats at-rest obfuscation; a trusted-engine adversary can
dump RAM during a live run - true of the `.deb` today, and the OVA does not worsen it. The one
VM-specific amplifier is mass distribution of a single downloadable file, fully mitigated by
"no baked secret + inert without vacti". A pre-enrolled/secret-carrying OVA would collapse this -
**never ship one.** Add a CI "no secret in image" scan over every emitted artifact.

---

## 7. Jev vetting

Request: `typesafe/jev-1.13` via `openrouter-jev`, state = the unified golden-image + convert
fan-out pipeline (one `virt-customize`d Debian qcow2 -> cloud/ISO/VMware-OVA/VBox-OVA), two OVAs
(not one universal), NoCloud seed ISO as the unified first-boot enroll, IP posture carried over.

Live response snapshot `typesafe/jev-1.13-20260917`, cost $0.000071, id
`gen-dec-1791695323-72irBYkC4nzC2kYMc8Nc`.

| Question | Answer |
| --- | --- |
| `unified_feasible` (one config -> all 4 formats via golden-image fan-out) | **Score 1.55/2 -> high but soft** (p: low 0.01, med 0.42, high 0.57; conf 0.34) |
| `maintainable` (CI-buildable, open-source tools, low burden) | **Score 1.81/2 -> high** (p.high 0.81, conf 0.71) |
| `two_ova_right` (ship two hypervisor-specific OVAs, not one "universal") | **Noul 0.91** (yes) |
| `recommend` (adopt fan-out A as the pipeline backbone) | **Noul 0.91** (yes) |

**Interpretation:** the architecture decision is clearly endorsed - `recommend` 0.91 and
`two_ova_right` 0.91 are strong yeses, and `maintainable` lands high (0.81). The single non-maximal
signal is `unified_feasible`: it still leans "high" (0.57) but with 0.42 mass on "medium" and a low
0.34 confidence - i.e. Jev is not doubting the design, it is flagging that real integration unknowns
remain before the pipeline is *routine*. Those unknowns are exactly the two deferred details in this
doc: (a) the precise hand-off of the golden rootfs to the sibling ISO agent's build, and (b)
hand-authoring two correct hypervisor-specific OVF descriptors (vmx-13 vs virtualbox-2.2) and
proving each imports clean. Close both (and keep the smoke-boot gate) and feasibility firms up.
Hold the "no baked secret" and "golden disk is the only source of truth" rules absolutely - they are
what keep both the IP posture and the all-four-identical correctness property.

---

## 8. Open questions for the operator

1. **CI without VMware/VBox binaries:** adopt the **hand-authored OVF + tar** path (keeps CI
   fully open-source, no ovftool download / no vboxdrv kernel module), with `ovftool`/`VBoxManage`
   only on dev boxes for spot-checks? (Recommended.)
2. **Disk adapter default:** `lsilogic` (imports everywhere) vs `pvscsi`/`vmxnet3` (faster, needs the
   right in-guest driver present - it is, in genericcloud) for the VMware OVA?
3. **Guest tools:** bake BOTH open-vm-tools + virtualbox-guest-utils into the one golden rootfs
   (recommended, they coexist) vs per-format rootfs? Baking both keeps ONE golden disk.
4. **Seed-ISO delivery:** ship the `cidata.iso` as a template + `make-seed.sh` (recommended,
   secretless) vs a GUI step in the control plane that mints the token and hands the operator a
   ready `cidata.iso` to attach?
5. **vSphere-direct lane:** add the optional Packer `vsphere-clone` path for push-to-vCenter, or is
   the ESXi-importable OVA enough for now?
6. **Which formats are Phase-1 vs later:** cloud (done/primary) + the two OVAs now, ISO as the
   sibling agent lands it? Confirm the fan-out ships OVAs in the first image release.

---

## Appendix - grounding facts (verified this pass)

- **VMDK subformats:** the OVA-embedded disk must be `streamOptimized` (single compressed stream);
  `qemu-img convert -O vmdk -o subformat=streamOptimized,adapter_type=lsilogic` produces it; qemu
  reads/writes streamOptimized since qemu 1.2. No one-step qcow2->OVA tool exists - convert to VMDK,
  then package with ovftool or a hand-authored OVF+tar. (Vinchin/COT guides; qemu-img docs.)
- **OVA cross-hypervisor:** VirtualBox stamps `VirtualSystemType=virtualbox-2.2`; VMware/ovftool
  rejects it (import warning; works only on Retry / `ovftool --lax` best-effort). The portable part
  is the VMDK; the OVF descriptor is hypervisor-flavoured -> ship two OVAs. (howtogeek,
  fabianlee.org, Ganeti ovfconverter notes.)
- **VBoxManage:** `VBoxManage export <vm> --output x.ova --ovf10` (OVF 1.0 = widest import);
  `VBoxManage clonehd`/`convertfromraw --format VDI`; `qemu-img convert -O vdi/vmdk` direct. VDI =
  VBox native on-disk; VMDK = VBox OVA default. (linuxconfig, dedoimedo, sleeplessbeastie.)
- **Packer plugins (post-1.7 external-plugin model):** declare in `required_plugins` + `packer init`
  (or `packer plugins install github.com/hashicorp/<name>`). `packer-plugin-qemu` (KVM images),
  `packer-plugin-vmware` (`vmware-iso`/`vmware-vmx`; no vSphere API; follows Broadcom lifecycle),
  `packer-plugin-vsphere` (`vsphere-iso`/`vsphere-clone`/`vsphere-supervisor` via vCenter API),
  `packer-plugin-virtualbox`. Each builder boots its own base + re-provisions (the drift reason to
  prefer golden-image fan-out). (developer.hashicorp.com; the hashicorp plugin repos.)
- **cloud-init datasources:** VMware `DataSourceVMwareGuestInfo` reads `guestinfo.metadata`/
  `.userdata` via VMware extraconfig (NOT a CD-ROM), encodings `base64` or `gzip+base64`, needs a
  `*.encoding` key; no EC2-style IMDS on VMware. VirtualBox has no native cloud-init datasource ->
  use NoCloud. **NoCloud** reads `user-data`+`meta-data` from a `CIDATA`-labelled FS (a `cidata.iso`
  via `genisoimage`), works on cloud/VMware/VBox/ISO alike - the unifying first-boot channel. (AWS
  AL2023 guestinfo docs; cloud-init datasource docs.)
- **Guest tools on Debian:** `open-vm-tools` (main, headless; `-desktop` only for GUI);
  `virtualbox-guest-utils` (contrib, headless; `-x11` only for GUI). Both coexist in one rootfs.
- **Reused appliance layer** (from `scratchpad/vacti-distro-debian-replan.md`): Debian 13 trixie
  genericcloud qcow2, `virt-customize` offline, `apt-get install vacti-engine` from the private apt
  repo + arsenal (Option A keeps the Kali apt repo as a package source), tailscale client + scoped
  sudoers/systemd/OOM hardening (postinst), zero-identity, no baked secret, engine self-update timer.

Sources:
- https://www.vinchin.com/vm-migration/convert-qcow2-to-ova.html
- https://cot.readthedocs.io/en/v1.8.2/_modules/COT/disks/qcow2.html
- https://www.howtogeek.com/125640/how-to-convert-virtual-machines-between-virtualbox-and-vmware/
- https://fabianlee.org/2016/11/30/vmware-exporting-from-oracle-virtualbox-vagrant-to-vcloud-director/
- https://docs.ganeti.org/docs/ganeti/2.17/html/_sources/ovfconverter.txt
- https://docs.aws.amazon.com/linux/al2023/ug/vmware-guestinfo.html
- https://developer.hashicorp.com/packer/plugins/builders/vmware
- https://github.com/hashicorp/packer-plugin-qemu
- https://github.com/hashicorp/packer-plugin-vsphere
- https://linuxconfig.org/ (VBoxManage export OVF 1.0)
- https://www.dedoimedo.com/computers/virtualbox-convert.html
- https://sleeplessbeastie.eu/2012/04/29/how-to-convert-raw-image-to-vdi-and-otherwise/
</content>
</invoke>
