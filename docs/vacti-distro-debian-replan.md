# vacti OS / distro - Debian RE-PLAN (research pass, not implementation)

Date: 2026-10-11 · Author: fanout research subagent · Status: for operator review
Scope: READ-ONLY research + re-scope. No code/git writes. Supersedes the base-OS choice in
`scratchpad/vacti-distro-research.md` (the Kali plan); the appliance/IP/enrollment design from
that doc is carried over and only the base + licensing are re-cut.

---

## 0. TL;DR

**Operator pivot:** move the vacti custom appliance OFF Kali Linux onto a lightweight **Debian**
base, to sidestep the OffSec trademark / written-permission blocker on remastering Kali entirely.

**Verdict: do it. Debian 13 "trixie" headless `genericcloud` is the right base.** It is
licensing-clean (Debian's SPI trademark policy welcomes derivatives with only rename + no-logos +
a non-affiliation disclaimer; NO written permission, unlike OffSec), it is **engine-native** (our
`.deb` already targets Debian + Node 22, and `packaging/bootstrap-apt.sh` already has a
first-class Debian-family code path), and the **full arsenal is installable on Debian at parity**.

**The key realisation:** the engine was *already built to run on Debian*. `detect_distro()` maps
`ID=debian` / `ID_LIKE=debian` to a supported `debianlike` mode, and `ensure_kali_repo_on_ubuntu()`
already adds the Kali **package repo** (pinned low, priority 100 so it never overrides base libc) so
the Kali-packaged tools install from apt without Kali being the OS. Everything else in the arsenal
installs through distro-agnostic channels (nodesource, `go install`, `pipx`, upstream scripts,
GitHub releases, Playwright). So the pivot is mostly a re-label of the base image, not a rebuild of
the toolchain.

**Jev vet (`typesafe/jev-1.13-20260917`, cost ~$0.00008):**

| Question | Answer |
| --- | --- |
| `right_base` (Debian trixie headless is the right base) | **Noul 0.93** (yes) |
| `arsenal_installable` (full arsenal on Debian w/o Kali OS) | **Score 1.92 / 2 -> high** (p.high 0.92, conf 0.88) |
| `trademark_clean` (clears the OffSec blocker + fits Debian policy) | **Noul 0.93** (yes) |
| `recommend_pivot` (proceed with Phase-1 on Debian) | **Noul 0.88** (yes) |

All green. The single soft signal (`arsenal_installable` 0.08 mass on "medium") is the **seclists
wordlist**, the one CORE item with no pre-existing non-apt fallback (§2).

---

## 1. BASE CHOICE - Debian trixie headless, confirmed

**Distribution + release: Debian 13 "trixie", current stable** (released 2025-08; the Debian cloud
team publishes and maintains official cloud images for it with cloud-init, through the trixie LTS
window). Use trixie over bookworm (12) because its `main` carries newer tool versions (ffuf 2.1.0 vs
1.1.0, gobuster 3.6.0) and a longer support horizon; keep **bookworm as a conservative fallback**
only if a provider lacks a trixie image (all the official variants exist for both). Avoid Debian
*testing/sid* as a base: unpinned churn defeats reproducibility.

**Image variant: headless `genericcloud`, no desktop environment.**

- `debian-13-genericcloud-amd64.qcow2` (~326 MB) / `...-arm64.qcow2` (~322 MB) are VM-optimised
  (virtio-only drivers), smallest, cloud-init baked in - the right appliance base on
  idcloudhost / biznet / DO.
- `generic` (~415 MB) carries extra drivers/firmware for bare-metal / unknown hypervisors - keep it
  as the on-prem/standalone variant only.
- **Headless beats Lubuntu/XFCE for the appliance:** the engine's screenshot/evidence pipeline runs
  under **Xvfb** (a virtual X server) + imagemagick/xdotool/qterminal - it needs no desktop
  environment at all. A light DE (LXQt/XFCE on Debian) is only worth adding for an *optional GUI SKU*
  (Phase 3), never the headless fleet appliance.

**Why Debian, not Ubuntu/Lubuntu** (the licensing reason, §4): Canonical's IP policy makes a
modified Ubuntu far more encumbered than a Debian derivative. Debian is also what our `.deb` and
bootstrap already target (Kali is Debian-based), so Debian is the *lowest-delta* native base.

**Arch:** amd64 primary; arm64 images exist natively for both variants, matching the engine's
existing amd64+arm64 `.deb` build (`release-deb.yml`).

---

