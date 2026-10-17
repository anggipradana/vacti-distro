# Vacti OS — Pre-Login Engine Provisioning / Activation (impl-ready design)

READ-ONLY design refresh. Re-established against the CURRENT `anggipradana/vacti-distro`
(`/home/vacti/vacti-distro`, HEAD `f11745c`) and `vacti-pentest-engine`
(`/home/vacti/vacti-pentest-engine`). Nothing is implemented here. Implementation is a
separate, serialized distro-repo change AFTER the running 0.1.0 build finishes.

Vetted by Jev (`typesafe/jev-1.14-20261014`) — probabilities inline in §7.

---

## 0. Goal (operator: "bener2 mateng")

A user must be able to ENROLL / PROVISION the engine WITHOUT logging into the desktop OS:
a pre-login activation front door. On the GUI SKU the box boots to an activation kiosk
(network → enroll), and the normal LightDM desktop login is withheld until the box is
enrolled (`/etc/vacti-engine/engine.env` exists). Headless keeps cloud-init/networkd and
gains a `vacti-netsetup` TUI. Calamares-installed systems inherit the gate. The REAL moat
stays `engine.env` + the server-side token kill-switch; the pre-login gate is a mandatory
UX front door and defense-in-depth, not the security boundary.

---

## 1. Current repo state — what EXISTS vs what the prior design ASSUMED

### CONFIRMED (integration points that still hold)

- **The enroll mechanism is real and complete.** `distro/enroll/firstboot/vacti-firstboot`
  is the one first-boot code path behind every channel (file-drop
  `/etc/vacti-engine/enroll.token`, NoCloud `/run/vacti/enroll.env` /
  `/var/lib/cloud/instance/vacti-enroll.env`, kernel cmdline `vacti.enroll_token=`).
  It POSTs `Bearer <token>` to `<url>/api/pentest/enroll` with `{"engine_id":...}`,
  receives `{producer,verifier,gatekeeper}`, writes `/etc/vacti-engine/engine.env` (0600),
  starts `vacti-engine.service`, disables itself. **This is exactly the hook the kiosk
  must drive — the pre-login flow is a front-end that supplies a token to this script,
  not a new enroll path.**
- **`engine.env` is the gate key and already exists as a concept.**
  `vacti-firstboot.service` and `vacti-firstrun.service` already use
  `ConditionPathExists=!/etc/vacti-engine/engine.env`. The engine `.deb`'s systemd units
  (`vacti-engine.service`, `vacti-submission-runner.service`, `vacti-engine-update.service`)
  all `EnvironmentFile=/etc/vacti-engine/engine.env`. So "no engine.env ⇒ inert engine" is
  already true; gating LightDM on the same path is consistent.
- **LightDM IS the GUI display manager** and is already brand-themed.
  `vacti-gui.list.chroot.in` installs `lightdm` + `lightdm-gtk-greeter` +
  `network-manager-gnome` + `plymouth`. `apply-branding.sh` §8 installs the greeter theme
  only when `/etc/lightdm` exists (GUI SKU). `network-manager-gnome` (hence
  `nm-connection-editor`) is ALREADY in the GUI package list.
- **`vacti-firstboot` already enumerates "a GUI first-run dialog" as a token source** (file
  drop to `TOKEN_FILE=/etc/vacti-engine/enroll.token`). The kiosk writing that file is an
  intended, pre-wired channel — no script change required for the happy path.
- **ISO carries the enroll unit into the installed system today.**
  `preseed.cfg` `late_command` does `in-target systemctl enable vacti-firstrun.service`;
  `0100-branding.hook.chroot` enables it in the live/chroot too. The Calamares carry-through
  point is a known, working seam.
- **The build is single-source.** `vacti-appliance.env` drives both
  `golden-image/build-golden.sh` (virt-customize, cloud/OVA) and
  `live-build-config/build-iso.sh` (`lb`, ISO). Branding/enroll/packages are materialized
  from the shared `distro/` tree by both. New units/scripts added under `distro/enroll/` +
  `distro/branding/` + the GUI package list land in BOTH forms automatically if staged the
  same way (see §2 staging table).
- **Engine VPN registry exists** (`src/runner/vpn/index.ts`,`registry.ts`,`driver.ts`):
  GlobalProtect/Fortinet/AnyConnect/OpenVPN/WireGuard/Pritunl/IPsec, **additive, per-engagement,
  CP-driven, POST-enroll** (uploaded `VpnProfile` → tunnel egress to a target).

