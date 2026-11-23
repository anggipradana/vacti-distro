---
license: other
pretty_name: vacti-distro images
tags:
  - vacti
  - disk-images
---

# Vacti appliance images

Pre-built operating-system images for the Vacti pentest appliance.
Each image boots pre-provisioned; first boot runs enrollment against
your Vacti control plane.

Documentation: [docs.vacti.org](https://docs.vacti.org).

## Latest complete release: v0.2.491

Engine **0.2.495** is the current fleet release (apt-only; OVA build pending).
Appliance OVAs are produced by a separate image-build workflow, so the latest
engine version is not always the latest OVA set here. The most recent release
with a **complete** OVA set (both arches × both hypervisors) is **v0.2.491**.

Building: v0.2.492 (amd64 up; arm64 pending).

| file | download |
| --- | --- |
| `vacti-distro-0.2.491-amd64-gui.vbox.ova` | https://huggingface.co/datasets/anggipradana/vacti-distro-images/resolve/main/v0.2.491/vacti-distro-0.2.491-amd64-gui.vbox.ova |
| `vacti-distro-0.2.491-amd64-gui.vmware.ova` | https://huggingface.co/datasets/anggipradana/vacti-distro-images/resolve/main/v0.2.491/vacti-distro-0.2.491-amd64-gui.vmware.ova |
| `vacti-distro-0.2.491-arm64-gui.vbox.ova` | https://huggingface.co/datasets/anggipradana/vacti-distro-images/resolve/main/v0.2.491/vacti-distro-0.2.491-arm64-gui.vbox.ova |
| `vacti-distro-0.2.491-arm64-gui.vmware.ova` | https://huggingface.co/datasets/anggipradana/vacti-distro-images/resolve/main/v0.2.491/vacti-distro-0.2.491-arm64-gui.vmware.ova |

Verify: download `https://huggingface.co/datasets/anggipradana/vacti-distro-images/resolve/main/v0.2.491/SHA256SUMS` and run
`sha256sum -c SHA256SUMS` next to the images.

## File naming

Images follow a fixed schema:

```
vacti-distro-<X.Y.Z>-<arch>-gui.<form>.ova
```

- `<arch>` is `amd64` or `arm64`
- `<form>` is `vbox` (VirtualBox) or `vmware`

The version is **not** `v`-prefixed in the filename; the `v` prefix appears only
on the per-release directory name (`v<X.Y.Z>/`). Each release directory also
carries a `SHA256SUMS` manifest. Post-0.1.0 the dataset ships **OVA only** — no
ISO / qcow2 images.

## Available releases

Older point releases are retained under their own `vX.Y.Z/` directory. A short
rolling window is kept (latest complete releases plus the current build);
superseded releases are pruned to keep the dataset lean.

| version | status | forms |
| --- | --- | --- |
| v0.2.492 | current build (arm64 pending) | amd64 vbox+vmware OVA |
| v0.2.491 | latest complete | amd64 + arm64 vbox+vmware OVA |
| v0.2.490 | previous (fallback) | amd64 + arm64 vbox+vmware OVA |
| v0.2.487 | previous (fallback) | amd64 + arm64 vbox+vmware OVA |
| v0.1.0 | genesis release | amd64 + arm64 vbox+vmware OVA |

## Connector

The appliance reaches your control plane through the Vacti connector — a small
Go relay/tunnel service shipped as a container image:

```
ghcr.io/anggipradana/vacti-connector:0.1.4
```

It brokers the engine's outbound connection to the control plane (relay +
tunnel), so the appliance needs no inbound ports opened. Connector setup and
operation are documented at [docs.vacti.org](https://docs.vacti.org).

The OVA appliance is the primary engine-shipping surface; the connector is the
network path it uses to enroll and stay reachable.
