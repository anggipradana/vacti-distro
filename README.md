# Vacti OS — appliance build sources

Vacti is an AI-driven autonomous penetration-testing platform. This repository holds the **build
sources for the Vacti OS appliance**: the ready-to-run operating-system images that carry a Vacti
engine. You boot one, point it at your own Vacti control plane, and it is ready to work.

It is aimed at two audiences: the engineers who build and release the images, and the
administrators who want to understand exactly what is inside the appliance they are about to run.

If you only want to *use* an appliance, you do not need this repository — download an image from
[vacti.org](https://vacti.org) and follow the [installation guide](https://docs.vacti.org).

## What you get

One source tree produces four distribution forms, all carrying the same engine:

| Form | Best for |
|---|---|
| **Cloud image** (`qcow2`, `raw.gz`) | provisioning on a cloud or VPS provider |
| **Installable ISO** | on-premises and standalone appliances, with a desktop or headless |
| **VMware OVA** | Workstation, Player, Fusion and ESXi |
| **VirtualBox OVA** | VirtualBox on a desktop |

A universal multi-architecture Docker image is also built from the same sources.

## Why the appliance is safe to hand out

Every image is built to be **inert until it is enrolled**. It carries no credentials of any kind:
an image that is copied, leaked or downloaded by a stranger cannot run an engagement, because the
engine only becomes useful once it is enrolled against a control plane that you own and control.
Every engine can be revoked individually from that control plane.

A mandatory scan runs over each artifact before it is published and fails the release if any secret
is found in it.

## The base system

The appliance is built on **Debian 13 (trixie)**, chosen for its permissive derivative policy, its
native fit with the engine, and its predictable, security-supported release cadence. The licensing
posture of the *built* image — Debian, GPL components and third-party packages — is documented
separately in [`NOTICE.md`](NOTICE.md); the build sources in this repository are MIT.

## Repository layout

```
distro/        the appliance source tree (packages, branding, first-boot, image drivers)
ci/            release gates, including the mandatory no-secret scan
.github/       the build and release pipeline
```

Operator-facing instructions — how to mint an enrolment credential and bring an appliance online —
are in [`distro/README.md`](distro/README.md).

## Building

The images are heavy, so the build runs in CI (`.github/workflows/build.yml`) and never on a
production control plane. A local build is possible for development; see the `Makefile`
targets and the operator quickstart in [`distro/README.md`](distro/README.md).

## Licence

The build sources in this repository are MIT-licensed. The resulting images combine Debian and
third-party packages under their own licences — see [`NOTICE.md`](NOTICE.md).

Vacti is for authorised security testing only. You are responsible for having permission to test
any system you point an engine at.
