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

The Vacti Connector is a lightweight, scoped L4 forwarder that lets Vacti engines
reach your VPN-protected or intranet-only endpoints without requiring the full
Vacti OVA appliance. It opens one outbound tunnel from inside your network and
carries only the traffic a running engagement is explicitly authorized to reach.

This HuggingFace dataset is a free, rate-limit-friendly mirror of the connector
binaries. GitHub Releases remain the canonical download; see the links at the
bottom.

## Installation

Each command needs an INSTALL_ID (a single-use enrollment token minted in the
control plane) and the control-plane API URL. Replace `<INSTALL_ID>` and keep the
API URL pointed at your control plane (shown here as `https://itsai.sbs`).

### Linux

```sh
curl -fsSL https://itsai.sbs/api/connector/install.sh | sudo sh -s -- --token <INSTALL_ID> --api-url https://itsai.sbs
```

### macOS

```sh
curl -fsSL https://itsai.sbs/api/connector/install.sh | sudo sh -s -- --token <INSTALL_ID> --api-url https://itsai.sbs
```

### Windows (PowerShell, run as Administrator)

```powershell
$env:VACTI_INSTALL_ID='<INSTALL_ID>'; iwr -useb 'https://itsai.sbs/api/connector/install.ps1?api-url=https://itsai.sbs' | iex
```

The installer fetches the matching binary, verifies it against SHA256SUMS,
enrolls once with the install token, and registers a background service
(systemd/launchd on Linux/macOS, an SCM service on Windows).

### Docker

```sh
docker run -d --name vacti-connector \
  -v vacti-connector-state:/var/lib/connector \
  -e VACTI_API_URL=https://itsai.sbs \
  -e VACTI_INSTALL_ID=<INSTALL_ID> \
  ghcr.io/anggipradana/vacti-connector:latest
```

## How to get your INSTALL_ID

1. Log in to the Vacti control plane.
2. Open Settings > Connectors.
3. Click Add Connector, name it, and (optionally) pre-authorize the intranet
   CIDRs it is allowed to reach.
4. Copy the INSTALL_ID (and the ready-made one-liner) from the dialog that
   appears. The token is shown once and is single-use; it expires 30 minutes
   after it is minted.

## Full step-by-step tutorial (all methods)

The fast one-liners above are all most operators need. This section is the detailed
walkthrough for each install method: prerequisites, verify, log tail, and
uninstall. Replace `<INSTALL_ID>` with your enrollment token and keep the API URL
pointed at your control plane (`https://itsai.sbs` in these examples). The service
names match the shipped installers: the systemd unit `vacti-connector`, the launchd
label `id.vacti.connector`, and the Windows service `VactiConnector`.

### Linux (Debian / Ubuntu / Kali)

Prerequisites: `curl`, and root (the one-liner uses `sudo` to install a systemd
service).

1. Install:

   ```sh
   curl -fsSL https://itsai.sbs/api/connector/install.sh | sudo sh -s -- --token <INSTALL_ID> --api-url https://itsai.sbs
   ```

   The script downloads the binary, verifies it against SHA256SUMS, enrolls once,
   writes a systemd unit named `vacti-connector`, and enables + starts it so it
   reconnects on boot.

2. Verify it is running:

   ```sh
   sudo systemctl status vacti-connector
   ```

3. Tail the logs:

   ```sh
   journalctl -u vacti-connector -f
   ```

4. Uninstall (stop + remove the service, binary and state):

   ```sh
   curl -fsSL https://itsai.sbs/api/connector/install.sh | sudo sh -s -- --uninstall
   ```

### macOS

Prerequisites: `curl` (bundled). Homebrew is optional and not required.

1. Install (installs a launchd LaunchDaemon):

   ```sh
   curl -fsSL https://itsai.sbs/api/connector/install.sh | sudo sh -s -- --token <INSTALL_ID> --api-url https://itsai.sbs
   ```

   The LaunchDaemon label is `id.vacti.connector` (plist at
   `/Library/LaunchDaemons/id.vacti.connector.plist`).

2. Verify it is loaded:

   ```sh
   sudo launchctl print system/id.vacti.connector
   launchctl list | grep vacti
   ```

3. Tail the logs:

   ```sh
   tail -f /var/log/vacti-connector.log
   ```

4. Uninstall:

   ```sh
   curl -fsSL https://itsai.sbs/api/connector/install.sh | sudo sh -s -- --uninstall
   ```

### Windows (PowerShell)

Prerequisites: PowerShell 5+ in an elevated (Run as Administrator) window.

1. Install (registers the VactiConnector service):

   ```powershell
   $env:VACTI_INSTALL_ID='<INSTALL_ID>'; iwr -useb 'https://itsai.sbs/api/connector/install.ps1?api-url=https://itsai.sbs' | iex
   ```

   The binary is placed under `%ProgramData%\Vacti\connector` and registered as the
   `VactiConnector` service (start=auto).

2. Verify the service:

   ```powershell
   Get-Service VactiConnector
   sc.exe query VactiConnector
   ```

