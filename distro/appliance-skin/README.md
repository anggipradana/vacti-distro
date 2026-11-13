# vacti-appliance-skin

An apt-installable retrofit that brings the vacti-distro appliance presentation and a
GREEN lockdown subset onto an already-provisioned, already-enrolled Kali/Debian engine
host, with **zero forced reboots**, **no engine restart**, and a **24h auto-revert** so a
bad rollout self-heals.

It is additive and reversible: `apt remove vacti-appliance-skin` restores the host to its
pre-install state (branding + lockdown + diverts + units). The optional `kali -> arparp`
user migration is a separate, operator-invoked step and is **not** part of apt remove.

## What it applies

**Branding** (runs the unchanged `distro/branding/apply-branding.sh`, one code path with
the golden image and ISO): os-release/issue/MOTD, PS1, fastfetch, logo/icons, plymouth
boot splash, GRUB theme, LightDM greeter theme + wallpaper, XFCE skel defaults, kiosk CSS,
and a default hostname only if the host is still generic. Boot artifacts render at the next
natural reboot. The pre-login enrollment gate drop-in is kept only on hosts that have the
`vacti-activate` kiosk; a bare retrofit host does not get it (nothing to enroll through).

**Lockdown** (B3 GREEN subset, both Jev critical gates cleared). The skin does not ship its
own copy: the same `apply-branding.sh` run applies it (section 11), so there is one source of
truth and the retrofit stays byte-identical to a fresh appliance image.

- L1: polkit rule so an unprivileged seat (greeter, console) cannot reboot/power-off/suspend
- L2: `ctrl-alt-del.target` masked + `CtrlAltDelBurstAction=none`
- L3: `kernel.sysrq = 0` (applied live and for the next boot)
- L6: `getty@tty2..6` and `autovt@tty2..6` masked (tty1 and the `getty@` template stay, for
  console break-glass)
- L7: serial-getty per SKU (default `keep`, so a VM's hypervisor serial break-glass is kept)

The skin's role for lockdown is **reversibility**: it pre-claims the lockdown files and
pre-masks the units before the run, so `apt remove` restores them. The HELD B3 layers (GRUB
password, NAutoVTs=0, pkexec/su) are not applied. apply-branding.sh also installs
`vacti-lockdown-undo` for per-layer operator opt-out.

## Reversibility (the contract)

Every pre-existing file the skin overlays is first moved aside with
`dpkg-divert --package vacti-appliance-skin --add --rename --divert <path>.vacti-orig <path>`,
so remove puts the original back byte-for-byte. Files and directories the skin creates are
recorded write-ahead in `/var/lib/vacti-appliance-skin/manifest` and deleted on remove; a
pre-existing directory is tar-backed-up and restored; systemd masks are created only where no
unit/override existed and only those are removed. `remove.sh` reads the dpkg diversion
database and the manifest (never a hardcoded path list) and is idempotent. The CI smoke test
installs then removes the package in a container and fails the release if `/etc`, `/usr/local`,
`/boot` and `/root` are not byte-identical to the pre-install capture.

It never restarts lightdm (that would kill the operator's Xfce session), never stops
vacti-engine, and never touches SSH, users, sudoers, tailscale or apt.

## Auto-revert

`postinst` arms `vacti-appliance-skin-auto-revert.timer`. Acknowledge a good rollout with:

```
sudo vacti-appliance-skin --ack
```

Without an ack, 24h after install the skin is removed automatically (`apt-get remove`, with a
`dpkg --remove` then direct `remove.sh` fallback). The window is a wall-clock deadline in
`/var/lib/vacti-appliance-skin/revert-deadline`, so it is exactly 24h from install across
reboots. `vacti-appliance-skin --status` shows where a host stands.

## Install / remove

```
sudo apt-get update && sudo apt-get install -y vacti-appliance-skin
sudo vacti-appliance-skin --status
# verify SSH key login + engine health, then:
sudo vacti-appliance-skin --ack
# revert at any time:
sudo apt-get remove vacti-appliance-skin
```

## User migration (kali -> arparp), optional and separate

`/usr/libexec/vacti-appliance-skin/migrate-user.sh` renames the uid-1000 login in place.
Operator decisions baked in: one **shared** password read from
`/etc/vacti-appliance-skin/arparp-password` (0400 root:root, operator-populated; fail-closed
if absent), the operator's **existing SSH key** as the root break-glass key (no FIDO2), and
diversions/retrofit pull from `distro/` as the source of truth.

- `phase-a` kills the stock credential: sets the shared password on uid 1000, installs the
  operator key(s) as a logged root break-glass forced command, and switches sshd to key-only
  (`PermitRootLogin forced-commands-only`). It proves the config in a throwaway loopback sshd
  (user key works, root forced-command works, bare root key refused) **before** installing it,
  verifies the effective config, reloads (keeps live sessions), and arms a 15-min dead-man.
  No engine restart.
- `phase-b` renames in place (`usermod -l`, uid/home/files unchanged), re-points engine.env
  `ENGINE_USER`, operator-user, sudoers (incl. legacy `vacti-vpn`) and lightdm autologin, then
  re-runs the engine postinst (one restart, same engine_id). Runs detached, verifies, and
  auto-rolls-back on any failure; a 20-min dead-man rolls back unless disarmed.

Every phase is **dry-run** unless `--commit` is given. `rollback-a`, `rollback-b`, `disarm`
and `status` round it out. Snapshots land in `/var/lib/vacti-appliance-skin/migrate/`.

```
sudo /usr/libexec/vacti-appliance-skin/migrate-user.sh phase-a --dry-run
# populate /etc/vacti-appliance-skin/arparp-password (0400 root:root) first
sudo /usr/libexec/vacti-appliance-skin/migrate-user.sh phase-a --commit
# from a NEW session, prove key + break-glass login, then:
sudo /usr/libexec/vacti-appliance-skin/migrate-user.sh disarm
sudo /usr/libexec/vacti-appliance-skin/migrate-user.sh phase-b --dry-run
sudo /usr/libexec/vacti-appliance-skin/migrate-user.sh phase-b --commit
```

Branding assets are copied at build time from `distro/branding/` (single source of truth);
`/usr/share/vacti-appliance-skin/SOURCE` records the exact vacti-distro revision built from.
