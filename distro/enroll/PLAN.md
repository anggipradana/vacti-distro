# distro/enroll - first-boot enrollment layer

> STATUS (2026-11): implemented. Operator-facing usage (GUI kiosk pairing, Docker, NoCloud seed)
> lives in [`distro/README.md`](../README.md) sections 1 and 3. Besides the directories below, this
> tree also carries `activate/` (pre-login activation kiosk), `common/` (short-code pairing
> exchange), `install/` and `netsetup/` (network setup console).

The universal first-boot enrollment layer. The shared image carries **zero credentials**; this
directory bakes the *mechanism* only. The *secret* (a short-lived, single-use enroll token) arrives
per-instance via a NoCloud seed, provider metadata, or VMware guestinfo - never baked.

## What lands here

- `firstboot/` - the firstboot unit + script baked into the image:
  - `vacti-firstboot.service` (cloud/VM) / `vacti-firstrun.service` (ISO) - oneshot, runs once:
    reads a per-boot enroll token (from NoCloud user-data / provider metadata / guestinfo / a
    console-dropped file / a GUI first-run dialog), runs the existing enroll path (single-use,
    3-hour TTL, server-deletes the token) to obtain the scoped tokens, writes
    `/etc/vacti-engine/engine.env`, then disables itself. Fails **loudly** on a missing/expired
    token - no longer-lived fallback.
- `nocloud/` - the NoCloud seed template (the lingua franca across cloud / VMware / VBox / ISO):
  - `user-data.example` - the cloud-init user-data template with a `__ENROLL_TOKEN__` placeholder.
  - `meta-data.example` - minimal instance metadata.
  - `make-seed.sh --token <TOKEN> --url <CP_URL> [--out cidata.iso]` - takes a freshly-minted
    token, fills `user-data`, and builds a `cidata.iso` (volume label `CIDATA`) to attach as a
    second CD-ROM. The published image is never pre-filled.
- `guestinfo/` - optional VMware `DataSourceVMwareGuestInfo` notes (set `guestinfo.userdata` /
  `.metadata`, base64 or gzip+base64, via OVF vApp property / `.vmx` / `govc`) layered on the same
  firstboot unit.

## Rules

- **No baked secret, ever.** The seed is a template; `cidata.iso` and `user-data` are gitignored.
- One firstboot code path behind every channel (NoCloud primary; provider metadata / guestinfo as
  optional enhancements).
- Tailscale joins on the engine's normal startup with the server-served reusable key - not baked.
