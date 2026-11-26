# Vacti Connector: end-to-end guide

This guide follows one intranet engagement from the control plane (CP) to tunnel teardown. Every step has the same
four parts: **UI** (what the operator sees), **DB** (rows to check), **Logs** (lines to expect), and
**Troubleshooting** (failures seen at that step and the fix). It was
written from an empirical run on the production CP on 2026-11-26: a fleet engine (`vacti7`) tested a web server on
an isolated Docker network (`10.77.0.0/24`) that only the connector could reach. That run's evidence is at the end.

For per-platform install commands, see [README.md](README.md). This guide covers the whole flow and the CP side.

## Components and data path

```text
 engine (Kali, fleet)                     control plane box                      customer network
 --------------------                     -----------------                      ----------------
 tool (curl, httpx, browser)
   |  SOCKS5 127.0.0.1:1080
 vacti-tunnel  --- wss /relay/v1/session -->  Caddy --> relay  <-- wss /relay/v1/connect ---  vacti-connector
 (sidecar, per run)                              |       |                                     |
                                                 |   callbacks (internal, X-Relay-Secret)      | TCP/UDP/DNS/ping
                                                 +--> app (CP API) --> Postgres                v
                                                                                           intranet hosts
```

- **connector**: runs inside the customer network. Outbound only. It enforces the signed grant: only the CIDRs the
  CP signed for this session, never loopback, link-local or metadata addresses.
- **relay**: pairs engine sessions with connectors. It does not interpret traffic. It verifies connectors by asking
  the CP and verifies engine session JWTs with the shared session secret.
- **vacti-tunnel**: started by the engine for a via-connector run. It exposes a loopback SOCKS5 proxy, and the
  engine points `VACTI_TARGET_PROXY` at it.
- **CP**: mints the install ticket, the connector identity, the per-engagement grant and the session JWT. It keeps
  the audit trail (`connector_grants`, `audit_log`).

## Step 0: one-time CP setup (operator or admin)

Do this once per CP deployment. Without it, enrollment answers 503 and via-connector dispatch fails closed.

| Item | Command or setting | Check |
| --- | --- | --- |
| DB tables | `psql < drizzle/0188_w48_connector_tables.sql` (hand-applied; drizzle skips it) | `\dt connector*` lists 3 tables |
| Relay secrets | `sudo ops/connector/init-relay-secrets.sh` (prints only `created` or `present`) | `/etc/vacti/connector-relay/` has 2 files, `root:10001 0440` |
| Relay service | `docker compose --profile connector up -d --build relay` | `curl https://<cp>/relay/healthz` returns `ok` |
| CP env (non-secret, server-local override) | `VACTI_PUBLIC_URL=https://<cp>`, `VACTI_RELAY_URL=wss://<cp>/relay` | install one-liner shows your host, not `<your-vacti-host>` |
| Edge (Caddyfile.vps) | `@connector_public` bypass + `handle_path /relay/*` | `curl https://<cp>/api/connector/install.sh` returns 200, not 401 |
| Deploy | `scripts/deploy.sh` (rolling) | `/api/ready` reports the new build on both replicas |

- **UI:** none yet. Settings > Connectors refuses to mint a token until the relay URL is configured.
- **DB:** `connectors`, `connector_enrollment_tickets`, `connector_grants` exist (empty).
- **Logs:** `docker logs vacti-relay-1` shows `relay <version> listening on :8080`.

The relay secrets never go in an env file. The app replicas and the relay read them from the mounted directory
(`VACTI_RELAY_*_SECRET_FILE`). To rotate one, delete the file, run the script again, then restart `app`, `app2` and
`relay`. Rotating the session secret invalidates every live engine session.

Troubleshooting:

- `install.sh` returns **401**: the edge Basic gate is still on the connector paths. Reload Caddy with the current
  `Caddyfile.vps`.
- `/relay/healthz` returns **502**: the relay container is not running. Check `docker logs vacti-relay-1`.
  `RELAY_API_URL, RELAY_SHARED_SECRET (>=32) ... are required` means the secrets directory is missing or unreadable.
