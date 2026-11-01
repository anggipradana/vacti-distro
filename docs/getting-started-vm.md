# Getting started: VACTI virtual machine (OVA / ISO)

This guide takes you from download to a running, enrolled VACTI engine in a
virtual machine. It assumes you can already run VirtualBox or VMware, but not
that you know anything about VACTI.

You will need one thing that is not in the download: an **enrollment token**
(your license key). You mint it yourself in the VACTI control plane (the web
dashboard your operator gave you). The disk image ships with no secret baked in,
so it stays inert until you enroll it.

## Which variant should I pick?

If you are new to VACTI, use the **GUI ISO** (`-gui.iso`). It is the only path
that needs no extra tooling: boot it and an on-screen wizard asks for your URL
and token. Follow sections 1 to 4, then **section 5A**, and you are done. You can
skip section 5B.

The **OVAs** and the **headless ISO** are headless cloud images with **no console
password**. They are meant for operators doing repeatable or automated rollouts,
and they enroll from a small seed disk rather than an on-screen prompt (section
5B). If you just want one VM running, prefer the GUI ISO above.

## 1. Prerequisites

- A 64-bit host with virtualization enabled and at least 4 vCPU, 8 GB RAM, and
  60 GB of free disk for the VM.
- One of:
  - **VirtualBox 7.0+** (7.1+ required on Apple Silicon / arm64), or
  - **VMware Workstation 17+ / Fusion 13+** (Fusion 13+ required on Apple
    Silicon / arm64), or
  - **QEMU/KVM** if you prefer the raw `.qcow2` cloud image instead of an OVA.
- For building a seed disk (OVA / headless path): `genisoimage` or `xorriso` on
  your workstation.
- Outbound HTTPS (port 443) from the VM to your control-plane URL. Enrollment
  fails if that URL is unreachable.

## 2. Download

Open the releases page and pick your variant:

<https://github.com/anggipradana/vacti-distro/releases>

> Note: release assets are **private** to the repository and published as
> pre-releases, so the `/releases/latest` shortcut may not resolve. Open the
> `images-v<version>` release your operator points you to, signed in with an
> account that has access.

Four VM variants are published per release (x86-64 shown; the arm64 build
inserts `-arm64` after the version):

| File | Use it for |
| --- | --- |
| `vacti-engine-<version>-gui.iso` | Desktop install with the activation wizard (easiest) |
| `vacti-engine-<version>-virtualbox.ova` | VirtualBox import (headless, needs a seed) |
| `vacti-engine-<version>-vmware.ova` | VMware import (headless, needs a seed) |
| `vacti-engine-<version>-headless.iso` | Server install, no desktop (needs a seed) |

arm64 example: `vacti-engine-<version>-arm64-virtualbox.ova`.

## 3. Verify checksums

Download `MANIFEST.sha256` (and any per-file `*.sha256`) from the same release,
put it next to the image, then verify:

```bash
sha256sum -c MANIFEST.sha256
```

Each line must print `OK`. If it does not, re-download; do not import a
mismatched image.

## 4. Import or install

OVA, VirtualBox (command line):

```bash
VBoxManage import vacti-engine-<version>-virtualbox.ova
```

Or VirtualBox GUI: **File > Import Appliance**, pick the `.ova`, review CPU/RAM,
**Finish**.

OVA, VMware Workstation / Fusion (GUI):

1. **File > Open**, select `vacti-engine-<version>-vmware.ova`.
2. Accept a name and storage location, then **Import**.
3. If prompted about OVF compliance, choose **Retry** / relax checks; the
   hand-authored OVF imports cleanly.

ISO (GUI or headless): create a new VM, attach the `.iso` as the boot CD/DVD, and
boot it. The GUI ISO brings up the activation wizard (section 5A); the headless
ISO needs a seed disk (section 5B).

## 5. Boot and enroll

There is **no setup web page on the VM itself** - the "control plane" is your
separate VACTI dashboard. First, mint the token you will need:

In your VACTI control-plane dashboard, create (mint) a **single-use enrollment
token**. It has a short time-to-live (about 3 hours) and works only once, so
enroll promptly.
`TODO: confirm the exact dashboard location once the control-plane UX copy is
finalized (reported to be Settings > Engine, "enroll an engine").`

Copy both the token and your control-plane base URL (for example
`https://your-cp.example.com`); you enter them in the step below.

### 5A. GUI path (the `-gui.iso`)