3. View recent logs (Event Viewer, or PowerShell):

   ```powershell
   Get-EventLog -LogName Application -Source VactiConnector -Newest 50
   ```

4. Uninstall:

   ```powershell
   iwr -useb 'https://itsai.sbs/api/connector/install.ps1' | iex -Uninstall
   ```

   If the script is unavailable, remove the service directly:

   ```powershell
   sc.exe stop VactiConnector
   sc.exe delete VactiConnector
   ```

### Docker

Prerequisites: a Docker engine on a host inside the customer network.

1. Run:

   ```sh
   docker run -d --name vacti-connector \
     -v vacti-connector-state:/var/lib/connector \
     -e VACTI_API_URL=https://itsai.sbs \
     -e VACTI_INSTALL_ID=<INSTALL_ID> \
     ghcr.io/anggipradana/vacti-connector:latest
   ```

2. Logs:

   ```sh
   docker logs -f vacti-connector
   ```

3. Stop and remove:

   ```sh
   docker rm -f vacti-connector
   ```

### Manual (no installer)

1. Download the binary and its `.sha256` for your platform (from the GitHub release
   or the HF mirror; see Downloads below), verify the checksum, and make it
   executable:

   ```sh
   shasum -a 256 -c <(echo "<sha256>  vacti-connector") && chmod +x vacti-connector
   ```

2. First enroll (writes identity to the state dir), then run:

   ```sh
   VACTI_API_URL=https://itsai.sbs VACTI_INSTALL_ID=<INSTALL_ID> ./vacti-connector
   ```

3. To run it unattended, install it as a service by hand: a systemd unit (Linux),
   a launchd plist (macOS), or on Windows:

   ```powershell
   sc.exe create VactiConnector binPath= "C:\ProgramData\Vacti\connector\vacti-connector.exe" start= auto
   ```

   The one-liners above do exactly this for you.

## Verification

Every release ships a `SHA256SUMS` file covering all archives. The installers
verify against it automatically. To check a download by hand:

```sh
# From the same release/mirror directory as the archive:
sha256sum -c SHA256SUMS 2>/dev/null | grep vacti-connector
```

The control plane also serves the expected digest per platform at:

```
https://itsai.sbs/api/connector/sha256/<os>/<arch>
```

for example `https://itsai.sbs/api/connector/sha256/linux/amd64`.

## Network model

- The connector makes one outbound WebSocket (WSS) connection to the Vacti relay;
  no inbound ports are opened on your network.
- Engine tool traffic is carried as scoped SOCKS5 over that WSS tunnel
  (SOCKS5 -> wss/yamux -> relay -> connector -> intranet host).
- Each engagement gets its own signed CIDR grant: the connector only forwards to
  the destinations that grant authorizes, for the lifetime of that run, and drops
  the session within one re-verify cycle once the grant is revoked.
- No root is required to run the connector, except the Windows SCM service
  install, which needs an elevated (Administrator) PowerShell.

## Troubleshooting

- **Stays offline / never turns online.** The connector makes an outbound WSS
  connection to the control plane. Check the host can reach the API URL
  (`https://itsai.sbs`) and that NAT/firewall allows outbound 443, and confirm the
  service is running (see the verify step for your OS).
- **Enrollment token expired / already used.** The token is single-use and lasts 30
  minutes. Mint a fresh one in the control plane (Settings > Connectors > Add
  Connector) and re-run the installer.
- **Permission denied (Linux/macOS).** The service install needs root; run the
  one-liner with `sudo` (it is included above).
- **Windows error 1053 (service did not respond).** Handled by the shipped SCM
  service wrapper; make sure you installed from an elevated PowerShell. Re-run the
  installer to repair the service registration.

Confirm the control plane sees the connector online:

```sh
curl https://itsai.sbs/api/connector/status/<name>
```

## Supported platforms

- linux/amd64
- linux/arm64
- darwin/amd64
- darwin/arm64
- windows/amd64

## Downloads

- GitHub Releases (canonical):
  `https://github.com/anggipradana/vacti-distro/releases/tag/connector-v<VERSION>`
  Assets download from:
  `https://github.com/anggipradana/vacti-distro/releases/download/connector-v<VERSION>/<asset>`

- HuggingFace mirror:
  `https://huggingface.co/datasets/anggipradana/vacti-connector/resolve/main/v<VERSION>/<asset>`

To install from the mirror instead of GitHub, point the installer's release base
at it:

```sh
VACTI_CONNECTOR_RELEASE_BASE=https://huggingface.co/datasets/anggipradana/vacti-connector/resolve/main/v<VERSION> \
  ./install-connector.sh --token <INSTALL_ID> --api-url https://itsai.sbs
# PowerShell: -ReleaseBase https://huggingface.co/datasets/anggipradana/vacti-connector/resolve/main/v<VERSION>
```

Assets per version: `vacti-connector_<VERSION>_{linux,darwin}_{amd64,arm64}.tar.gz`,
`vacti-connector_<VERSION>_windows_amd64.zip`, `SHA256SUMS`,
`install-connector.sh`, and `install-connector.ps1`.