## 2. TOOL AVAILABILITY (the crux) - full arsenal enumerated

Sources read: `packaging/bootstrap-apt.sh` (`APT_PACKAGES`, `APT_PKGS_*`, every `step_*`),
`src/runner/arsenal-check.ts` (`REQUIRED_TOOLS`, `OPTIONAL_TOOLS`, `TOOL_APT_PACKAGES`,
`TOOL_GO_PACKAGES`, `VERTICAL_TOOL_PACKAGES`, `MOBILE_*`, `SCREENSHOT_CAPS`), `build-chromium-deb.sh`.

**Only the apt subset depends on a distro repo. Everything else is already distro-agnostic:**

| Channel | Tools | Debian impact |
| --- | --- | --- |
| nodesource | Node 22 + Claude Code CLI | none (installed from nodesource if base Node too old) |
| `go install` (golang-go in Debian main) | nuclei, httpx, naabu, subfinder, dnsx, katana, gau, interactsh-client | none - go fallbacks already in bootstrap + runtime self-heal |
| `pipx` | semgrep, frida-tools, objection, pymobiledevice3, uv, jwt_tool; AD: impacket, netexec, bloodhound, certipy-ad; web3: slither | none |
| upstream script | trufflehog (`install.sh`), kubectl (dl.k8s.io) | none |
| upstream download | Caido CLI (`caido.download`), Foundry (`foundryup`) | none |
| Playwright | pinned Chromium build 1228 (`vacti-engine-chromium` .deb or self-heal download) | none |
| GitHub release zip | jadx, Ghidra, tun2proxy-bin | none |

**The apt arsenal, Debian-trixie availability (verified against packages.debian.org):**

| Tool (pkg) | In Debian main? | If not, how on Debian |
| --- | --- | --- |
| nmap, sqlmap, whatweb, dirb, default-mysql-client, nftables, ripgrep, fd-find, trivy, openssh-server, adb, socat, imagemagick, xdotool, x11-xserver-utils, qterminal, tmux, sshpass, golang-go, pipx, xvfb, fonts-noto\* | **Yes (main)** | - |
| **ffuf** (2.1.0), **gobuster** (3.6.0), **dirsearch** (0.4.3) | **Yes (main)** | - |
| VPN clients: openconnect, openfortivpn, openvpn, wireguard-tools, strongswan(-swanctl) | **Yes (main)** | globalprotect-openconnect may be absent from some Debian suites (already best-effort in bootstrap) |
| Mobile/iOS apt: scrcpy, apktool, aapt, usbmuxd, libimobiledevice-utils, libplist-utils, llvm, default-jre-headless, unzip | **Yes (main)** | - |
| RE apt (gated): gdb-multiarch, binwalk, strace, ltrace, tshark, checksec, binutils, python3-venv | **Yes (main)** | - |
| AD apt (gated): enum4linux-ng, smbclient, ldap-utils, smbmap, ntpsec-ntpdate, rlwrap, hashcat, john | mostly main; enum4linux-ng is the one to confirm | Kali repo or git if absent |
| **nuclei** | **No** | `go install` (already in self-heal) or Kali repo |
| **httpx-toolkit** (binary `httpx`) | **No** | `go install .../httpx` or Kali repo |
| **naabu** | **No** | `go install` or Kali repo |
| **feroxbuster** | **No** | Kali repo, or cargo / GitHub release (NEW bootstrap line for option B) |
| **seclists** | **No** | Kali repo, or `git clone danielmiessler/SecLists` (NEW line for option B). **dirb (main) is the degraded fallback the engine already uses.** |
| **commix** | **No** (not in trixie) | Kali repo, or git/pip (NEW line for option B) |
| **weevely** | confirm (historically Debian, may be dropped) | Kali repo or pip if absent |
| metasploit (`kali-linux-default`) | **No** | opt-in only (`VACTI_KALI_DEFAULT`, default-off); Rapid7 omnibus installer on Debian |

**Tools HARDER on Debian than Kali** = exactly the Kali-packaged pentest tools absent from Debian
`main`: **nuclei, httpx-toolkit, naabu, feroxbuster, seclists, commix, interactsh-client** (and the
PD tools dnsx/katana/subfinder/gau which were *already* go-install even on Kali). For all except
feroxbuster/seclists/commix the engine **already** has a non-apt fallback wired (go-install +
runtime self-heal in `arsenal-check.ts`). The genuine gap list to close is small:

