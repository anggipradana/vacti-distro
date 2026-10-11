# vacti OS / distro - research + design (RESEARCH PASS, not implementation)

Date: 2026-10-11 · Author: fanout research subagent · Status: for operator review
Scope: READ-ONLY research + design. No code/git writes. Grounded in current engine
packaging (`/home/vacti/vacti-pentest-engine/packaging`) + memory notes, with Kali
build-tooling facts verified via web.

---

## 0. TL;DR (read this first)

**Operator ask:** build vacti's OWN OS by customizing ("editing") Kali Linux.

**Recommended primary target = an ENGINE APPLIANCE image (candidate a), phased:**

- **Phase 1 (committed primary, lowest effort / highest ROI):** a **cloud
  engine-appliance image** built by customizing Kali's *official Generic Cloud Image*
  OFFLINE (`virt-customize`/libguestfs) so it boots pre-provisioned as a vacti engine
  and auto-enrolls via `cloud-init` first-boot. Reuses ~all existing machinery (the
  `.deb`, the private apt repo, the enroll flow, tailscale auto-join, skills-off-box).
  Outputs raw + qcow2 for idcloudhost / biznet / DO. **This replaces "install the .deb
  on a fresh Kali box" with "boot an image."**
- **Phase 2 (branding + ISO):** a branded **live-build ISO** (Kali `kali-live`
  build-scripts) with Kali trademarks removed + an attribution notice, for
  offline/on-prem/standalone appliances and a bootable installer.
- **Phase 3 (optional, product):** a standalone branded pentest-OS product (WSL rootfs,
  OVA, rpi/ARM) if there is ever a commercial reason to ship vacti-OS to third parties.

**Jev vet of the Phase-1 primary (model `typesafe/jev-1.13-20260917`):**

| Question | Answer | Confidence |
| --- | --- | --- |
| right_goal (on-intent first step) | **Noul 0.90** (yes) | - |
| feasible | **Score 1.78 / 2 → high** (p.high 0.78) | 0.67 |
| ip_safe | **Score 2.00 / 2 → high** (p.high 1.00) | 1.00 |
| maintainable | **Score 1.97 / 2 → high** (p.high 0.97) | 0.95 |
| recommend_ship (proceed Phase 1 first) | **Noul 0.89** (yes) | - |

All five green. Jev's one soft signal: `feasible` confidence 0.67 - i.e. clearly
feasible but with integration gaps worth nailing (the open questions in §9).

---

## 1. GOAL / use cases - what is the distro FOR?

Three candidate goals were posed. Inferring from our actual distribution model:

**(a) Engine appliance - RECOMMENDED PRIMARY.** Today a new engine box = "get a Kali
host, run `bootstrap-apt.sh`, it adds the private apt source, installs `vacti-engine`,
enrolls, joins tailscale." That is already a *de-facto appliance install*; the only
missing step is pre-baking it into a bootable image so provisioning is "boot + hand it a
one-time token" instead of "SSH in and run a 107 KB installer." This is the highest-ROI
form because:
- Our fleet is cloud VMs on providers with **no native Kali image** (idcloudhost, biznet,
  DO) - we already solve that by uploading Kali's Generic Cloud Image as a custom image
  (`vacti-kali-droplet` memory). An appliance image is the natural next step on a path we
  already walk.
- Everything the appliance needs already exists and is battle-tested: the `.deb`, the
  apt repo, `enroll.ts`, tailscale auto-join, the hardening sudoers, OOM hardening.

**(b) Branded standalone pentest OS.** A product-shaped "vacti-OS" a human boots and uses
like Kali/Parrot. Real work (branding, trademark compliance, a full live-build pipeline,
support surface) for unclear near-term benefit. Defer to Phase 2/3.

**(c) Both.** The phased plan *is* both over time: appliance now, branded ISO later,
product last. We do not have to choose (a) vs (b) up front - (a) is the substrate (b)/(c)
are built on.