- `enroll` returns **503** `connector relay is not configured`: `VACTI_RELAY_URL` is unset or not `ws(s)://`. The
  ticket is NOT consumed, so fix the env and re-run the same install command.

## Step 1: create the connector and mint the install ticket

UI: **Settings > Connectors > Add connector**. Enter a name and the intranet CIDRs this connector may ever reach
(for example `10.77.0.0/24`). This is the ceiling for every future grant. The dialog shows the install token once,
with per-OS one-liners. The token is single use and expires after 30 minutes.

- **UI:** the connector is listed with status **pending**. The dialog shows the Linux/macOS, Windows and Docker
  commands with your CP host filled in.
- **DB:**

  ```sql
  SELECT name, status, intranet_cidrs FROM connectors;               -- status = pending
  SELECT expires_at, consumed_at FROM connector_enrollment_tickets;  -- consumed_at IS NULL
  ```

- **Logs:** audit row `connector.install_created` (Settings > Audit).

Troubleshooting:

- "Connector relay is not configured on this control plane": finish Step 0 first. The dialog will not mint a token
  that could never enroll.
- "CIDR ... is too broad" or "reserved": the CP refuses scopes wider than /8 and loopback, link-local or metadata
  ranges. Use the real intranet ranges.

## Step 2: install the connector on a host inside the customer network

The host needs outbound HTTPS to the CP (and to GitHub or the HuggingFace mirror for the binary). It needs no
inbound port.

```sh
# Linux / macOS (the dashboard one-liner; plain sh is fine, it hands off to bash)
curl -fsSL https://<cp>/api/connector/install.sh | sudo sh -s -- --token <INSTALL_ID> --api-url https://<cp>

# Windows (elevated PowerShell)
$env:VACTI_INSTALL_ID='<INSTALL_ID>'; iwr -useb 'https://<cp>/api/connector/install.ps1?api-url=https://<cp>' | iex

# Docker
docker run -d --name vacti-connector -v vacti-connector-state:/var/lib/connector \
  -e VACTI_API_URL=https://<cp> -e VACTI_INSTALL_ID=<INSTALL_ID> ghcr.io/anggipradana/vacti-connector:latest
```

The CP-served `install.sh` is a small bootstrap. It downloads the canonical installer
(`connector/scripts/install-connector.sh`), resolves the newest `connector-v*` release, verifies the binary against
`SHA256SUMS`, enrolls once, and registers the `vacti-connector` systemd unit (launchd `id.vacti.connector` on macOS,
`VactiConnector` service on Windows).

- **UI:** the connector stays **pending** until enrollment, then becomes **offline** (enrolled, not yet connected).
- **Logs:** expected installer output (Linux):

```text
==> checksum verified
==> control-plane reachable at https://<cp>/api/health
==> enrolling connector (one-time) against https://<cp>
==> enrollment succeeded
==> connector service is ACTIVE
```

- **DB:** the ticket has `consumed_at` set. The connector row has `enrolled_at`, `token_hash` and
  `grant_public_b64`, with status `offline` until the first relay connect. On the host,
  `/var/lib/connector/state.json` exists with mode 0600.

Troubleshooting:

- `bootstrap rejected (HTTP 404)`: the token is unknown, already used or expired. Mint a new one (Step 1).
- `bootstrap rejected (HTTP 503)`: CP relay not configured (Step 0). The ticket is still valid.
- `cannot persist identity`: the state directory is not writable (Docker: mount a volume at `/var/lib/connector`).
  The ticket is not consumed in this case.
- `needs bash`: you ran the canonical installer with `sh`. Use the CP one-liner above, or pipe into `bash`.
- No systemd (containers, minimal hosts): use the Docker variant, or run the binary under your own supervisor
  with `VACTI_CONNECTOR_STATE=/var/lib/connector /usr/local/bin/vacti-connector`.

## Step 3: connector registers with the relay

The connector dials `wss://<cp>/relay/v1/connect` with its bearer token. The relay asks the CP
(`POST /api/internal/relay/verify-connector`) whether the token is live, then reports presence.