### DRIFTED / NEVER-BUILT (the prior design's net-new surface)

- **There is NO `vacti-activate` kiosk, NO LightDM gating drop-in, NO pre-login network UI.**
  Grep for `lightdm|vacti-activate|kiosk|ConditionPathExists|nm-connection|nmtui|netsetup`
  returns only: the two firstboot units' `engine.env` condition, the greeter THEME install,
  and VPN tool package names. **The entire pre-login gate is greenfield.** The prior
  session's doc described intent that was never committed.
- **`vacti-firstrun.service` on the ISO lives in `includes.chroot` only** (it is copied in
  step 3 of `build-iso.sh`). The golden path has `vacti-firstboot.service`. Any new
  activation units must be staged in BOTH drivers or they ship on only one form.
- **The engine VPN registry is the WRONG layer for pre-login host VPN.** It tunnels a
  *target* egress per engagement after enrollment; it cannot bring the *host* onto a
  corporate VPN so the box can reach the CP to enroll. Pre-login host VPN must be the
  host/NetworkManager layer (GUI: NM VPN plugins; headless: `nmcli`/`wg-quick`/`openconnect`
  CLI). **Flag this in impl: do not wire the kiosk "VPN" button to the engine registry.**
- **`network-manager` (core) is only pulled on the GUI SKU** via `network-manager-gnome`.
  Headless has `systemd-networkd` + cloud-init; `VACTI_HEADLESS_NM=1` must *add* NM, which
  conflicts with networkd unless one is disabled (see §4).
- `make-seed.sh` is still a documented STUB (not load-bearing for the GUI kiosk path).

---

## 2. Architecture

```
            ┌────────────────────────── BOOT ──────────────────────────┐
GUI SKU:    plymouth → [gate decision] → vacti-activate kiosk (Xorg,    │
            │              │              no DM, network→enroll)        │
            │              │                     │ writes enroll.token  │
            │              │                     ▼                      │
            │              │              vacti-firstboot (existing)    │
            │              │                     │ writes engine.env    │
            │              ▼                     ▼                      │
            │   engine.env EXISTS ───────► LightDM desktop login        │
            └──────────────────────────────────────────────────────────┘
Headless:   boot → cloud-init/networkd → vacti-firstboot (token from seed)
                 └─ no token + interactive TTY → vacti-netsetup TUI (opt)
```

Gate key = presence of `/etc/vacti-engine/engine.env`. One predicate, three enforcers:
LightDM drop-in (GUI desktop), the activation kiosk unit (GUI pre-login), and the existing
firstboot/firstrun units (enroll itself). All three use the SAME `ConditionPathExists`.

### Staging table (where each new file must be wired so it ships in ALL forms)

| New artifact | Golden (`build-golden.sh`) | ISO (`build-iso.sh`) |
| --- | --- | --- |
| `vacti-activate` script, kiosk/session units | add to the `cp -a ENROLL_DIR/...` block (§ "firstboot unit + script", lines ~86-90) → STAGE `/usr/local/sbin` + `/etc/systemd/system` | add an `install -D` in step 3 (beside the firstrun copy) |
| LightDM gate drop-in | stage into `/etc/systemd/system/lightdm.service.d/` (GUI-only; harmless if lightdm absent) | same, GUI SKU branch (step 4) |
| `vacti-netsetup` TUI | stage `/usr/local/sbin` | step 3 |
| GUI activation packages (xinit/openbox/nm, see §3) | n/a (golden is headless cloud) | append to `vacti-gui.list.chroot.in` |

---

## 3. GUI SKU — the pre-login kiosk (`network → enroll`)

### Files to ADD (distro repo)