**Assumption stated:** the operator's "our own OS" instinct is satisfied *fastest and
cheapest* by (a) - a reproducible vacti-customized Kali image the fleet boots - and the
branded-OS ambition is served *better later* once (a) proves the pipeline. If the
operator's actual priority is a *marketable branded OS first*, jump to Phase 2; but that
is a product decision, not a fleet-ops one.

---

## 2. HOW to build a custom Kali distro - options compared (verified)

| Route | Produces | Build host | Effort | Fit for vacti |
| --- | --- | --- | --- | --- |
| **Generic Cloud Image + `virt-customize`** | qcow2 / raw cloud image | any Linux w/ libguestfs | **Low** | **Phase 1 primary** - matches how we already run Kali in cloud |
| **`kali-live` live-build** | bootable live/installer **ISO** | must be a Kali host | Medium-High | Phase 2 (branding + offline appliance) |
| **`debootstrap`** | minimal rootfs (DIY) | any Debian/Kali | High (reinvents live-build) | Not recommended - live-build already wraps it |
| **`kali-arm` build-scripts** | rpi/ARM SD images | Kali host + qemu | Medium | Phase 3 only if an ARM appliance is wanted |
| **WSL rootfs** | `.wsl`/rootfs tarball | any | Low-Medium | Phase 3 niche (dev/analyst-on-Windows) |

Verified facts:
- **live-build:** Kali's build-scripts were **split in 2025-2026**: the live ISO builds
  from **`kali-live`** (the old `live-build-config` URL now redirects there), the
  installer from a separate **`kali-installer`** repo. You enter `kali-live` and run
  `./build.sh --verbose`; output lands in `images/`. There is **no longer an
  `--installer` flag** in `kali-live`. **You must build a Kali ISO from within a Kali
  environment** (live-build + Kali's hooks assume a Kali host; Debian needs extra
  patching). (kali.org docs.)
- **Generic Cloud Image:** Kali began publishing **official GenericCloud images in 2025**
  (minimal, no GUI, few tools, tailorable). Distributed as a **`.tar.xz` that unpacks to a
  sparse `disk.raw`** (~25 GB virtual / ~850 MB actual) - exactly what
  `vacti-kali-droplet` records us already using on DO. Convert raw↔qcow2 with
  `qemu-img`. Customize offline with **`virt-customize`** (libguestfs-tools): install
  packages, enable services, inject cloud-init - no boot needed.
- **Trademark (kali.org/docs/policy/trademark + EULA):** The EULA grants redistribution of
  **unmodified** copies under the Kali mark only. The trademark policy says **"Please do
  not modify the marks"** and **"we do not want to confuse the public into believing they
  are dealing with us, when in fact they are not."** No OffSec marks in domain names;
  written materials should carry **"KALI LINUX ™ is a trademark of OffSec."** Net rule for
  us: **a modified build must be RENAMED and must strip Kali branding** (name, logos,
  wallpapers, `/etc/os-release`, boot splash, MOTD) and must not imply OffSec
  endorsement; "any other use … is not permitted without express written permission." For
  a derivative, also **review the license of each Kali-specific non-free package** before
  including it (Kali open-source policy). Phase 1 cloud images are internal fleet infra
  (not publicly distributed), which lowers the risk, but we should still neutralize
  branding and keep an attribution notice so the practice is clean from day one.

**Recommended pipeline (concrete):**

- **Phase 1 image build (offline, no Kali host required):**
  1. `curl -O https://kali.download/cloud-images/current/kali-linux-<ver>-cloud-genericcloud-amd64.tar.xz`
  2. `tar xJf … → disk.raw`
  3. `virt-customize -a disk.raw` to: add the vacti apt source + auth.conf, `apt-get
     install vacti-engine` (+ arsenal deps), install tailscale, drop in the hardening
     sudoers/systemd/OOM bits the postinst already writes, install the firstboot
     cloud-init config, neutralize branding, and **zero out machine-id + any identity**
     (`/etc/machine-id` truncated, `ssh_host_*` removed, apt lists cleaned) so every clone
     is fresh.
  4. `qemu-img convert -O qcow2 disk.raw vacti-engine-<ver>.qcow2` (and keep a `.raw.gz`
     for DO/biznet/idcloudhost upload).
  5. Publish to R2 / a non-app domain (see §6).