- **UI:** the connector shows **online** with its public IP and version. It turns **offline** after 3 minutes
  without presence.
- **DB:** `status = online`, `last_ip` = the site's public IP, `version` = the connector version, and
  `last_seen_at` refreshed every 60 s.
- **Logs:**

  ```text
  journalctl -u vacti-connector:   connector: ... connected
  docker logs vacti-relay-1:       connector <id> connected from <public ip>
  ```

Troubleshooting:

- Connector log `expected handshake response status code 101 but got 503`, repeating: the relay cannot verify the
  connector. Check that the relay and CP versions match (relay >= 0.1.7 reads the CP's flat reply; the CP also sends
  the `{data}` envelope for older relays) and that the relay can reach `http://app:3000`.
- `got 401` and the connector exits with code 3 (`access revoked`): the connector was revoked or its token
  replaced. Re-enroll with a new ticket.
- Backoff grows to about 1 minute between attempts. After fixing the CP side, wait up to a minute or restart the
  service.

## Step 4: create the engagement that uses the connector

UI: **AI Pentest > New engagement**. Put the intranet targets in scope (for example `http://10.77.0.10/`) and pick
the connector under **Reach target via connector**. The picker only appears when the workspace has a connector.
The readiness tile warns when no picked connector is online.

- **UI:** the engagement is **queued**. Its readiness tile names the connector and shows whether it is online.
- **DB:** `pentest_engagements.run_config.connector_id = <connector id>`. This key is CP-only and is never forwarded
  to the engine.
- **Logs:** nothing yet. The engine sees the job only when it polls.

Troubleshooting:

- "The chosen connector is not available for this workspace": the connector belongs to another project or is
  revoked. Connectors are workspace-scoped.
- The picker is missing: the selected project has no connectors. Create the connector in the same workspace.
- The engagement stays **queued**: no eligible engine is idle, or it is hard-pinned to a busy or offline engine.

## Step 5: dispatch, grant mint and tunnel start on the engine

When an engine claims the engagement (`GET /api/pentest/jobs/next`), the CP signs a grant for this engagement.

- **Scope**: `scope_in` intersected with the connector's CIDRs, minus `scope_out`. URL or hostname scopes fall back to
  the connector ceiling.
- **Lifetime**: the engagement wall-clock cap plus 15 minutes.

The CP then wraps the grant in a session JWT and adds a `connector` block (relay URL plus JWT) to the claim
response. The engine starts `/usr/lib/vacti-engine/bin/vacti-tunnel` and sets
`VACTI_TARGET_PROXY=socks5://127.0.0.1:1080`. The target-proxy pre-flight then proves the target is reachable
through the tunnel before any tool runs.

- **UI:** the engagement moves **claimed** then **running**, with the engine name. If the tunnel cannot be proven,
  it goes to **failed** with a "Target proxy pre-flight failed (fail-closed)" reason. It never runs direct.
- **DB:**

  ```sql
  SELECT sid, scan_id, scope_cidrs, expires_at, used_at FROM connector_grants;  -- one row, scan_id = engagement id
  ```

  Audit `connector.session_minted`, then `connector.session_attached` with `used_at` stamped.
- **Logs:** engine (`journalctl -u vacti-engine`):

```text
connector-tunnel: SOCKS5 listener up at 127.0.0.1:1080
target-proxy: pre-flighting socks5 proxy socks5://127.0.0.1:1080 to target http://10.77.0.10 (fail-closed)
```

Relay `session <sid> (scan <engagement>) attached to connector <id>`. Connector `session opened (1 ranges)`.

Troubleshooting:

- Engagement goes straight to **failed** with "connector tunnel could not be established": the mint failed. The
  usual causes are a revoked connector, a connector from another workspace, a scope that does not intersect the
  connector CIDRs, or CP relay secrets missing. Check app logs for `connector session mint FAILED`.