- **seclists** (CORE content-discovery wordlist; critical - without it ffuf/dirsearch brute a
  non-existent path and the run looks clean). Today's fallback is `dirb` (Debian main), but dirb's
  lists are far smaller. This is the one item Jev's "medium" mass points at.
- **feroxbuster** (one of three content-discovery tools; ffuf + dirsearch remain in Debian main, so
  the *capability group* in `arsenal-check.ts` `CRITICAL_TOOL_GROUPS` is still satisfied - a soft,
  not critical, gap).
- **commix** (command-injection confirmation oracle; reported-tier, fail-open).

### Two sub-options for the Kali-packaged tools

- **Option A (RECOMMENDED, zero new code): Debian base + keep the Kali apt repo as a package
  SOURCE.** This is already implemented (`ensure_kali_repo_on_ubuntu`, pinned priority 100). Adding a
  third-party apt repo is **not** building a Kali derivative and puts **no Kali branding** in our
  image, so it does **not** trigger the OffSec distro-remaster / written-permission blocker. Tool
  parity with today is exact; nothing to build. Residual: a soft *infrastructure* dependency on
  `archive.kali.org` (not a legal one).
- **Option B (fully Kali-free, small added surface): Debian base + no Kali repo.** Replace the
  ~11 Kali-packaged tools with upstream sources: the PD/go tools via `go install` (already wired),
  **feroxbuster** via GitHub release/cargo, **seclists** via `git clone SecLists`, **commix** via
  git/pip, metasploit via the Rapid7 installer (opt-in). Removes even the OffSec *infra* dependency.
  Added bootstrap work is ~3 small steps; most of the fallbacks already exist.

Recommendation: ship **Option A** as the Phase-1 default (clears the legal blocker immediately with
no code change) and land **Option B's 3 bootstrap lines** (seclists git, feroxbuster release, commix
git) as a fast follow so the operator can flip `VACTI_NO_KALI_REPO=1` for a 100% OffSec-free image.

---

## 3. CLOUD IMAGE ROUTE - simpler than Kali

Debian publishes **official cloud images** natively, which Kali did not do cleanly - this is the
biggest build simplification.

- **URL pattern:** `https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-<arch>.qcow2`
  (and `.raw`, `.tar.xz`, a per-image `.json`, and `SHA512SUMS`). Variants: generic, genericcloud,
  nocloud, azure, ec2, raspi; arches amd64/arm64/ppc64el/riscv64.
- **Provider fit:** Debian is a **first-class native distro** on DigitalOcean (no custom-image upload
  needed, unlike Kali). idcloudhost / biznet take the `genericcloud` qcow2/raw as a custom image the
  same way they took the Kali Generic Cloud Image - but Debian is the format every cloud already
  expects, so fewer surprises.
- **Phase-1 appliance build (unchanged shape, simpler inputs):**
  1. `curl -O .../debian-13-genericcloud-amd64.qcow2` (+ verify against `SHA512SUMS`).
  2. `virt-customize -a debian-13-genericcloud-amd64.qcow2` to: add the vacti private apt source +
     `auth.conf`, `apt-get install vacti-engine` (which pulls the arsenal; option A also drops in the
     Kali apt source so the Kali-packaged tools resolve), install tailscale client + the scoped
     sudoers/systemd/OOM hardening the postinst already writes, install the cloud-init firstboot
     unit, and **zero identity** (truncate `/etc/machine-id`, remove `ssh_host_*`, clean apt lists)
     so every clone is fresh.
  3. `qemu-img convert -O qcow2` (keep a `.raw.gz` for idcloudhost/biznet/DO upload).
  4. Publish to R2 / a non-app download domain (same rule as the `.deb`).