1. **`distro/enroll/activate/vacti-activate`** (`/usr/local/sbin/vacti-activate`, 0755)
   The kiosk controller. Runs as an unprivileged `vacti-activate` user inside a minimal
   Xorg session (no window manager chrome beyond a kiosk WM). Flow, strictly
   network-then-enroll (Jev 0.89):
   - **Stage A — network.** Launch `nm-connection-editor` (already packaged) for
     Wi-Fi/wired/802.1x/DNS; expose "Proxy" (writes `/etc/vacti-engine/proxy.env` →
     consumed as `WEB_PROXY`/`HTTPS_PROXY` by the enroll curl and later by the engine) and
     "VPN" (NM openvpn/wireguard/openconnect/strongswan plugins — HOST layer, see §6).
     Offer "Tailscale" (`tailscale up`, reusable key entered or via the CP). Gate "Next"
     on a reachability probe to the CP URL the user typed (curl HEAD, 10s).
   - **Stage B — enroll.** Collect (i) control-plane URL and (ii) the enrollment
     token ("license"). On submit, write them to `/etc/vacti-engine/enroll.token`
     (line 1 = token, line 2 = url — exactly the format `vacti-firstboot` already parses),
     `chmod 0600`, then `systemctl start vacti-firstboot.service` and stream its journal to
     the kiosk. On success (`engine.env` appears) show "Activated — starting desktop" and
     exit; the gate flips and LightDM is now allowed (see §3 gate logic).
   - **Air-gap (opt-in).** A secondary tab "Offline key" accepts a signed license file; this
     is the ONLY place the offline signed key appears, opt-in, air-gap only.
   - Token value is NEVER logged; the script defers all crypto/token parsing to the existing
     `vacti-firstboot` (single source of truth).

   Implementation note: keep the UI LIGHTWEIGHT and renderer-agnostic (per the
   works-everywhere rule) — a YAD/zenity GTK dialog set or a small GTK3 python app over
   plain Xorg; no GPU/compositor assumptions.

2. **`distro/enroll/activate/vacti-activate.service`**
   (`/etc/systemd/system/vacti-activate.service`)
   ```
   [Unit]
   Description=vacti pre-login activation kiosk
   After=systemd-user-sessions.service plymouth-quit-wait.service
   After=network-online.target
   Wants=network-online.target
   Conflicts=getty@tty1.service
   ConditionPathExists=!/etc/vacti-engine/engine.env      # only before enrollment
   ConditionPathExists=/usr/bin/lightdm                   # GUI SKU only
   [Service]
   Type=simple
   # run a bare Xorg on vt1 + the kiosk; unprivileged user, polkit rule allows NM/tailscale
   ExecStart=/usr/local/sbin/vacti-activate
   Restart=on-failure
   RestartSec=2
   StartLimitIntervalSec=120
   StartLimitBurst=5                                       # after N crashes → fail OPEN (§3 fail)
   TTYPath=/dev/tty1
   StandardInput=tty
   [Install]
   WantedBy=graphical.target
   ```

3. **`distro/branding/greeter/lightdm.service.d/10-vacti-gate.conf`**
   (`/etc/systemd/system/lightdm.service.d/10-vacti-gate.conf`) — the GATE:
   ```
   [Unit]
   # No desktop login until the box is enrolled. The activation kiosk owns tty1
   # until engine.env exists; LightDM starts only once it does.
   ConditionPathExists=/etc/vacti-engine/engine.env
   After=vacti-activate.service
   ```
   Rationale: a drop-in `ConditionPathExists=` is the least-invasive, upgrade-safe way to
   withhold the DM (does not edit the packaged unit). When the kiosk writes `engine.env`
   and exits, a `systemctl start lightdm` (issued by `vacti-activate` on success) now passes
   its condition.

4. **`distro/enroll/activate/vacti-activate-polkit.rules`**
   (`/etc/polkit-1/rules.d/49-vacti-activate.rules`) — allow the unprivileged kiosk user to
   drive NetworkManager + tailscale + start `vacti-firstboot.service`/`lightdm.service`
   only (narrow, named actions; no blanket admin).

### Packages to ADD to `vacti-gui.list.chroot.in`
`xserver-xorg xinit openbox` (or `matchbox-window-manager`) for the bare kiosk X session,
`network-manager` (core; `-gnome` is already there), `network-manager-openvpn-gnome`
`network-manager-openconnect-gnome` `network-manager-wireguard`/`wireguard-tools`
`network-manager-strongswan` (HOST-VPN plugins, §6), `yad` or `zenity` (or
`python3-gi gir1.2-gtk-3.0`) for the dialogs, `polkit`.

### Gate logic (GUI)
- `engine.env` ABSENT → `vacti-activate.service` wins tty1 (`graphical.target` pulls it;
  `lightdm.service` condition fails, so no DM race). Kiosk runs network→enroll.
- Kiosk success → writes `engine.env` (via firstboot) → kiosk `systemctl start lightdm` →
  desktop login appears. On next boot the kiosk condition is false and LightDM starts
  normally.