- Pre-flight `proxy http_code none` and no `attached` line in the relay log: the engine's tunnel never reached the
  relay. Engines shipping vacti-tunnel 0.1.4 to 0.1.6 had a SOCKS5 greeting bug that reset every curl connection, so
  upgrade the engine to a build pinned to connector 0.1.7 or later. With >= 0.1.7 the reason appears in the engine
  log as `connector-tunnel: [vacti-tunnel] relay dial failed (HTTP <code>)` and in the relay log as
  `session refused from <ip>: <reason>`.
- Relay log `refused: connector <id> is offline`: the connector is not connected (Step 3).
- Relay log `refused by the API`: the grant was revoked or expired, or the engagement already ended.

## Step 6: engine traffic through the tunnel

Every target-bound tool goes through the SOCKS5 proxy. Names resolve through the connector's own DNS, so internal
names work. The connector refuses any destination outside the grant.

- **UI:** findings and evidence for intranet targets appear as for any web run. The activity feed shows tools
  hitting the internal addresses.
- **DB:** no new connector rows. The grant stays `used_at` set and `revoked_at` empty while the run lasts.
- **Logs:** intranet servers see the connector host as the client (in the run below, nginx logged `10.77.0.20`).
  With vacti-tunnel >= 0.1.7, refused destinations appear in the engine log as
  `connector-tunnel: [vacti-tunnel] connector refused tcp <ip:port>: scope`.

Troubleshooting:

- `scope` refusals for hosts you expected to reach: the grant is `scope_in` intersected with connector CIDRs minus `scope_out`. Widen
  the connector's CIDRs (re-enroll) or fix the engagement scope.
- `unreachable` or `timeout`: the connector host itself cannot reach the target (routing, firewall, host down). Test
  from the connector host with `curl` or `nc`.
- Internal names do not resolve: the connector uses its host's resolver (`/etc/resolv.conf`, or the OS resolver on
  Windows and macOS). Set `VACTI_CONNECTOR_DNS=<ip>` in the connector's environment to override it.
- ICMP shows `unavailable`: unprivileged ping is not permitted on the connector host (Linux
  `net.ipv4.ping_group_range`, never on Windows). TCP and UDP still work.

## Step 7: engagement ends (complete, fail, stop or cancel)

The engine tears the tunnel down when the run ends, and the relay revokes the grant on the connector. The CP side
does not depend on the engine: the relay re-checks every live session with the CP every 60 s
(`/api/internal/relay/session-status`). Once the engagement is `completed`, `failed`, `cancelled`, `delivered` or
`stopped`, the CP answers 403 and the relay closes the session.

- **UI:** the engagement shows **completed**, **failed**, **stopped** or **cancelled**. The connector stays
  **online**, ready for the next engagement.
- **Logs:** within one cycle (about 60 s) of a cancel:

```text
relay:      session <sid> revoked by the API; closing
relay:      session <sid> closed
connector:  session closed
engine:     relay dial failed (HTTP 403)      (if anything still tries the tunnel)
```

- **DB:** `connector_grants.revoked_at` stamped. Audit: `connector.session_refused` (reason
  `engagement cancelled`), then `connector.session_closed`.

A mid-run network drop does NOT revoke the grant. The engine's tunnel redials with the same session, which still
expires at the engagement cap. A resumed engagement is a new claim with a new grant.

Troubleshooting:

- Session still open more than about 2 minutes after the engagement ended: check the relay can reach the CP
  callbacks (relay log `session ... report failed`). A transport error never tears a tunnel down. The grant still
  expires at the engagement cap plus 15 minutes.
- `revoked_at` empty after a normal completion: the engine closed the tunnel before the engagement reached a
  terminal status. The `connector.session_closed` audit row still records the end, and the grant expires at its
  TTL.

## Step 8: connector disconnect, revoke and uninstall

| Action | Expected |
| --- | --- |
| Stop the service (`systemctl stop vacti-connector`, container stop) | relay `connector <id> disconnected`; DB `status = offline` immediately |
| Start it again | `status = online` within seconds |
| Revoke in **Settings > Connectors** | within 60 s relay `connector <id> revoked; closing`; connector exits with code 3 (`access revoked`); DB `status = revoked`, `token_hash` cleared, open tickets deleted, grants `revoked_at`; presence reports can never flip it back |
| Uninstall | `curl -fsSL https://<cp>/api/connector/install.sh \| sudo sh -s -- --uninstall` removes the unit, binary and state |