- **Phase 2 ISO build (on a Kali host / Kali container in CI):** clone `kali-live`, add a
  vacti **package-list** (`kali-config/variant-*/package-lists/vacti.list.chroot`
  referencing `vacti-engine` from our apt source) + **hooks** for branding + firstboot,
  `./build.sh --verbose`, collect `images/*.iso`.

---

## 3. WHAT to bake in

The engine box is **already fully specified** by `packaging/` - the appliance image is
"run the existing provisioning once, then snapshot." Concretely bake:

- **vacti engine:** `apt-get install vacti-engine` from the private apt repo
  (`<vacti>/api/pentest/apt`, token/Basic-auth gated). The `.deb` already carries dist +
  prod `node_modules` + `bin` + `mcp` + systemd units; the postinst writes the
  user-manager drop-in, the arsenal/deprovision/rename sudoers, and starts the service.
- **Arsenal the engine needs** (from `bootstrap-apt.sh` `APT_PACKAGES`): nmap, nuclei,
  httpx-toolkit, naabu, subfinder, ffuf, gobuster, dirsearch, sqlmap, commix, feroxbuster,
  seclists/dirb wordlists, trufflehog, dnsx/katana, the VPN clients
  (openconnect/openfortivpn/openvpn/wireguard/strongswan), the screenshot pipeline
  (xvfb/imagemagick/xdotool/qterminal/tmux), Caido, jwt_tool, pinned chromium
  (`vacti-engine-chromium`, build 1228), plus the gated per-vertical sets (mobile/iOS/RE).
  Bake the CORE + whatever `ENGINE_CAPABILITIES` the fleet default wants; the runtime
  arsenal self-heal (`arsenal-check.ts` + the `vacti-engine-arsenal-apt` NOPASSWD grant)
  fills any gap post-boot.
- **tailscale:** client installed; the reusable auth key is **NOT baked** - it is served
  from `pentest_engine_config.tailscale_auth_key_ciphertext` and the runner runs
  `sudo -n tailscale up --authkey … --hostname=<engineId>` on startup. Bake only the
  client + the `vacti-engine-tailscale` NOPASSWD grant.
- **Hardening controls (all already in `packaging/`):** non-root engine user; the three
  scoped NOPASSWD sudoers (`-arsenal-apt`, `-deprovision`, `-rename`) + the VPN netops
  wrappers; OOM hardening (`vacti.slice`, swapfile step, the user-manager mem-cap
  drop-in); `harden-journald.sh`; setcap for unprivileged port scan; the enroll-gate (now
  single-sourced through `canEnrollEngine`, fixed a61b1085).
- **Branding:** rename to a vacti product name; replace `/etc/os-release`,
  `/etc/issue`, MOTD, wallpaper, boot splash/GRUB, lightdm theme; remove Kali logos; add
  the **"KALI LINUX ™ is a trademark of OffSec"** attribution notice. A helper already
  exists in spirit (`packaging/rename-engine.sh` re-IDs an engine; branding is a separate,
  larger remaster task - Phase 2). **Do not** put a vacti product name that implies OffSec,
  and no OffSec marks in any domain.
- **Auto-update:** nothing special to bake - the shipped `vacti-engine-update.timer`
  (idle-gated, 45 min) keeps the engine current post-boot, so the IMAGE can lag the latest
  `.deb` and self-heal within a cycle. This is the key maintainability lever (§6).

---

## 4. FIRST-BOOT / ENROLLMENT

**Design goal:** a booted image auto-registers with its-ai.site **without any long-lived
secret baked into a shared image.**

- **cloud-init firstboot** (bakes the *mechanism*, not the *secret*): the image ships a
  cloud-init config + a oneshot `vacti-firstboot.service` that, on first boot, reads a
  **short-lived per-boot enroll token from instance user-data / metadata**, then runs the
  existing enroll path (`do_enroll` → `POST /api/pentest/enroll`, which is single-use +
  30-min-expiry and deletes the enroll token server-side) to obtain the 3 scoped tokens
  and write `/etc/vacti-engine/engine.env`. Tailscale joins on the engine's normal startup
  using the server-served reusable key (unchanged).
