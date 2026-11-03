# vacti-distro E2E harness — OVA + Docker + short-code (pre-staged)

Empirical, end-to-end verification that the published appliance images enroll
correctly through the **short-code** pairing flow (and the backward-compatible
full-token flow), across all three shipped forms:

- the **amd64/arm64 GUI OVA** (GTK4 pre-login kiosk), and
- the **amd64/arm64 headless OVA** (whiptail `vacti-netsetup` console), and
- the **multi-arch Docker image** (`ghcr.io/anggipradana/vacti-distro`).

It exercises the `POST /api/pentest/enroll/exchange` short-code endpoint
end-to-end against the real appliance clients, plus the enroll handshake and the
private-apt engine pull, and it checks the CP-contract edge cases (rate limit,
expiry, single-use).

> **This is a test harness.** The bundled mock control plane
> (`lib/mock-cp-server.py`) is a **scoped test fixture** — it imitates only the
> enroll / exchange / apt surface and serves a clearly-labelled **STUB** engine
> package. It is **never** a control-plane replacement and it **never** ships the
> real `vacti-engine`. Point the harness at a real CP with `--cp-url` /
> `--cp-admin-token` when you want to verify the real control plane.

## Scenario matrix

| # | Form | Credential | Drives | Verifies |
|---|------|-----------|--------|----------|
| 1 | GUI OVA | short code | qemu + VNC (`vncdotool`) | boot → kiosk → exchange → apt pull → enroll |
| 2 | headless OVA | short code | qemu + serial (`expect`) | boot → whiptail → exchange → apt pull → enroll |
| 3 | Docker | short code | `docker run` | exchange → apt pull (exchanged token) → enroll → runner |
| 4 | Docker | full token | `docker run` | **no** exchange → apt pull (supplied token) → enroll → runner |
| 5 | exchange API | — | `curl` | 10×{404/410} then **429** lockout |
| 6 | exchange API | — | `curl` | expired code → **410** |
| 7 | exchange API | — | `curl` | reused (consumed) code → **410** |

Each scenario is **fail-closed**: it stops at the first unmet checkpoint and
exits non-zero, naming that checkpoint.

## Prerequisites

| Need | Scenarios | Install (Debian/Ubuntu) |
|------|-----------|--------------------------|
| `qemu-kvm` + `qemu-utils` (`qemu-system-x86_64`/`-aarch64`, `qemu-img`) | 1, 2 | `apt install qemu-system qemu-utils` |
| UEFI firmware (`ovmf` amd64 / `qemu-efi-aarch64` arm64) | 1, 2 | `apt install ovmf qemu-efi-aarch64` |
| `vncdotool` (pip) | 1 | `pip install -r requirements.txt` |
| `expect` | 2 | `apt install expect` |
| `docker` (+ Docker ≥ 20.10 for `host-gateway`) | 3, 4 | `apt install docker.io` |
| `python3` + `flask` | all (mock CP) | `pip install -r requirements.txt` |
| `curl`, `tar`, `sha256sum` | all | base system |
| ~20 GB free disk | 1, 2 (OVA + qcow2 workspace) | — |
| CPU with KVM (`/dev/kvm`) | 1, 2 preferred | TCG fallback works, slower; or pass `--no-kvm` |

Recommended one-shot setup:

```bash
cd test/e2e
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt
```

## How to run

```bash
# everything (mock-CP backed; hermetic)
test/e2e/run-e2e.sh --all

# a single scenario
test/e2e/run-e2e.sh --scenario 3

# target a REAL control plane for the exchange-contract scenarios
test/e2e/run-e2e.sh --cp-url https://cp.example.local \
                    --cp-admin-token "$CP_ADMIN_TOKEN" --scenario 5

# force software emulation (no KVM), keep the workspace for inspection
test/e2e/run-e2e.sh --all --no-kvm --keep-work
```

### Flags

```
--all                 run scenarios 1..7
--scenario N          run one scenario (1..7)
--cp-url URL          real CP base URL (for real-target scenarios)
--cp-admin-token TOK  real CP admin token (runtime only; never written to disk)
--pairing-code CODE   short code to use (default TEST-CODE; replace with a minted code)
--release VER         image release (default 0.1.0)
--arch amd64|arm64    image arch (default amd64)
--hf-base URL         HF resolve base for OVA downloads
--image REF           Docker image (default ghcr.io/anggipradana/vacti-distro:0.1.0)
--mock-port PORT      mock CP port (default 8080)
--work-dir DIR        workspace (default a fresh mktemp dir)
--no-kvm              force TCG software emulation
--keep-work           keep the workspace (OVA, qcow2, screenshots, logs) after the run
```

### Networking model

- **VM scenarios** reach the host-run mock CP via qemu user-net: the guest uses
  `http://10.0.2.2:<port>` (SLIRP maps the gateway to the host).
- **Docker scenarios** reach it via `--add-host mock-cp:host-gateway`, so the
  container's `http://mock-cp:<port>` resolves to the host, matching the brief.
- The mock's **admin** endpoints are loopback-only **and** token-gated.

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | all selected scenarios passed |
| 1 | one or more scenarios failed (summary names which) |
| 2 | bad usage, or a hard prerequisite missing (e.g. mock CP could not start) |

## Sample output (abridged)

```
[e2e] workspace: /tmp/vacti-e2e.AbC123
[e2e] starting mock CP fixture on 0.0.0.0:8080 (test double only)
[e2e][ok]   mock CP healthy
[e2e] ================= scenario 3 =================
[e2e][ok]   checkpoint PASS: [s3] c1 image present
[e2e][ok]   checkpoint PASS: [s3] c2 container started
[e2e][ok]   checkpoint PASS: [s3] c3 exchange POST received
[e2e][ok]   checkpoint PASS: [s3] c3b exchange returned 200 (code TE..)
[e2e][ok]   checkpoint PASS: [s3] c4 engine .deb pulled over apt with exchanged token
[e2e][ok]   checkpoint PASS: [s3] c5 enroll POST received
[e2e][ok]   checkpoint PASS: [s3] c5b entrypoint reached the engine runner
[e2e][ok]   scenario 3 PASS
[e2e] ================= SUMMARY =================
[e2e][ok]   scenario 3: PASS
[e2e][ok]   ALL SELECTED SCENARIOS PASSED
```

## Notes / known deviations from the brief

- The Docker container has **no systemd** (the entrypoint execs the engine runner
  as PID 1 — see `distro/golden-image/docker-entrypoint.sh`). Scenarios 3/4
  therefore assert engine liveness via the `starting vacti-engine runner`
  entrypoint log line plus the enroll POST, which is the container-form
  equivalent of the brief's `systemctl status` check.
- The 1-hour rate-limit clear (scenario 5) and the ~11-minute code TTL
  (scenario 6) are **abstracted** by default (the 429/410 is asserted without the
  real wait). Export `E2E_REAL_EXPIRY=1` on scenario 6 to actually wait out a real
  TTL against a real CP.
- Secrets (`--cp-admin-token`, pairing codes, enrollment tokens) are passed at
  runtime only and are **never** printed by the harness or written to the repo.