- **UI:** stop shows **offline**. Revoke shows **revoked**, the row can no longer be picked for an engagement, and
  its pending tickets are gone.
- **DB / Logs:** see the table above. Audit `connector.revoked` carries the operator who revoked it.

Troubleshooting:

- Still **online** after stopping the service: the relay could not report presence. The UI flips to offline after
  3 minutes regardless. Check the relay log for `status report ... failed`.
- The connector keeps reconnecting after a revoke: it runs a build older than the relay re-verify (it exits on
  401/403). Stop and uninstall it, and the token is already dead server-side.

A revoked connector cannot be reused. Enroll a fresh one with a new ticket. With a Docker restart policy, a revoked
container restarts and exits with code 3 again, so remove it.

## Step 9: audit trail

```sql
-- per engagement: when access was granted, first used and ended
SELECT sid, scope_cidrs, created_at, used_at, revoked_at, expires_at
FROM connector_grants WHERE scan_id = '<engagement id>';

-- full connector history
SELECT created_at, action, metadata FROM audit_log
WHERE resource = 'connector:<connector id>' ORDER BY created_at;
```

- **UI:** Settings > Audit, filtered on `connector:`.
- **DB:** the two queries above.
- **Logs:** the actions `connector.install_created`, `connector.session_minted`, `connector.session_attached`,
  `connector.session_refused`, `connector.session_closed`, `connector.revoked`.

Troubleshooting:

- No `session_attached` row for a run that claims to have used the connector: the engine never reached the relay.
  See Step 5.
- Audit rows older than `AUDIT_RETENTION_DAYS` (default 365) live in the cold NDJSON archive, not the table.

## Verified run (prod, 2026-11-26)

Setup:

- Intranet: Docker network `10.77.0.0/24` (internal, no route out) with nginx at `10.77.0.10`.
- Customer host: systemd Debian 12 at `10.77.0.20`, also on a NAT network for outbound HTTPS.
- Engine: fleet engine `vacti7`, which cannot reach `10.77.0.10` directly (curl returned 000).

| Step | Result |
| --- | --- |
| 0 setup | Migration 0188 applied. Relay deployed. Installer and enroll answer through the edge. Internal relay routes stay non-public (401). |
| 1 mint | Connector `pending`, ticket unconsumed. |
| 2 install | Dashboard one-liner piped to `sh`: checksum verified, enrolled, systemd unit ACTIVE, `state.json` 0600, ticket consumed. |
| 3 register | First attempt FAILED: relay 503, flat-reply bug. After the relay fix: `online`, version 0.1.6, public IP recorded. |
| 4/5 dispatch | Grant minted with scope `10.77.0.0/24` and TTL = cap + 15 min. Engine tunnel up. Pre-flight FAILED twice (tunnel 0.1.4 SOCKS5 bug), failed closed with no direct fallback. |
| 6 traffic | vacti-tunnel 0.1.7 on `vacti7` with a real CP-minted session: `GET /` and `/login.html` returned 200. nginx logged client `10.77.0.20`. `10.78.0.1` and `127.0.0.1` refused with `scope`. `used_at` stamped. |
| 7 teardown | Engagement cancelled at 01:36:10. Relay closed the session at 01:36:59. Connector logged `session closed`. `revoked_at` stamped. Redial got 403. |
| 8 disconnect / revoke | Service stop set `offline` immediately and start set `online`. Docker connector enrolled and connected in 1 s. Revoke dropped it in 33 s (exit code 3) and the status stayed `revoked`. |
| 9 audit | `session_minted`, `session_attached`, `session_refused` (engagement cancelled), `session_closed`. |

Engines pick up the tunnel fix with the first engine release pinned to connector 0.1.7 (engine commit `a20f2672`).
Until that release reaches the fleet, via-connector runs fail closed at the pre-flight (Step 5 troubleshooting).