- **FAIL-OPEN (Jev 0.78).** If the kiosk itself crash-loops past `StartLimitBurst`, systemd
  stops restarting it; a companion `vacti-activate-fallback.service`
  (`ConditionPathExists=!/etc/vacti-engine/engine.env`, ordered `After=vacti-activate.service`,
  started only if the kiosk entered `failed`) drops a plain getty + an on-screen note so the
  box is never bricked by a kiosk bug. The engine stays inert without `engine.env` regardless,
  so failing open costs no security. The USER DECLINING (quitting the kiosk) is distinct: that
  returns to the kiosk, not to a desktop — declining is not a crash.

---

## 4. Headless SKU — unchanged defaults + opt-in TUI

- **Default stays cloud-init + systemd-networkd** (Jev 0.78). The existing
  `vacti-firstboot` already consumes the NoCloud/metadata/cmdline/file channels; headless
  provisioning via a `cidata.iso` seed is the primary, zero-touch path and is untouched.
- **ADD `distro/enroll/netsetup/vacti-netsetup`** (`/usr/local/sbin/vacti-netsetup`, 0755):
  an interactive TUI (whiptail/dialog — already pullable) for an operator on a console with
  NO seed: set static IP/DNS/route (writes a `systemd-networkd` `.network` drop-in),
  optional proxy (`/etc/vacti-engine/proxy.env`), optional host VPN via CLI
  (`wg-quick`/`openconnect`/`nmcli` if NM present), then prompt for URL+token → write
  `/etc/vacti-engine/enroll.token` → `systemctl start vacti-firstboot.service`. It is the
  console twin of the GUI kiosk's enroll stage.
  - Wire it as an **ExecStartPre hint / `After` of a getty**, or document `vacti-netsetup`
    as an operator command in the MOTD when `engine.env` is absent (the branding MOTD
    already renders on console). Do NOT auto-seize all TTYs on headless — that would break
    the seed/zero-touch path.
- **`VACTI_HEADLESS_NM=1`** (new knob in `vacti-appliance.env`): when set, the build installs
  `network-manager` and the provision/hook **masks `systemd-networkd`** (and lets cloud-init's
  `network: renderers: [NetworkManager]` or a `/etc/NetworkManager/conf.d` take over) so the
  two renderers never fight over the same links. Default 0 = networkd, exactly as today.

---

## 5. ISO-installed systems (Calamares) — carry the gate through (Jev 0.86)

The live session gets the kiosk via `graphical.target` like any boot. The INSTALLED system
must also boot gated+unenrolled. Calamares copies the live rootfs (`unpackfs`) so the units
and drop-ins travel automatically PROVIDED they are enabled in the chroot. Concretely:

- **In `0100-branding.hook.chroot`** (ISO chroot hook), alongside the existing
  `systemctl enable vacti-firstrun.service`, ADD (GUI SKU only):
  `systemctl enable vacti-activate.service` and ensure the `lightdm.service.d` gate drop-in
  is present in the chroot (it is, via includes.chroot staging). This makes the enabled
  symlinks + drop-in part of the squashfs → copied verbatim into the installed system.
- **`preseed.cfg` `late_command`** (headless install) already enables `vacti-firstrun`; add
  nothing for headless beyond optionally enabling `vacti-netsetup`'s MOTD hint.
- **Calamares caveat.** `settings.conf` runs the `machineid` module (regenerates
  `/etc/machine-id`) and `networkcfg` — fine. No change needed to the module sequence; the
  gate is unit-level, not a Calamares module. Verify the installed system's first boot has
  `engine.env` ABSENT (it will — no secret is ever baked; Calamares copies the live rootfs
  which the no-secret scan guarantees carries no `engine.env`).
- The installed GUI system therefore boots → kiosk (network→enroll) → LightDM, identical to
  live. One behavior across live, cloud, OVA, and installed.

---

## 6. VPN — two DISTINCT layers (Jev 0.93)

- **Pre-login HOST VPN (new, distro-side):** so the box can REACH the CP to enroll when it
  sits behind a corporate VPN. GUI: NetworkManager VPN plugins (openvpn/openconnect/
  wireguard/strongswan) surfaced by the kiosk's "VPN" button. Headless:
  `nmcli`/`wg-quick`/`openconnect` in `vacti-netsetup`. This is ordinary host networking,
  brought up BEFORE the enroll POST.