The GUI ISO is a **live image**: boot the VM from it and the activation wizard
starts on its own, before any desktop login. (You can also install VACTI to the
VM's disk with the on-image installer for a permanent VM; the same wizard runs on
the installed system's first boot.) Follow its two steps:

1. **Network**: a NetworkManager editor opens so the VM can reach the control
   plane. Set up wired/Wi-Fi/DNS (and an optional proxy), then close it.
2. **Activation**: a form asks for the **control-plane URL** and your
   **enrollment token**. Fill both and submit.

On success the wizard shows **"Activated. Starting the desktop..."** and hands
you to the normal login screen. The engine is now enrolled.

### 5B. OVA / headless path (seed disk, for operators)

These images have no console password, so you hand them the token on a tiny seed
CD-ROM. From a checkout of this repository, one command builds it:

```bash
distro/enroll/nocloud/make-seed.sh \
  --token YOUR_ENROLLMENT_TOKEN \
  --url https://your-cp.example.com \
  --out cidata.iso
```

Without the repository, create two files in an empty folder and build the ISO by
hand. `user-data` (replace the two placeholders):

```yaml
#cloud-config
write_files:
  - path: /run/vacti/enroll.env
    permissions: "0600"
    content: |
      vacti_enroll_token=YOUR_ENROLLMENT_TOKEN
      vacti_url=https://your-cp.example.com
runcmd:
  - [ systemctl, start, vacti-firstboot.service ]
```

`meta-data`:

```yaml
instance-id: vacti-engine-01
local-hostname: vacti-engine
```

Build the seed ISO (the volume label must be `CIDATA`):

```bash
genisoimage -output cidata.iso -volid CIDATA -joliet -rock user-data meta-data
# or: xorriso -as mkisofs -o cidata.iso -V CIDATA -J -r user-data meta-data
```

Then attach `cidata.iso` to the VM as a **second CD/DVD drive** and boot:

- VirtualBox: **Settings > Storage > add Optical Drive > choose `cidata.iso`**.
- VMware: **VM Settings > add CD/DVD > Use ISO image > `cidata.iso`**.

On boot the VM reads the seed, enrolls itself automatically, then wipes the
token. Because the token is single-use with a ~3 hour lifetime, build the seed
and boot promptly; if it expires, re-mint and rebuild. You can detach
`cidata.iso` after the first successful boot.

> Advanced: if you need an interactive console instead, extend the seed's
> `user-data` to set a user password or SSH key, then log in and run
> `sudo vacti-netsetup` (the login banner reminds you while the box is
> unenrolled). A bare image has no password, so this is not available without the
> seed.

All paths drive the same first-boot enrollment unit under the hood
(`vacti-firstboot.service`, which calls `POST /api/pentest/enroll`).

## 6. Verify enrollment

Once you can reach a shell on the VM (GUI desktop terminal, or SSH after the seed
set up access), confirm the engine is up:

```bash
systemctl status vacti-engine
journalctl -u vacti-firstboot --no-pager | tail
```

A successful run logs `[vacti-firstboot] first-boot enrollment complete` and
writes `/etc/vacti-engine/engine.env`. Then open your control-plane dashboard;
the engine should appear in the engines list as **enrolled and online**.
`TODO: fill in the exact dashboard menu path once the control-plane UX copy is
finalized (reported to be Settings > Engine).`

## 7. Troubleshooting

- **Bad or expired token**: enrollment fails with an HTTP error. The token is
  single-use with a ~3 hour lifetime - mint a fresh one and retry (rebuild the
  seed for the OVA/headless path).
- **No network**: re-run the wizard's network step (GUI), or confirm the VM has
  an IP and DNS before building the seed (OVA/headless).
- **Firewall blocks the control plane**: the GUI wizard probes the URL first and
  reports it cannot reach it. Allow outbound HTTPS (443) to the control-plane
  host, including any proxy you configured.
- **OVA booted but nothing enrolled**: confirm `cidata.iso` is attached as a
  CD-ROM and was built with the correct `--url` and a still-valid token.

## 8. Auto-updates

Once enrolled, the engine keeps itself current from the VACTI apt repository via
the `vacti-engine-update.timer` systemd timer, which runs idle-gated (about every
45 minutes). You do not need to chase updates manually. To freeze a specific
engine, set `VACTI_AUTO_UPDATE=0` in `/etc/vacti-engine/engine.env` and restart
`vacti-engine`.
