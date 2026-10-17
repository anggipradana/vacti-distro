# distro/enroll - PLAN (Phase-1)

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
  - `make-seed.sh` (**stub**) - takes a freshly-minted token, fills `user-data`, and
    `genisoimage`s a `cidata.iso` (volume label `CIDATA`) to attach as a second CD-ROM. Ships as a
    template + one-liner; the published image is never pre-filled.
- `guestinfo/` - optional VMware `DataSourceVMwareGuestInfo` notes (set `guestinfo.userdata` /
  `.metadata`, base64 or gzip+base64, via OVF vApp property / `.vmx` / `govc`) layered on the same
  firstboot unit.

## make-seed.sh (stub shape)

```sh
# make-seed.sh <enroll-token>  ->  cidata.iso
# 1. sed "s/__ENROLL_TOKEN__/$1/" user-data.example > user-data
# 2. cp meta-data.example meta-data
# 3. genisoimage -output cidata.iso -volid CIDATA -joliet -rock user-data meta-data
# TODO Phase-1: implement + validate the token is a live, unexpired, single-use token
```

## Rules

- **No baked secret, ever.** The seed is a template; `cidata.iso` and `user-data` are gitignored.
- One firstboot code path behind every channel (NoCloud primary; provider metadata / guestinfo as
  optional enhancements).
- Tailscale joins on the engine's normal startup with the server-served reusable key - not baked.