- **Per-engagement target egress VPN (existing, engine-side, UNCHANGED):**
  `src/runner/vpn/*` driven by an uploaded `VpnProfile` from the CP, AFTER enrollment, to
  tunnel to a target. **The kiosk must NOT call this layer.** Keep the two separate in impl;
  they share tool binaries (openconnect/wg-quick/swanctl are in the arsenal manifest) but not
  control flow.

---

## 7. Tie to the moat (engine.env + kill-switch) & fail posture

- The pre-login gate's ONLY key is `/etc/vacti-engine/engine.env`. The gate does not store,
  validate, or enforce any secret itself — it just withholds the DM until the REAL enroll
  flow has produced `engine.env`. (Jev 0.94: gate = defense-in-depth, NOT the moat.)
- The moat is server-side: the three scoped tokens (producer/verifier/gatekeeper) and the
  CP's ability to REVOKE them (kill-switch) — a stolen/!enrolled box is inert because every
  engine unit is `EnvironmentFile=/etc/vacti-engine/engine.env` and the tokens it needs to
  fetch work/skills are revocable at the CP. A bypassed local gate yields a bare desktop with
  no working engine, no skills, no tokens.
- **Fail posture:** gate withholds the DESKTOP fail-closed on the happy path (no engine.env →
  no login) but the KIOSK ITSELF fails OPEN on crash-loop (fallback getty) so a UI bug can
  never brick the appliance. Enrollment (the firstboot script) already fails LOUDLY on a
  missing/expired token — unchanged.

### Jev probabilities (`typesafe/jev-1.14-20261014`, noul = P(yes))

| Decision | P |
| --- | --- |
| Reuse existing enroll token as "license" (offline key opt-in) | **0.81** |
| Local gate = defense-in-depth, moat stays server-side | **0.94** |
| Kiosk fails OPEN to usable console on crash-loop | **0.78** |
| network-then-enroll ordering | **0.89** |
| Headless default networkd + NM opt-in (`VACTI_HEADLESS_NM=1`) | **0.78** |
| Carry gate through Calamares into installed system | **0.86** |
| Host VPN (enroll-reachability) distinct from engine VpnProfile registry | **0.93** |

All seven endorsed. The two lower (0.78) are the fail-open choice and the headless-NM
default — both are reversible policy knobs; leave margin and make them explicit flags rather
than hard-coding (pinned-vs-latest threshold hygiene).

---

## 8. DISTRO-side vs ENGINE-side split

### DISTRO-only (all changes live in `vacti-distro`; no engine code needed)
- New: `distro/enroll/activate/{vacti-activate, vacti-activate.service,
  vacti-activate-fallback.service, vacti-activate-polkit.rules}`.
- New: `distro/branding/greeter/lightdm.service.d/10-vacti-gate.conf`.
- New: `distro/enroll/netsetup/vacti-netsetup`.
- Edit: `golden-image/build-golden.sh` (stage the new units/scripts — the cp block ~L86-90;
  enable `vacti-activate` only on a GUI golden, which today is headless-only, so effectively
  a no-op for cloud/OVA — guard on `/usr/bin/lightdm`).
- Edit: `live-build-config/build-iso.sh` step 3/4 (install the new files; GUI branch).
- Edit: `live-build-config/config/package-lists/vacti-gui.list.chroot.in` (xinit/openbox/
  NM core + VPN plugins + yad/zenity/polkit).
- Edit: `live-build-config/config/hooks/normal/0100-branding.hook.chroot`
  (`systemctl enable vacti-activate.service` on GUI).
- Edit: `vacti-appliance.env` (add `VACTI_HEADLESS_NM` knob; document the kiosk packages).
- Edit: `branding/apply-branding.sh` (optional: install the gate drop-in next to the greeter
  theme when LightDM present — keeps gate + theme co-located).
- Optional: `preseed.cfg` late_command — enable `vacti-netsetup` MOTD hint.

### ENGINE-side (ideally ZERO; one optional nicety)
- **Zero required.** The kiosk drives the EXISTING `vacti-firstboot` → existing
  `/api/pentest/enroll` → existing `engine.env`. No contract, endpoint, or unit change.
- Optional nicety (only if desired): have the engine ship a tiny
  `vacti-engine-write-env` (already referenced as an optional path in `vacti-firstboot`) so
  env writing is owned entirely engine-side rather than the firstboot inline jq/node writer.
  NOT required for this feature.
- The proxy the kiosk writes (`/etc/vacti-engine/proxy.env` → `WEB_PROXY`) is already an
  engine-recognized knob (see `engine.env.template`), so no engine change to honor it.

---