- **Why simpler than the Kali route:** no `.tar.xz`->sparse-`disk.raw` unpack quirk; the image is a
  standard, widely-tested cloud base; no Kali-mark neutralisation of os-release/splash/wallpaper
  needed (Debian's neutral branding is renamed under a permissive policy); DO needs no custom upload.

---

## 4. LICENSING / TRADEMARK (accurate, not overclaimed)

**Debian (the new base) - permissive, no written permission.**

- Debian **Derivatives** are a first-class, explicitly-supported ecosystem (`wiki.debian.org/
  Derivatives`: 400+ derivatives, a Census, Guidelines, a DerivativesFrontDesk). Building a Debian
  derivative needs **no written permission**.
- The Debian **trademark policy** (owned by Software in the Public Interest, Inc.) asks only that a
  derivative: **(a)** not use "Debian" (or a confusingly-similar name) as the product/company name;
  **(b)** not use Debian logos in its own branding; **(c)** present itself as *related to but not
  part of / produced by / endorsed by* Debian, with **a non-affiliation disclaimer** on the site;
  **(d)** acknowledge SPI's ownership of the mark. "When in doubt" email `trademark@debian.org` - but
  a renamed, de-logoed derivative with a disclaimer is squarely within policy. Contrast the OffSec
  EULA/trademark regime, which permitted redistribution only of *unmodified* Kali and required
  express written permission for anything else - **that blocker is gone.**

**Ubuntu/Canonical (why we avoid it as the base).** Canonical's IP policy is materially stricter:
"You can redistribute Ubuntu, but only where there has been no modification to it." A modified build
that keeps the marks needs Canonical's **approval/certification, via a licence agreement for which
you may be required to pay**; otherwise "you must remove and replace the Trademarks and **will need
to recompile the source code**." Recompiling to strip marks is exactly the kind of friction the
pivot is meant to avoid, so Ubuntu/Lubuntu are rejected as the base.

**GPL / mixed-source obligation (be precise).** A Debian base is GPL/mixed, **not** "MIT" - and that
is fine. We redistribute **unmodified** Debian binary packages, so we satisfy the GPL/LGPL
written-offer by **pointing to Debian's already-public source mirrors** (`deb-src`,
`snapshot.debian.org`) rather than mirroring sources ourselves; if we ever rebuild a package we mirror
that one's source. **Our own engine keeps its own license** (proprietary, obfuscated dist) - the base
OS license does not reach into our package.

**Net:** the Debian pivot removes the OffSec written-permission blocker entirely. The only standing
obligations are trivial: rename + no-Debian-logos + a disclaimer + an SPI acknowledgement + the
standing GPL source-pointer. Option A's use of the Kali *apt repo* is ordinary package consumption,
not distribution of Kali, so it carries no Kali-trademark obligation on our image.

---

## 5. UPDATED PHASED PLAN

**Phase 1 (committed primary) - Debian headless engine-appliance image.** Same design as the Kali
plan's Phase 1, re-based:

- Base: `debian-13-genericcloud-amd64.qcow2` (+ arm64), customised offline with `virt-customize` +
  cloud-init firstboot auto-enroll (short-lived per-boot enroll token from instance user-data; the
  existing single-use/30-min `do_enroll` -> `POST /api/pentest/enroll` path).
- Arsenal: `apt-get install vacti-engine` + the bootstrap arsenal. **Option A:** the Kali apt repo
  (already coded) resolves nuclei/httpx/feroxbuster/seclists/commix; go/pipx/release fallbacks cover
  the rest. Bake the CORE + the fleet-default `ENGINE_CAPABILITIES`; runtime self-heal fills gaps.
- Branding is now **freely ours** - pick a vacti product name, set `/etc/os-release`, issue, MOTD;
  no OffSec attribution, no mark-stripping, add the Debian non-affiliation disclaimer + SPI notice.

**Phase 2 - branded installer/live ISO, now on plain Debian.** Build with **Debian `live-build`**
on any Debian host or an ordinary Debian CI container - **no Kali-only `kali-live` + `--privileged`
Kali runner** required. This removes a whole class of Phase-2 risk from the Kali plan.

**Phase 3 (optional) - product SKUs:** standalone/on-prem (the `generic` image), a GUI SKU (light
XFCE/LXQt), WSL rootfs, OVA, ARM/rpi (Debian raspi image). Situational.

**IP-protection design carries over UNCHANGED** (Kali-plan §5): the shared image carries **no
credential** (no enroll token / engine token / tailscale key / `EVIDENCE_KEY`); **no `.claude`** on
disk (methodology fetched per-engagement into `/dev/shm`, wiped on teardown); skills off-box + the
`.deb` dist stripped + obfuscated; **inert without vacti** (enrollment + per-engagement
trust-gated skill-bundle fetch = the license kill-switch). Debian changes none of this.

### Simpler vs the Kali plan

1. **Official cloud images, native on every cloud** (DO needs no custom upload); no `.tar.xz`->raw
   unpack quirk.
2. **Licensing freedom:** no OffSec written permission, no Kali-mark neutralisation of
   os-release/splash/wallpaper; branding is ours under a permissive Debian policy.
3. **Phase-2 ISO builds on plain Debian/CI** - the "live-build must run on Kali" + `--privileged`
   Kali-container risk is gone.
4. **Zero toolchain rework for Phase 1** - the bootstrap already supports Debian-family hosts.

### New / changed risks

