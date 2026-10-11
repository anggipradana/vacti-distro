# vacti Pentest Distro — Base OS Survey & Recommendation

**Date:** 2026-10-11 · **Scope:** BASE SELECTION only (tool-availability + cloud-image + licensing detail is the parallel `vacti-distro-debian-replan.md` agent). READ-ONLY research + this doc.

## Constraints (operator)
- **NOT bare/raw** — Kali-like readiness out of the box (not minimal-Debian raw).
- **As lightweight as possible.**
- **Permissive** — no OffSec/Canonical-style trademark or written-permission blocker. A Debian-family derivative policy is fine.
- **Stack-compatible:** glibc (NOT musl), systemd (engine ships systemd units + timers), Node 22, Chromium/Playwright, full arsenal (sqlmap/nuclei/ffuf/nmap/caido/mitmproxy/jwt_tool/…).
- **Cloud-image** (qcow2/raw) for idcloudhost / biznet / DO provisioning.

Two use cases:
1. **Headless engine APPLIANCE** — we bake it fully, so "raw" is MOOT. Lightest headless base wins + cloud-image + permissive.
2. **GUI pentest-OS PRODUCT** — "not raw" + a light DE matters.

---

## Scorecard

Legend: Y = yes/good, ~ = partial/with-caveat, N = no/blocker.

| Candidate | Upstream base | Light | Not-raw/ready | Permissive (no written-perm) | glibc | systemd (default) | Stack compat | Cloud image (qcow2/raw) |
|---|---|---|---|---|---|---|---|---|
| **Debian (min + light DE we polish)** | — (upstream) | Y | ~ (we provide it) | **Y** (DFSG) | **Y** | **Y** | **Y** | **Y** (official genericcloud/generic + cloud-init) |
| **MX Linux** | Debian 13 stable | Y (XFCE/Fluxbox) | **Y** (MX Tools, ready) | Y (DFSG, no written-perm) | Y | ~ (systemd variant on same ISO; sysVinit historical default) | Y | **N** (ISO/live only) |
| **SpiralLinux** | Debian (pure + polish) | Y | Y (sensible defaults) | Y (DFSG, uses official Debian repos) | Y | Y (standard Debian) | Y | N (ISO/live only) |
| **SparkyLinux** | Debian (testing/stable) | Y (LXQt/Openbox/Xfce) | Y | Y | Y | Y | Y | N |
| **BunsenLabs** | Debian stable + Openbox | Y (very light) | Y (CrunchBang heir) | Y | Y | Y | Y | N |
| **Q4OS** | Debian stable | Y (Trinity/Plasma) | Y | Y | Y | Y | Y | N |
| **LXLE** | **Ubuntu LTS** | Y (LXDE/LXQt) | Y | **N** (inherits Canonical IP) | Y | Y | Y | N |
| **Bodhi** | **Ubuntu LTS** | Y (Moksha) | Y | **N** (inherits Canonical IP) | Y | Y | Y | N |
| **antiX** | Debian stable | **Y** (lightest Debian) | Y | Y | Y | **N** (sysVinit/runit, no systemd) | ~ (needs systemd re-add) | N |
| **Devuan** | Debian fork | Y | ~ | Y | Y | **N** (sysvinit/runit/OpenRC, systemd-free by design) | ~ (needs systemd re-add) | ~ (has some images, but no systemd) |
| **Alpine** | — (independent) | **Y (lightest)** | N | Y | **N (musl)** | **N (OpenRC)** | **N** (Playwright/Chromium need glibc 2.17+; Node native modules) | Y (but moot) |
| Ubuntu / Lubuntu | — (Canonical) | ~ | Y | **N** (license agreement + written permission for modified branded images) | Y | Y | Y | Y |

---

## Key findings per candidate

### Debian (self-polished: minimal headless + light-DE GUI)
- The "we provide the readiness" baseline. glibc + systemd by default + DFSG-permissive (no trademark/written-permission blocker) + the ONLY candidate with **official cloud images**: `cloud.debian.org` publishes `generic`, `genericcloud` (reduced-driver, smallest), `nocloud`, plus azure/ec2 builds as qcow2 with cloud-init — runs on OpenStack/DigitalOcean/bare-metal/idcloudhost/biznet. Trixie (Debian 13) is current.
- "Raw" is only a concern for the GUI product, solved by shipping a preconfigured LXQt/XFCE + our tooling — which is effort we own but control fully.

### MX Linux — the leading light+ready+popular Debian derivative
- Debian **Stable 13 "trixie"** base; current MX-25.3 "Infinity" (2026-09-20), point releases ~every 4 months. XFCE main (also KDE, Fluxbox; AHS = newer kernel/GPU). Ready out-of-box (MX Tools). DFSG-compliant, no stated trademark/written-permission blocker.
- **Init caveat (now resolved in our favour):** MX-25 ships **systemd variants on the same ISO** (Xfce, Xfce-AHS, Fluxbox also have sysVinit variants; 25.1+ supports both). So MX CAN boot systemd → our systemd units work. Historically sysVinit was the default, so this is a selectable variant, not the historical posture.
- **Weak spot:** No official cloud/qcow2 image — ISO/live only. Appliance provisioning via cloud-init on idcloudhost/biznet/DO would need us to build our own image. Also a small downstream team = lag vs. upstream Debian.

