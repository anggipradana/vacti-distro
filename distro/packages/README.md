# Arsenal packages: single source of truth, update cadence, and cross-arch parity

This directory is where the vacti appliance decides **which pentest tools get baked
into every image**. One manifest drives the OVA golden image, the ISO, and the
universal Docker image, so there is exactly one list to keep honest.

## Where the manifest lives and how to update it

- **`arsenal-manifest.json`** (here) is the single source of truth for the baked
  arsenal. It is a **generated, vendored snapshot** (`schema: vacti-arsenal-manifest/v1`)
  of the authoritative manifest the **engine repo** ships inside the `vacti-engine`
  `.deb` at `/usr/lib/vacti-engine/packaging/arsenal-manifest.json`.
- **Do not hand-edit it.** It is regenerated in the engine repo with
  `node scripts/gen-arsenal-manifest.mjs` (source of truth there:
  `packaging/arsenal.env`). The distro's vendored copy is re-synced from the engine
  and kept honest by **`ci/arsenal-sync-check.sh`** (the divergence guard), which
  fails CI if the vendored snapshot drifts from the engine manifest.
- **`gen-live-build-list.sh`** + **`manifest-lib.sh`** derive the actual apt install
  list for a build flavour (`lean` / `full` / `ctf`) from the manifest. Both the
  golden-image build and the Dockerfile call this one bridge — no image hand-keeps a
  forked package list.

### Manifest apt sets

| Set | Count | Meaning | Must install on every arch? |
| --- | --- | --- | --- |
| `apt.grant` | 34 | required arsenal (GUI/session grant tools) | yes (gate) |
| `apt.core` | 70 | required arsenal (web/infra/mobile/RE core) | yes (gate) |
| `apt.verticals.*` | 16 (all already inside `core`) | optional per-vertical (`source`, `mobile`, `ios`, `re`) | no — arch-divergent allowed |
| `apt.ctf` | 21 | optional CTF toolset | no — arch-divergent allowed |

`grant` ∪ `core` = the **gate** set (76 unique packages). `verticals` ∪ `ctf` = the
**optional** set.

## OVA and Docker bake the arsenal at BUILD time, not runtime

Both image forms install the arsenal **when the image is built**, from public sources
only (Debian 13 "trixie" + the priority-100 pinned Kali rolling source + NodeSource):

- **OVA / golden image**: `distro/golden-image/build-golden.sh` runs the derived apt
  install inside the guest at build time.
- **Docker**: `distro/Dockerfile` derives and installs the lean arsenal in the builder
  stage at build time.

Because the arsenal is baked, **a running appliance does not fetch new tools on its
own.** To get an updated arsenal, the operator must **pull a new OVA / new Docker
image tag** built after the manifest changed. (There is a best-effort runtime
self-heal for the handful of tools that have no apt package — see below — but that is
a floor, not the update channel.)

### What DOES update independently: the engine `.deb`

The **engine itself** (the `dist` runtime + the prompt-bundle + the skill-bundle = the
real IP, plus its bundled Chromium) is **not baked** into any published image
(thin-bootstrap, IP protection). It is pulled at **first boot / container start** from
the private apt repo using the per-run enrollment token, and the running engine then
does a **~45-minute idle update check** to stay current. So methodology/skills update
on their own cadence; the **apt arsenal of binary tools does not** — that rides the
image tag.

## Cross-arch parity is enforced in CI

`.github/workflows/arsenal-parity.yml` is the gate that answers "are the required
tools installable and consistent on **every** architecture (amd64 + arm64)?"

- It runs on **both** `ubuntu-latest` (amd64) and `ubuntu-24.04-arm` (arm64), each
  simulating `apt-get install` for **every** manifest package **inside a
  `debian:trixie-slim` container with the pinned Kali source** — native per-arch (no
  QEMU, no Ubuntu-runner skew), using the same `kali-repo/*.list*` + pin files the
  images use.
- Per-arch reports land at `generated-reports/arsenal-parity-amd64.json` and
  `-arm64.json` (`{package, arch, class, installable, has_apt_candidate,
  reason_if_not}`), via `ci/arsenal-parity.sh`.
- `ci/arsenal-parity-diff.sh` compares the two and decides the gate.

### Gate semantics

- **FAIL** when a `grant`/`core` package is installable on **one** arch but **not the
  other** — a true arch-parity defect (an image would ship a required tool on one arch
  and silently omit it on the other).
- **Report loudly, do NOT fail**, when a `grant`/`core` package is absent on **both**
  arches. Those are **runtime-self-heal** tools with no apt package on either arch
  (e.g. Go tools installed via `go install`, or a Kali-only tool unsatisfiable under
  the priority-100 pin). They are arch-consistent, so not a parity failure, and the
  manifest (engine-generated) is not edited here to remove them. They are still named
  in the job summary so the operator knows which required tools are runtime-provisioned
  rather than baked.
- **`verticals`/`ctf` are allowed to be arch-divergent** — reported, never fatal.

### Dockerfile fail-loud

`distro/Dockerfile` no longer silently warns-and-ships a missing required tool. After
the bulk + per-package install attempts, any still-failed package is classified
against the manifest:

- optional (`verticals`/`ctf` only) → `[docker][warn]`, continue;
- required (`grant`/`core`) with **no apt candidate** → `[docker][warn]`, continue
  (runtime self-heal);
- required with an **apt candidate that still failed to install** → `[docker][error]`
  and **`exit 1`** (real breakage, build fails loud).

## Known arch support of the optional sets

The CI reports are the authoritative, per-commit truth. As of this writing, with the
Debian trixie + pinned Kali base:

- **`verticals.source`** (`trivy`), **`verticals.ios`** (`usbmuxd`,
  `libimobiledevice-utils`, `libplist-utils`, `llvm`), **`verticals.re`**
  (`gdb-multiarch`, `binwalk`, `strace`, `ltrace`, `tshark`, `checksec`) and the
  **`ctf`** apt set resolve on **both amd64 and arm64**.
- **`verticals.mobile` → `scrcpy`** is **Kali-only and unsatisfiable under the pin on
  both arches** (its Kali build needs `libavdevice63 >= 7:9.0.2`, which the
  priority-100 pin will not pull over Debian's ffmpeg stack). It is optional, so this
  is allowed; the mobile workflow uses the other mobile tools (`apktool`, `aapt`,
  `apksigner`, `zipalign`) which do install. `adb` (core) installs on both.

Required (`grant`/`core`) tools that are **runtime-self-heal** (no apt package on
either arch, provisioned by the engine at runtime): `gau`, `interactsh-client`
(Go tools), and `globalprotect-openconnect` (no Debian/Kali package). These are
arch-consistent and surfaced by the gate as non-fatal.