1. **Tool parity now rests on a choice:** option A = a soft *infra* dependency on `archive.kali.org`
   (legal-clean); option B = ~3 new bootstrap lines (seclists/feroxbuster/commix) to be fully
   Kali-free. Mitigation: ship A now, land B's lines as a fast follow behind `VACTI_NO_KALI_REPO=1`.
2. **seclists is the one CORE Debian-missing item with a weaker fallback (dirb).** Close it with the
   Kali repo (A) or a `git clone SecLists` step (B) before relying on content discovery; add a CI
   assertion that a content-discovery wordlist resolves on the built image.
3. **Debian stable lags Kali rolling on some lib versions** - largely irrelevant because the
   load-bearing components are pinned/self-sourced (Node via nodesource, Chromium via Playwright,
   Caido + PD tools self-installed), but pin the base image version in the build manifest.

---

## 6. OPEN QUESTIONS FOR THE OPERATOR

1. **Option A vs B as the default:** ship A (keep the Kali apt repo, zero code, legal-clean) now and
   add B's Kali-free bootstrap lines as a fast follow? Or go straight to B (fully OffSec-free infra)?
2. **Product name + branding** (now freely ours): what vacti OS name, and confirm the Debian
   non-affiliation disclaimer + SPI acknowledgement wording for `/etc/os-release` + the download page.
3. **trixie vs bookworm** as the pinned base (recommend trixie; bookworm only as a provider fallback).
4. **Default baked `ENGINE_CAPABILITIES`** (web/infra lean vs full verticals) - unchanged question
   from the Kali plan, drives image size.
5. **seclists sourcing** on the image: Kali repo (A) or baked `git clone SecLists` (B)?

---

## Appendix - grounding facts (verified this pass)

- Engine already Debian-ready: `packaging/bootstrap-apt.sh` `detect_distro()` (ID=debian/ID_LIKE ->
  `debianlike`, supported) + `ensure_kali_repo_on_ubuntu()` (adds `deb .../kali kali-rolling ...`
  pinned `Pin-Priority: 100`). Install channels per tool enumerated in §2 from `APT_PACKAGES`,
  `step_apt` (go/script fallbacks), `step_python`/`step_ad_arsenal` (pipx), `step_caido`,
  `install_pinned_chromium`, `step_jadx`/`step_ghidra` (GitHub release).
- `src/runner/arsenal-check.ts`: `REQUIRED_TOOLS` (nmap/naabu/nuclei/httpx/ffuf/gobuster/dirsearch/
  sqlmap/whatweb/feroxbuster), `TOOL_APT_PACKAGES` (httpx->httpx-toolkit, fd->fd-find, ...),
  `TOOL_GO_PACKAGES`+`TOOL_GO_VERSIONS` (interactsh/dnsx/gau pinned go installs), content-discovery
  is a capability GROUP (ffuf|feroxbuster|dirsearch - any one satisfies it), `WORDLIST_APT_PACKAGES`
  (seclists, dirb).
- Debian trixie = current stable (2025-08); official cloud images at
  `cloud.debian.org/images/cloud/trixie/latest/` (genericcloud qcow2 ~326MB + raw ~3GB, generic,
  nocloud, azure, ec2, raspi; amd64/arm64/ppc64el/riscv64; `SHA512SUMS`). Verified in Debian main:
  ffuf 2.1.0, gobuster 3.6.0, dirsearch 0.4.3. Verified NOT in trixie: nuclei, feroxbuster, seclists,
  commix.
- Debian trademark (SPI): derivatives allowed; rename, no-logos-in-branding, non-affiliation
  disclaimer, acknowledge SPI; no blanket written permission. Debian Derivatives program
  (`wiki.debian.org/Derivatives`, 400+ derivatives).
- Ubuntu/Canonical IP policy: redistribute only unmodified Ubuntu; modified + marks needs a (paid)
  Canonical licence, else "remove and replace the Trademarks and ... recompile the source code".

Sources:
- https://packages.debian.org/search?keywords=nuclei (no results)
- https://packages.debian.org/src:ffuf ; .../gobuster ; trixie dirsearch (0.4.3, misc)
- https://packages.debian.org/search?suite=trixie&keywords=seclists (no results),
  .../feroxbuster (no results), .../commix (no results)
- https://cloud.debian.org/images/cloud/trixie/latest/
- https://www.debian.org/trademark ; https://wiki.debian.org/Derivatives
- https://canonical.com/legal/intellectual-property-policy
- https://www.debian.org/releases/trixie/release-notes/installing.en.html