- **Per-image vs per-boot token story (critical):**
  - The **shared image** contains **zero** credentials - no enroll token, no engine token,
    no tailscale key, no `EVIDENCE_KEY`. It is inert.
  - The **enroll token is injected at provision time** per instance:
    - idcloudhost/biznet/DO: pass as cloud-init **user-data** when creating the VM via
      each provider's API (all three APIs documented in memory: idcloudhost `POST /vm`,
      biznet `POST /neolites`, DO droplet create with `user_data`).
    - Mint it right before provisioning via `mintEnrollmentTokenAction` (30-min, single
      use). If the VM is slow to boot, the firstboot service should fail loudly and the
      operator re-mints - never bake a longer-lived fallback.
  - **No shared secret ever lives in the image**, so a leaked/copied image cannot enroll
    itself or read any tenant data. This is the property Jev scored `ip_safe = high (1.0)`.
- **Fallback for manual boots** (console-only providers): the firstboot service also
  accepts the token via a well-known file the operator drops over the provider console
  (same as how `bootstrap-apt.sh --enroll <tok>` works today), so there is always a
  path even where user-data is unavailable.

---

## 5. IP PROTECTION (critical - an OS image is MORE copyable than a .deb)

The honest threat model is unchanged from `vacti-engine-distribution`: **root-on-box beats
any at-rest obfuscation.** An image makes mass-copying *easier* than a single `.deb`, so
the defense must be architectural, not cryptographic. The image is designed to carry **no
more IP than the current `.deb`, and no secret at all:**

1. **No `.claude` on disk.** `build-deb.sh` ships **0 `.claude` entries** by default
   (`VACTI_DEB_SHIP_CLAUDE` defaults off). The methodology is fetched per-engagement into
   `/dev/shm` (RAM), wiped on teardown, sha256 fail-closed. The image inherits this - it
   bakes the same `.deb`, so the crown-jewel methodology is **never at rest on the image.**
2. **Skills/prompts stripped + obfuscated in the baked `.deb`.** Per the 2026-10-10
   IP-harden wave (engine 0.2.259): `strip-skill-prose.mjs` + `strip-orchestrator-
   prompts.mjs` blank the methodology prose at build, and `obfuscate-dist.mjs`
   (javascript-obfuscator) mangles the dist. The image carries exactly that hardened
   artifact.
3. **Inert without vacti = the moat + the kill-switch.** The image cannot run an
   engagement without (a) a valid enrollment (no baked token), (b) the per-engagement
   skill-bundle fetch (403s when `trusted=false` or the engine is disabled - the license
   kill-switch), and (c) the control plane for jobs/findings/creds. A copied image is a
   bricked Kali box with an obfuscated runner that fetches nothing.
4. **No baked secret** (see §4) - the single most important image-specific rule. Every
   secret arrives per-instance or per-engagement, never in the shared image.
5. **Watermark + trust-gate stay server-side.** `VACTI_WATERMARK_SECRET` +
   `VACTI_SKILL_BUNDLE_CLAIM_ENFORCE` live on the control plane; image-served bundles stay
   traceable + claim-gated.

**Residual risk (be honest with the operator):** the baked `.deb` dist is obfuscated JS,
not a hard wall - a determined root-on-box adversary with a trusted engine can still dump
RAM during a live run. That is true of the `.deb` today; the image does **not worsen it**
(Jev `ip_safe` p.high = 1.0, conf 1.0). The one *new* image-specific caution is **mass
distribution of a single artifact**, mitigated entirely by "no baked secret + inert
without vacti." A pre-enrolled / secret-carrying image would collapse this - **never ship
one.**

---

## 6. BUILD + MAINTENANCE pipeline