### SpiralLinux — "pure Debian done nicely"
- By the GeckoLinux creator; built on **Debian using the official Debian repositories** (no third-party repo divergence), Calamares installer, 8 editions incl. XFCE/LXQt. Standard Debian = systemd + glibc. Essentially Debian + sensible defaults/codecs/Btrfs snapshots — the lowest-divergence "ready" option. ISO/live only (no cloud image). Strong GUI-product alternative; near-indistinguishable from self-polished Debian but someone else maintains the polish.

### SparkyLinux / BunsenLabs / Q4OS (light Debian-family, systemd, glibc)
- **SparkyLinux:** Debian-based, rolling (testing branch) + stable branch; LXQt/Openbox/Xfce; very forgiving requirements. systemd/glibc.
- **BunsenLabs:** Debian **stable** + Openbox (CrunchBang continuation) — very light, customizable. systemd/glibc.
- **Q4OS:** Debian stable + Trinity (TDE)/Plasma — light, permissive. systemd/glibc.
- All permissive Debian-family, no cloud image. Viable GUI-product bases but smaller/niche than MX.

### antiX + Devuan — FLAG: no systemd (likely incompatible)
- **antiX:** lightest Debian-based, but **sysVinit/runit — no systemd**. **Devuan:** Debian fork explicitly systemd-free (sysvinit/runit/OpenRC, selectable since 3.1), whole raison d'être is avoiding systemd.
- Our engine **ships systemd units + timers** → both are **incompatible unless we re-add systemd**, which fights the distro's design and loses the reason to pick them. **Recommend SKIP** (unless a future systemd-free engine mode is built — not planned).

### Alpine — lightest, but musl is a BLOCKER (SKIP)
- Lightest of all, BUT **musl libc, not glibc**: Playwright's driver **requires glibc 2.17+**; its bundled Chromium is a glibc build; glibc-compiled binaries "will not run by default" on Alpine and the `alpine-pkg-glibc` shim is **not supported by Alpine**. Node native modules and glibc-assuming pentest tools break too. Also defaults to **OpenRC, not systemd**. **Confirmed BLOCKER → SKIP** for our stack.

### Ubuntu / Lubuntu / LXLE / Bodhi — avoid (Canonical IP policy)
- Canonical's IP Rights Policy: redistribution of **modified** Ubuntu associated with the Trademarks **requires Canonical approval/certification via a license agreement (which may carry a fee)**; otherwise trademarks must be removed/replaced and sources recompiled. Trademark use needs **Canonical's permission in writing**. This is exactly the "written-permission blocker" the operator wants to avoid — **stricter than Debian's DFSG**. **LXLE and Bodhi are Ubuntu-based** and inherit this. Avoid Ubuntu family as base.

---

## Recommendation

### Per use case
- **(1) Headless engine APPLIANCE:** **Debian Stable `genericcloud` (or `netinst`) minimal** — rawness is moot (we bake the arsenal), it's the lightest *practical* glibc+systemd base, DFSG-permissive, and the ONLY option with official qcow2/raw + cloud-init for idcloudhost/biznet/DO. Fits our existing `.deb` + enrollment distribution model directly.
- **(2) GUI pentest-OS PRODUCT:** **MX Linux (XFCE, systemd variant)** if we want out-of-box readiness we don't have to build — OR **Debian + preconfigured LXQt/XFCE** (or **SpiralLinux XFCE**) if we want to own the desktop layer and keep one base for both.

### PRIMARY single pick
**Debian Stable (trixie/13) as the one canonical base, with two build profiles** — minimal headless for the appliance, Debian + light DE (LXQt/XFCE) for the GUI product.

**Why:** wins every hard constraint — glibc, systemd-by-default, most permissive (DFSG, zero written-permission), full stack/arsenal compatibility, and uniquely official cloud images. One base = one security-update stream, one toolchain, no small-downstream lag. The only "loss" is out-of-box desktop readiness, which we supply via a preconfigured DE profile (same way we already bake the appliance).

**Trade-offs:** We must build/maintain the GUI readiness layer ourselves (effort), and Debian is not the *absolute* lightest (antiX/Alpine are lighter — but both are disqualified on systemd/musl). Accepting a slightly-larger-than-lightest base is the price of full stack compatibility.

**FALLBACK:** **MX Linux** (Debian 13 stable, XFCE, systemd-variant ISO) for the GUI product when we'd rather adopt an already-ready desktop than build one — accepting no official cloud image and downstream lag. **SpiralLinux** is the closest "pure-Debian-with-polish" middle ground.

---

## Jev vet (typesafe/jev-1.13) — primary = Debian Stable, two profiles, MX fallback

| Question | Type | Answer | Read |
|---|---|---|---|
| Lightweight constraint satisfied | score (0–2) | **1.61** (conf 0.43; P: light 0.38 / lightest 0.62) | Light but honestly not the absolute lightest — matches that we rejected lighter bases (antiX/Alpine) for compatibility. |
| Readiness constraint satisfied | score (0–2) | **1.85** (conf 0.78; P lvl2 0.85) | Readiness well covered: moot for baked appliance, ready DE for GUI. |
| Permissive (no written-perm blocker) | noul | **0.93** | Strong yes — DFSG, no trademark blocker. |
| Fully stack-compatible (glibc/systemd/stack) | noul | **0.81** | Yes. |
| Debian best SINGLE primary (vs MX) | noul | **0.92** | Strong yes — Debian over MX as the one base. |

Jev endorses the primary: strongly permissive, stack-compatible, ready, and Debian over MX as the single base. The only soft signal is "lightweight" (1.61) — an accepted, deliberate trade-off (compatibility over absolute minimalism). Cost: $0.0000536.