## 9. Open items to validate at IMPL time (not blockers)
- Confirm `graphical.target` is actually reached on the GUI live/installed system (lightdm
  normally pulls it); if the SKU uses `multi-user.target` only, anchor the kiosk there with a
  bare Xorg instead.
- Confirm no DM auto-start race: the `lightdm.service.d` condition must evaluate BEFORE
  lightdm would start; `ConditionPathExists` is checked at unit start, and `graphical.target`
  wants lightdm — verify the kiosk's `Conflicts=getty@tty1` + ordering actually prevents a
  flash of the greeter. If racy, add `systemctl mask lightdm` in the kiosk preStart and
  unmask on success instead of relying solely on the condition.
- Decide the kiosk user + polkit action names precisely (narrow to NM, tailscale,
  start-units).
- `VACTI_HEADLESS_NM=1` must mask `systemd-networkd` to avoid dual-renderer conflicts.
- Keep UI dependency set minimal + works-everywhere (no GPU/compositor assumption).
```

---

## 10. Implementation notes (as-built) — 0.1.0 pre-login gate

Shipped in `feat(distro): pre-login engine provisioning`. DO-NOT-BREAK held: the
server `POST /pentest/enroll` contract and its `{producer,verifier,gatekeeper,
engine_id}` response are untouched; the kiosk REUSES the existing enroll chain
(writes `/etc/vacti-engine/enroll.token`, starts `vacti-firstboot`/`-firstrun`),
no CP mint code changed, and `ci/no-secret-scan.sh` stays green (no baked token —
the kiosk prompts at runtime).

Files added:
- `distro/enroll/activate/vacti-activate` — the kiosk controller (bare Xorg →
  yad/zenity wizard; network→enroll; writes the token file; waits for engine.env;
  starts LightDM). Fails OPEN when no usable display exists.
- `distro/enroll/activate/vacti-activate.service` — `WantedBy=graphical.target`,
  `ConditionPathExists=!engine.env` + `=/etc/lightdm`, `Conflicts=getty@tty1`,
  `Before=lightdm.service`, `OnFailure=vacti-activate-fallback.service`,
  `StartLimitBurst=3`/`StartLimitIntervalSec=60`. ExecStartPre emits the
  `VACTI_ACTIVATE_KIOSK=start` console marker.
- `distro/enroll/activate/vacti-activate-fallback.service` — the fail-open getty
  (OnFailure target), emits `VACTI_ACTIVATE_FALLBACK=` then `getty@tty1`.
- `distro/enroll/activate/vacti-activate-polkit.rules` →
  `/etc/polkit-1/rules.d/49-vacti-activate.rules`.
- `distro/branding/greeter/lightdm.service.d/10-vacti-gate.conf` — the DM gate.
- `distro/enroll/netsetup/vacti-netsetup` — the headless console TUI.

Deliberate deviations from §1–§9 (with rationale):
- **Kiosk runs as root from its unit, not as an unprivileged `vacti-activate`
  user (§3.1/§9 open item).** Rootless-Xorg-from-a-systemd-service is unreliable
  across hardware/VMs (VT/seat acquisition), and reliability is paramount
  ("works-everywhere"). The polkit rule still ships, scoped to the
  `vacti-activate` user/group, as the forward-looking path for when a dedicated
  user is adopted. Pre-enrollment the box holds no secret, so root here costs no
  moat (the moat is server-side `engine.env` + token kill-switch).
- **The LightDM gate drop-in is installed by `apply-branding.sh` (single shared
  installer), not staged twice in `build-golden.sh` + `build-iso.sh` (§2 table).**
  It travels inside `branding/greeter/` (already copied by both drivers) and is
  installed only when LightDM is present (GUI), so golden/ISO/Calamares-installed
  all get it from one place — strictly less drift than two staging sites.
- **Fail-open is smoke-verified via `-vga none` (no contrived crash).** Booting
  the GUI ISO with no framebuffer makes the kiosk's display pre-flight fail
  deterministically → the genuine fail-open path (kiosk → fallback getty), which
  is exactly the display-less/broken-GPU scenario fail-open exists for. No kernel
  cmdline / SMBIOS injection needed (ISO `-cdrom` can't take `-append`).
- **30-min → 3h.** The stale "30-min" enroll-token comments in `vacti-firstboot`,
  `make-seed.sh`, `user-data.example`, and `enroll/PLAN.md` are corrected to the
  real 3-hour server TTL.