- **CI builds the image per release (or per N releases).** A GitHub Actions job (sibling
  to `release-deb.yml`) runs AFTER a `.deb` is published: pull the current Generic Cloud
  Image, `virt-customize` it with the just-published `vacti-engine`, emit qcow2 + raw.gz,
  smoke-boot it in qemu with a throwaway enroll token against a staging CP, assert it
  enrolls + claims a job, then publish. Phase 2 ISO needs a **Kali container/host runner**
  (live-build requires Kali) - run it in a `kalilinux/kali-rolling` container with
  `--privileged` (loop devices).
- **Publish where:** **NOT on the app domain.** Reuse the established posture (memory:
  "distribution on a NON-penetrasi/non-app domain") - an **R2 bucket + a plain download
  domain**, or GitHub release assets on the private engine repo. Images are large
  (qcow2 ~1-2 GB); R2 egress is cheap.
- **Reproducibility:** pin the Generic Cloud Image version, the `vacti-engine` version,
  the arsenal tool set, and the chromium `.deb` (build 1228). Record a manifest
  (image sha256 + component versions) alongside each published image.
- **Image refresh vs engine auto-update (the maintainability win):** the image only needs
  to be a *recent base*. The shipped `vacti-engine-update.timer` brings any booted engine
  to the latest `.deb` within ~1 idle cycle, so images can be rebuilt **monthly / per
  Kali point-release**, not per engine release. This is exactly why Jev scored
  `maintainable = high (1.97)`. Rebuild triggers: a new Kali Generic Cloud Image, a base
  CVE, or a `.deb` change that affects first-boot (postinst/sudoers/systemd).

---

## 7. RISKS / EFFORT / phasing

| Phase | Deliverable | Effort | Risk | ROI |
| --- | --- | --- | --- | --- |
| **1** | Cloud engine-appliance image (qcow2/raw) + cloud-init auto-enroll + CI build/smoke | **~3-5 days** | Low (reuses proven parts) | **Highest** - fleet provisioning becomes "boot + token" |
| **2** | Branded live-build ISO (Kali marks removed, attribution, installer) + Kali-host CI runner | ~1.5-2.5 weeks | Medium (branding completeness, live-build on CI, trademark hygiene) | Medium - offline/on-prem + product foundation |
| **3** | Standalone product (WSL rootfs, OVA, ARM/rpi), support surface | weeks, open-ended | Medium-High (product, not infra) | Situational - only with a commercial driver |

