---
license: other
pretty_name: Vacti Connector
tags:
  - vacti
  - connector
  - pentest
  - networking
---

# Vacti Connector

The Vacti Connector is a small, outbound-only agent you run **inside** a network
that the Vacti engines cannot reach directly (a VPN-only segment, an intranet, a
lab). It opens one outbound encrypted tunnel to the Vacti relay and forwards only
the traffic that a running engagement has been explicitly authorized to reach.
It never listens on a port, needs no inbound firewall rule, and carries no
prompts, tools, model keys or engine code: its only secret is its own identity.

This dataset is the download mirror for the connector binaries and installers.
GitHub Releases (`anggipradana/vacti-distro`, tags `connector-v*`) hold the same
files. The container image is `ghcr.io/anggipradana/vacti-connector` (public).

**Pick your platform:** [Linux](#linux-systemd) | [macOS](#macos-launchd) |
[Windows](#windows-powershell) | [Docker](#docker) | [Manual / air-gapped](#manual--air-gapped)
| [Troubleshooting](#troubleshooting) | [Uninstall](#uninstall)

## How it works

```
  Operator (browser)                      Vacti control plane (CP)
  ------------------                      ------------------------
  1. Settings > Connectors > Add  ------> mints a single-use INSTALL_ID
                                          (valid 30 min)
                                                 ^
  Your network (behind NAT/VPN)                  | 2. POST /api/connector/enroll/<INSTALL_ID>
  -----------------------------                  |    (one time, outbound HTTPS)
  +---------------------+                        |
  |  vacti-connector    | -----------------------+
  |  (service/container)|    returns: connector id + token + relay URL + grant key
  |                     |
  |                     | ==== 3. outbound WSS tunnel (443), kept alive =====> Vacti relay
  +---------------------+                                                          ^
        |                                                                          |
        | 5. forwards ONLY to the CIDRs the                     4. engine tools (SOCKS5)
        |    engagement's signed grant allows                      Vacti engine
        v
  intranet hosts (10.x / 172.16.x / 192.168.x ...)
```

1. You create a connector in the CP dashboard and get an `INSTALL_ID`.
2. The installer runs the connector once with that `INSTALL_ID`; it enrolls and
   stores its identity in `state.json`. The `INSTALL_ID` is consumed on success.
3. The connector keeps one outbound WebSocket (WSS) tunnel to the relay, and
   reconnects automatically with backoff.
4. During an engagement, engine traffic is carried as SOCKS5 over that tunnel.
5. Every engagement carries a signed CIDR grant. The connector forwards only to
   destinations inside that grant, and drops the session once the grant is revoked.

## Before you start (all platforms)

You need three things:

| What | Where to get it |
| --- | --- |
| **INSTALL_ID** | CP dashboard > **Settings > Connectors > Add Connector**. Copy it from the dialog. It is shown once, works **once**, and **expires 30 minutes** after creation. Format: 16-128 characters of `A-Z a-z 0-9 _ -`. |
| **CP URL** | The base URL of your Vacti control plane, e.g. `https://cp.example.com` (the URL you open the dashboard on, no path). |
| **A host inside the target network** | Linux with systemd, macOS, Windows 10/Server 2016 or newer, or anything that runs Docker. It needs **outbound HTTPS (443)** to the CP and to the relay. It does not need any inbound port. |

**Check that the host can reach the CP's enrollment endpoint before you use the
token.** Run this on the host (it uses a dummy id, so it does not consume your
token):

```sh
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://cp.example.com/api/connector/enroll/reachability-check-0000
```

| Result | Meaning |
| --- | --- |
| `404` | Good. The CP is reachable and answered "unknown id" as expected. |
| `401` (with `WWW-Authenticate: Basic` in `curl -i`) | A proxy in front of the CP (e.g. basic-auth/maintenance mode) is blocking `/api/connector/*`. Enrollment **will** fail. The CP operator must let `/api/connector/*` through. |
| `000` / timeout | DNS, firewall or proxy problem on the host side. Fix outbound 443 first. |

> PowerShell equivalent:
> `try { iwr -UseBasicParsing -Method Post https://cp.example.com/api/connector/enroll/reachability-check-0000 } catch { $_.Exception.Response.StatusCode.value__ }`

In the commands below, replace `<INSTALL_ID>` with your token and
`https://cp.example.com` with your CP URL. The current connector version is
**0.1.5**. All commands download from this HuggingFace mirror and pin the version.

---

## Linux (systemd)

Tested on Debian 12 with systemd (see [Test matrix](#test-matrix)). Works on
Debian, Ubuntu, Kali, RHEL/Rocky/Alma, Fedora, Arch and others that run systemd,
on **x86_64 (amd64)** and **aarch64 (arm64)**.

**Prerequisites:** `bash`, `curl` (or `wget`), `tar`, `sha256sum`, root via `sudo`,
and **systemd running as init**. On a plain container, WSL without systemd, or
Alpine/OpenRC, use [Docker](#docker) or the [manual](#manual--air-gapped) method
instead. The installer refuses to run there, before it touches your token.

### 1. Install

```sh
VER=0.1.5
BASE=https://huggingface.co/datasets/anggipradana/vacti-connector/resolve/main/v$VER
curl -fsSL "$BASE/install-connector.sh" \
  | sudo env VACTI_CONNECTOR_RELEASE_BASE="$BASE" bash -s -- \
      --token <INSTALL_ID> --api-url https://cp.example.com --version "$VER"
```

Important details:

- Pipe into **`bash`**, not `sh`. On Debian/Ubuntu `sh` is `dash`, and the 0.1.5
  script then dies with `set: Illegal option -o pipefail`.
- Keep `sudo env VAR=... bash`. A plain `VAR=... sudo bash` loses the variable,
  because `sudo` resets the environment.
- Without `VACTI_CONNECTOR_RELEASE_BASE`/`--version`, the script asks the GitHub
  API for the newest `connector-v*` release and downloads from GitHub Releases.
  That also works, but unauthenticated GitHub API calls are rate-limited
  (60/hour per IP).

What the installer does:

1. Detects OS/arch and downloads `vacti-connector_<ver>_linux_<arch>.tar.gz` plus `SHA256SUMS`.
2. Verifies the SHA-256 and aborts on mismatch.
3. Installs `/usr/local/bin/vacti-connector`.
4. Probes `<CP>/api/health`, then enrolls once and writes `/var/lib/connector/state.json` (mode 0600).
5. Writes `/etc/systemd/system/vacti-connector.service` (hardened: `NoNewPrivileges`,
   `ProtectSystem=strict`, writes only to `/var/lib/connector`), then enables and starts it.

Expected output (abridged):

```
==> installing vacti connector 0.1.5 for linux/amd64
==> downloading vacti-connector_0.1.5_linux_amd64.tar.gz
==> downloading SHA256SUMS
==> checksum verified
==> installed binary at /usr/local/bin/vacti-connector
==> enrolling connector (one-time) against https://cp.example.com
==> enrollment succeeded
==> wrote service definition /etc/systemd/system/vacti-connector.service
==> connector service is ACTIVE
==> done
```

### 2. Verify

```sh
systemctl status vacti-connector          # should be "active (running)"
journalctl -u vacti-connector -n 50       # recent logs
journalctl -u vacti-connector -f          # follow
```

A healthy connector logs `connector: ... connected`. The dashboard shows it
**online** within about a minute.

### 3. Upgrade / re-run

Re-running is safe. Once `state.json` exists, enrollment is skipped, so no new
token is needed:

```sh
VER=<new version>; BASE=https://huggingface.co/datasets/anggipradana/vacti-connector/resolve/main/v$VER
sudo systemctl stop vacti-connector   # needed for the 0.1.5 script ("Text file busy" otherwise)
curl -fsSL "$BASE/install-connector.sh" | sudo env VACTI_CONNECTOR_RELEASE_BASE="$BASE" bash -s -- --version "$VER"
```

### 4. Options

| Flag / env | Meaning |
| --- | --- |
| `--token <id>` | Single-use INSTALL_ID. Required for the first install only. |
| `--api-url <url>` | CP base URL. Required for the first install only. |
| `--version X.Y.Z` | Connector version to install (default: latest `connector-v*` on GitHub). |
| `--cidrs a.b.c.0/24,...` | Informational only. The real reach is the CP-signed per-engagement grant. |
| `--binary <path>` | Install a local binary instead of downloading (air-gapped). |
| `--dry-run` | Print the plan only. **Do not use `--dry-run` with the 0.1.5 scripts (`.sh` or `.ps1 -DryRun`) on a host that already has the connector installed:** that version truncates the installed binary, and `--uninstall --dry-run` really uninstalls. Fixed in the next release. |
| `--uninstall` | Remove the service, binary and state. |
| `VACTI_CONNECTOR_RELEASE_BASE` | Download base URL (this mirror, or an internal mirror). |

---

## macOS (launchd)

Works on macOS 11+ on Intel (`amd64`) and Apple Silicon (`arm64`). macOS ships
`bash`, `curl`, `tar` and `shasum`, so nothing extra needs installing.
Homebrew is not required.

### 1. Install

```sh
VER=0.1.5
BASE=https://huggingface.co/datasets/anggipradana/vacti-connector/resolve/main/v$VER
curl -fsSL "$BASE/install-connector.sh" \
  | sudo env VACTI_CONNECTOR_RELEASE_BASE="$BASE" bash -s -- \
      --token <INSTALL_ID> --api-url https://cp.example.com --version "$VER"
```

It installs:

- binary: `/usr/local/bin/vacti-connector`
- identity: `/Library/Application Support/vacti-connector/state.json`
- LaunchDaemon: `/Library/LaunchDaemons/id.vacti.connector.plist` (`RunAtLoad` + `KeepAlive`, so it starts at boot and restarts if it dies)
- log: `/var/log/vacti-connector.log`

Binaries fetched with `curl` carry no quarantine flag, so Gatekeeper does not
block them. If you downloaded the archive with a browser instead, clear the flag:
`sudo xattr -d com.apple.quarantine /usr/local/bin/vacti-connector`.

### 2. Verify

```sh
sudo launchctl print system/id.vacti.connector | head -20   # state = running
tail -f /var/log/vacti-connector.log
```

### 3. Restart

```sh
sudo launchctl kickstart -k system/id.vacti.connector
```

---

## Windows (PowerShell)

Works on Windows 10 / 11 and Windows Server 2016+ on **x64 (amd64)**. There is
no Windows ARM64 binary yet. The connector registers as the Windows service
**`VactiConnector`** (start type Automatic).

**Prerequisites:** an **elevated** PowerShell window (Start menu > type
"PowerShell" > right-click > **Run as administrator**). Windows PowerShell 5.1
or PowerShell 7 both work.

### 1. Install (recommended: download, then run with arguments)

This works with every installer version, including 0.1.5:

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Ver  = '0.1.5'
$Base = "https://huggingface.co/datasets/anggipradana/vacti-connector/resolve/main/v$Ver"
Invoke-WebRequest -UseBasicParsing "$Base/install-connector.ps1" -OutFile "$env:TEMP\install-connector.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\install-connector.ps1" `
  -Token '<INSTALL_ID>' -ApiUrl 'https://cp.example.com' -Version $Ver -ReleaseBase $Base
```

- `-ExecutionPolicy Bypass` applies to this one process only. It does not change
  the machine policy.
- The TLS 1.2 line is needed on older Windows PowerShell 5.1. Without it, the
  download fails with *"Could not create SSL/TLS secure channel"*.
- **Do not** use `iwr ... | iex` with the 0.1.5 installer. `iex` cannot pass
  `-Token`/`-ApiUrl`, and the 0.1.5 script does not read them from environment
  variables, so it stops with *"-Token is required for a first install"*.
  Installers newer than 0.1.5 accept
  `$env:VACTI_INSTALL_ID='<INSTALL_ID>'; $env:VACTI_API_URL='https://cp.example.com'; iwr -useb "$Base/install-connector.ps1" | iex`.

What it does: downloads `vacti-connector_<ver>_windows_amd64.zip` plus
`SHA256SUMS`, verifies the hash, installs
`C:\ProgramData\Vacti\connector\bin\vacti-connector.exe`, enrolls once (identity in
`C:\ProgramData\Vacti\connector\state.json`), and creates and starts the
`VactiConnector` service, with its state directory set as a per-service environment
value. The binary includes a real SCM handler, so Stop and Shutdown work cleanly
(no error 1053).

### 2. Verify

```powershell
Get-Service VactiConnector                 # Status should be Running
sc.exe qc VactiConnector                   # START_TYPE AUTO_START, BINARY_PATH_NAME ...
```

The service does not write to the Windows Event Log. To see its log output,
stop the service and run the connector in the foreground (Ctrl+C to stop):

```powershell
Stop-Service VactiConnector
$env:VACTI_CONNECTOR_STATE = 'C:\ProgramData\Vacti\connector'
& 'C:\ProgramData\Vacti\connector\bin\vacti-connector.exe'
# expect: "connector: ... connected"   then Ctrl+C and:
Start-Service VactiConnector
```

Service start/stop/crash events are in the System log:
`Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Service Control Manager'} -MaxEvents 50 | ? Message -match 'Vacti'`.

---

## Docker

Use this on any host with Docker: Linux servers, NAS boxes, hosts without
systemd. The image is public, distroless, runs as non-root (uid 65532), has no
shell, and is published for **linux/amd64 and linux/arm64**.

### 1. Run

```sh
docker run -d --name vacti-connector --restart unless-stopped \
  -v vacti-connector-state:/var/lib/connector \
  -e VACTI_API_URL=https://cp.example.com \
  -e VACTI_INSTALL_ID=<INSTALL_ID> \
  ghcr.io/anggipradana/vacti-connector:latest
```

- The **volume is mandatory**. It holds `state.json` (the identity). Without it,
  every container restart would need a new token.
- After the first successful start the token is consumed. Leaving
  `VACTI_INSTALL_ID` in place is harmless: on restart the connector sees the
  stored identity for that same token and reuses it.
- The env var names are exactly `VACTI_API_URL` and `VACTI_INSTALL_ID`. Other names,
  such as `VACTI_CP_URL`, are ignored and fail with
  `VACTI_API_URL must be an http(s) URL`.
- **Bind mount instead of a named volume?** The directory must be writable by
  uid 65532, otherwise you get `cannot persist identity here: ... permission denied`:
  ```sh
  sudo mkdir -p /srv/vacti-connector && sudo chown 65532:65532 /srv/vacti-connector
  # then: -v /srv/vacti-connector:/var/lib/connector
  ```
  The connector checks that it can write here before using the token, so a bad
  mount does not burn the token.

### 2. docker compose

```yaml
services:
  vacti-connector:
    image: ghcr.io/anggipradana/vacti-connector:latest
    restart: unless-stopped
    environment:
      VACTI_API_URL: https://cp.example.com
      VACTI_INSTALL_ID: <INSTALL_ID>
    volumes:
      - connector-state:/var/lib/connector
volumes:
  connector-state:
```

```sh
docker compose up -d && docker compose logs -f vacti-connector
```

### 3. Optional: manage the container with systemd

`--restart unless-stopped` already survives reboots. If you prefer a unit file,
create the container once (step 1), then:

```ini
# /etc/systemd/system/vacti-connector-docker.service
[Unit]
Description=Vacti connector (Docker)
Requires=docker.service
After=docker.service network-online.target

[Service]
Restart=always
ExecStart=/usr/bin/docker start -a vacti-connector
ExecStop=/usr/bin/docker stop -t 10 vacti-connector

[Install]
WantedBy=multi-user.target
```

```sh
docker update --restart=no vacti-connector   # let systemd own restarts
sudo systemctl daemon-reload && sudo systemctl enable --now vacti-connector-docker
```

### 4. Verify / logs

```sh
docker logs -f vacti-connector     # "enrolled", then "connected"
```

---

## Manual / air-gapped

1. Download the archive for your platform and `SHA256SUMS` from
   `https://huggingface.co/datasets/anggipradana/vacti-connector/tree/main/v0.1.5`:
   `vacti-connector_0.1.5_{linux,darwin}_{amd64,arm64}.tar.gz` or
   `vacti-connector_0.1.5_windows_amd64.zip`.
2. Verify the archive, then extract it:
   ```sh
   sha256sum -c SHA256SUMS --ignore-missing      # macOS: shasum -a 256 -c SHA256SUMS --ignore-missing
   tar -xzf vacti-connector_0.1.5_linux_amd64.tar.gz
   ```
3. Either feed the binary to the installer (it still creates the service):
   ```sh
   sudo bash install-connector.sh --binary ./vacti-connector --token <INSTALL_ID> --api-url https://cp.example.com
   ```
   or run it by hand in the foreground:
   ```sh
   mkdir -p ~/.vacti-connector
   VACTI_CONNECTOR_STATE=~/.vacti-connector \
   VACTI_API_URL=https://cp.example.com VACTI_INSTALL_ID=<INSTALL_ID> ./vacti-connector
   # later runs: VACTI_CONNECTOR_STATE=~/.vacti-connector ./vacti-connector
   ```

The connector does not need root when run by hand. Root (or Administrator) is
needed only to register a system service.

### Connector environment variables

| Variable | Purpose |
| --- | --- |
| `VACTI_INSTALL_ID` | Single-use enrollment token (first start only). |
| `VACTI_API_URL` | CP base URL, `http(s)://...` (first start only). |
| `VACTI_CONNECTOR_STATE` | Directory for `state.json`. Default: `/var/lib/connector` (Linux, Docker), `/Library/Application Support/vacti-connector` (macOS as root; `~/Library/...` as a user), `%ProgramData%\Vacti\connector` (Windows). |
| `VACTI_CONNECTOR_DNS` | Optional DNS server (`ip` or `ip:port`, default port 53) for resolving intranet names. Defaults to the host's `/etc/resolv.conf` nameserver. |

---

## Troubleshooting

| Symptom / message | Cause | Fix |
| --- | --- | --- |
| `bootstrap rejected (HTTP 401)` | A proxy in front of the CP (basic auth / maintenance mode) blocks `/api/connector/*`. This is **not** a token problem, even though the message mentions the install id. | Run the reachability check in [Before you start](#before-you-start-all-platforms). The CP operator must allow `/api/connector/*` through the proxy. Your token was not consumed, so retry after the fix. |
| `bootstrap rejected (HTTP 404)` / `(HTTP 410)` | The token is wrong, already used, or older than 30 minutes. | Create a new connector token in the dashboard and re-run. |
| `VACTI_INSTALL_ID has an invalid format` | The token was truncated or still has the `<...>` brackets or quotes around it. | Paste the exact 16-128 character token. |
| `enrollment failed: no identity was written` (0.1.5 script, no detail) | The 0.1.5 installer hides the connector's reason. | Run the binary once by hand to see it: `sudo VACTI_INSTALL_ID=<id> VACTI_API_URL=<url> VACTI_CONNECTOR_STATE=/tmp/vc /usr/local/bin/vacti-connector`. Newer installers print the reason. |
| `set: Illegal option -o pipefail` | The script was piped into `sh` (dash). | Use `... \| sudo bash -s -- ...`. |
| `sed: can't read bash` on `--help` | `--help` cannot read its own text when piped (0.1.5). | Download the script and run `bash install-connector.sh --help`. |
| `must run as root` | Run without sudo. | Add `sudo` (Linux/macOS) or use an elevated PowerShell (Windows). |
| `systemctl: command not found` / `systemd is not running` | No systemd on this host (container, WSL1, Alpine). | Use [Docker](#docker) or the [manual](#manual--air-gapped) method. With the 0.1.5 script the token was already used, so mint a new one. |
| `cp: cannot create regular file ... Text file busy` on re-run | 0.1.5 overwrites the running binary in place. | `sudo systemctl stop vacti-connector`, then re-run. Fixed in the next release. |
| `warning: cannot reach the control-plane at .../api/health` | Wrong `--api-url`, DNS, firewall or outbound proxy. | `curl -I https://cp.example.com/api/health` from the host. Outbound 443 must be open. |
| `-Token is required for a first install` (Windows) | Used `iwr \| iex` with the 0.1.5 script. | Use the download + `-File` command in [Windows](#windows-powershell). |
| `Could not create SSL/TLS secure channel` (Windows) | Windows PowerShell 5.1 defaulting to TLS 1.0. | Run `[Net.ServicePointManager]::SecurityProtocol = 'Tls12'` first. |
| `running scripts is disabled on this system` (Windows) | Execution policy. | Use `powershell -ExecutionPolicy Bypass -File ...` as shown. |
| `no published connector binary for windows/arm64` | Windows on ARM. | Not supported yet. Use an x64 host or Docker. |
| `cannot persist identity here: ... permission denied` (Docker) | Bind-mounted dir not writable by uid 65532. | `sudo chown 65532:65532 <dir>`, or use a named volume. |
| `VACTI_API_URL must be an http(s) URL` | Env var missing or misnamed. | Set `VACTI_API_URL=https://...`. |
| Logs show `disconnected (...); retrying in Ns` repeatedly | Enrolled, but cannot hold the tunnel to the relay (egress proxy, TLS inspection, firewall). | Allow outbound WSS (443) to the relay host. Corporate TLS-inspecting proxies must not intercept it. |
| `access revoked; re-enrol from the dashboard` (process exits with code 3) | The connector was deleted or replaced in the dashboard. | Uninstall, create a new connector, and install again with the new token. |
| Need to move a connector to a new host | Identity is tied to `state.json`. | Uninstall on the old host and install on the new one with a fresh token. Do not copy `state.json` around. |

---

## Uninstall

**Linux / macOS**

```sh
curl -fsSL https://huggingface.co/datasets/anggipradana/vacti-connector/resolve/main/v0.1.5/install-connector.sh \
  | sudo bash -s -- --uninstall
```

This removes the service (systemd unit or LaunchDaemon), `/usr/local/bin/vacti-connector`,
and the state directory. By hand on Linux:
`sudo systemctl disable --now vacti-connector && sudo rm -f /etc/systemd/system/vacti-connector.service /usr/local/bin/vacti-connector && sudo rm -rf /var/lib/connector && sudo systemctl daemon-reload`.

**Windows** (elevated PowerShell)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\install-connector.ps1" -Uninstall
# (re-download it first if $env:TEMP was cleaned - see the Install step), or by hand:
sc.exe stop VactiConnector; sc.exe delete VactiConnector
Remove-Item -Recurse -Force 'C:\ProgramData\Vacti\connector'
```

**Docker**

```sh
docker rm -f vacti-connector && docker volume rm vacti-connector-state
```

Then delete or revoke the connector in the dashboard (**Settings > Connectors**).

---

## Downloads and verification

| Asset (per version directory `v<ver>/`) | Platform |
| --- | --- |
| `vacti-connector_<ver>_linux_amd64.tar.gz` / `_linux_arm64.tar.gz` | Linux |
| `vacti-connector_<ver>_darwin_amd64.tar.gz` / `_darwin_arm64.tar.gz` | macOS |
| `vacti-connector_<ver>_windows_amd64.zip` | Windows x64 |
| `install-connector.sh`, `install-connector.ps1` | installers |
| `SHA256SUMS` | checksums for all of the above |

- Mirror: `https://huggingface.co/datasets/anggipradana/vacti-connector/resolve/main/v<ver>/<asset>`
- GitHub: `https://github.com/anggipradana/vacti-distro/releases/download/connector-v<ver>/<asset>`
- Image: `ghcr.io/anggipradana/vacti-connector:latest` (multi-arch)

Both installers verify the archive against `SHA256SUMS` and abort on mismatch.

### About the dashboard one-liner

The CP dashboard can also show a one-liner of the form
`curl -fsSL <CP>/api/connector/install.sh | sudo sh -s -- --token ... --api-url ...`.
That variant is served by the CP itself. It runs the connector **in the foreground
of your terminal** and does not register a service, and it needs the CP to expose
`/api/connector/*` publicly. For a connector that survives logout and reboot, use
the platform commands on this page.

## Security model

- Outbound only. The connector never opens a listening port.
- The install token is single-use and short-lived. After enrollment the connector
  authenticates with its own token stored in `state.json` (0600, root or service only).
- Reach is decided by the CP-signed, per-engagement CIDR grant (ed25519). The
  connector refuses destinations outside it and drops sessions within one re-verify
  cycle after revocation. `--cidrs` at install time is informational only.
- The systemd unit runs with `NoNewPrivileges`, `ProtectSystem=strict`,
  `ProtectHome`, `PrivateTmp`, and write access only to `/var/lib/connector`.

## Test matrix

How each install path in this document was exercised for connector 0.1.5
(2026-11-26), using a stand-in control plane that implements the enrollment API:

| Path | Environment | Result |
| --- | --- | --- |
| Linux installer, HF mirror, `sudo env ... bash` | Debian 12 + systemd (container, non-root sudo user) | Downloads, verifies checksum, enrolls, unit **active + enabled**. Uninstall clean. |
| Linux installer, GitHub default (no `--version`) | same | Resolves latest `0.1.5` via the GitHub API, downloads and verifies. Re-run over a running service hits `Text file busy` (documented above). |
| Linux installer piped to `sh` | Debian 12 (dash) | Fails: `Illegal option -o pipefail`. Documented above. |
| Linux installer, used / malformed token, unreachable CP | same | Fails with clear exit. Reasons documented above. |
| Linux installer, no systemd | debian:12-slim, alpine:3.20 | Fails at `systemctl` after enrollment. Documented above. |
| macOS installer | launchd layout via `uname` shim + real enrollment, plist validated | Binary, plist, state written correctly. `launchctl` calls planned. |
| Windows installer | PowerShell 7.4 (parser + Pester suite, sandbox/dry-run), `iex` behaviour | Parses; service plan correct; `iwr \| iex` with 0.1.5 fails as documented. Live SCM registration not run (no Windows host). |
| Docker image | linux/amd64, named volume, bind mount, compose, restart | Enrolls; restart reuses identity; bind mount needs `chown 65532`. |