**Top risks + mitigations:**
- *Baked secret creep* → hard rule: shared image carries no credential; secrets per-boot /
  per-engagement only. (This is the whole IP story - guard it in CI with a "no secret in
  image" scan.)
- *Image staleness* → engine self-update timer + monthly rebuild cadence.
- *live-build needs a Kali host* → run Phase 2 in a `kalilinux/kali-rolling` CI container.
- *node-pty ABI / chromium pin* → build the `.deb` on Node 22 (existing guard) and keep
  chromium build 1228; the image just bakes the already-correct `.deb`.
- *Trademark* → rename + strip Kali branding + attribution notice even for internal
  images; get written permission before any public "vacti-OS" distribution.
- *Provider quirks* → idcloudhost/biznet/DO each want a slightly different image format +
  user-data channel; the CI emits raw.gz (DO/biznet upload) + qcow2 and a per-provider
  provisioning snippet.

---

## 8. Jev vetting detail

Request: `typesafe/jev-1.13` via OpenRouter `POST /api/alpha/decisions`, state =
current distribution model + the Phase-1 recommended approach + IP/effort notes.
Response model snapshot `typesafe/jev-1.13-20260917`, cost ~$0.00007.

- `right_goal` - **Noul 0.90** → Phase 1 is a sound, on-intent first step.
- `feasible` - **Score 1.78/2 (high; p: low 0, med 0.22, high 0.78; conf 0.67)** →
  clearly feasible; the 0.22 medium mass + 0.67 confidence = resolve the §9 integration
  gaps before calling it routine.
- `ip_safe` - **Score 2.00/2 (p.high 1.00, conf 1.00)** → maximal: no worse than the
  `.deb`, inert without vacti, no baked secret. Jev is certain here *given the stated
  design* - which is a reason to hold the "no baked secret" rule absolutely.
- `maintainable` - **Score 1.97/2 (p.high 0.97, conf 0.95)** → low burden thanks to
  post-boot self-update.
- `recommend_ship` - **Noul 0.89** → proceed with Phase 1 first, phase in branding/ISO/
  product.

Interpretation: strong, consistent endorsement. The only non-maximal signal is
feasibility *confidence* (0.67), pointing at integration unknowns, not design soundness.

---

## 9. Open questions for the operator

1. **Primary intent check:** is the near-term goal the **fleet appliance** (Phase 1) or a
   **marketable branded OS** (jump to Phase 2)? The phasing assumes appliance-first.
2. **Image hosting:** R2 bucket on a non-app domain, or private GitHub release assets?
   (Same "keep distribution off the app domain" rule as the `.deb`.)
3. **Default `ENGINE_CAPABILITIES` baked into the image:** web-only lean (smallest image)
   vs full (mobile/iOS/RE verticals)? Affects image size by ~hundreds of MB.
4. **Provisioning channel per provider:** confirm we drive idcloudhost `POST /vm` /
   biznet `POST /neolites` / DO droplet-create with **cloud-init user-data** for the
   per-boot enroll token (vs a console-dropped token file for console-only providers).
5. **Rebuild cadence:** monthly + on Kali point-release + on first-boot-affecting `.deb`
   changes - acceptable?
6. **Phase 2 branding scope + name:** what product name (not implying OffSec), and do we
   want a bootable installer ISO or live-only? Written permission from OffSec is required
   before any *public* distribution of a modified build.
7. **Who builds Phase 2:** a dedicated Kali CI runner (`kalilinux/kali-rolling`
   `--privileged` container) is needed because live-build must run on Kali - provision it?

---

## Appendix - grounding facts (verified this pass)

- Engine packaging dir: `/home/vacti/vacti-pentest-engine/packaging/` - `build-deb.sh`
  (bakes dist+node_modules+bin+mcp+systemd; strips skill prose + orchestrator prompts;
  obfuscates dist; ships 0 `.claude` by default), `bootstrap-apt.sh` (107 KB; `APT_PACKAGES`
  arsenal list, `step_tailscale`, `step_vpn_netops`, `step_setcap`, `step_swapfile`,
  `do_enroll`, `write_engine_env`, `install_deb`), `systemd/` (`vacti-engine.service`,
  `vacti-engine-update.{service,timer}`, `vacti.slice`), `sudoers.d/` (arsenal-apt /
  deprovision / rename, all narrow NOPASSWD), `rename-engine.sh` + `deprovision.sh`
  (root-owned 0500 helpers), `strip-*.mjs` + `obfuscate-dist.mjs`.
- Release CI: `.github/workflows/release-deb.yml` (tag `v*` → smoke gate → build
  amd64+arm64 → `POST <vacti>/pentest/engine-deb`).
- Kali build tooling: live ISO = `kali-live` build-scripts, `./build.sh --verbose`, must
  build on a Kali host; installer = separate `kali-installer`; Generic Cloud Image =
  official since 2025, `.tar.xz`→sparse `disk.raw`, customize offline with `virt-customize`
  (libguestfs), convert with `qemu-img`.
- Trademark: don't modify the marks / don't confuse the public into thinking they deal
  with OffSec / no OffSec marks in domains / include "KALI LINUX ™ is a trademark of
  OffSec" / review Kali-specific non-free package licenses for a derivative / anything
  outside the policy needs written permission.
- Cloud providers (no native Kali image on any): DO (custom image from Generic Cloud
  Image, memory `vacti-kali-droplet`), idcloudhost (`vacti-idcloudhost-api`), biznet GIO
  (`vacti-biznet-gio`). Control plane = its-ai.site on a Hostinger VPS behind cloudflared;
  fleet + CP on a tailnet (reusable key).

Sources:
- https://www.kali.org/docs/development/live-build-a-custom-kali-iso/
- https://www.kali.org/docs/policy/trademark/
- https://www.kali.org/docs/policy/kali-linux-open-source-policy/
- https://www.kali.org/docs/policy/eula/
