# Vacti appliance - operator quickstart

Enroll a Vacti pentest engine from an appliance (OVA / Docker / cloud) or a terminal install, and
connect it to your control plane (CP). This is the step-by-step operator guide; the architectural
synthesis is in the [repo README](../README.md).

The fastest path is the **8-char pairing code**: short, typeable, no clipboard. Mint it in the CP,
type (or paste) it into the appliance, done.

---

## 0. Mint a credential in the control plane

In the CP, go to **Settings > Engine**. There are two mint modes:

| Mint mode | Credential | TTL | Use it for |
| --- | --- | --- | --- |
| **Mint for appliance (OVA/Docker)** *(default)* | **8-char pairing code** (e.g. `K7X9-R8W2`) | **10 min**, single-use | The OVA kiosk and `docker run`. Also shows a ready-to-paste Docker env snippet. |
| **Mint for terminal install** *(behind "Advanced")* | **Full UUID enrollment token** | **3 h**, single-use | Terminal install, cloud-init / NoCloud, pre-boot injection. |

Both credentials are **single-use** and are deleted by the server on first exchange. If one expires
before you finish, just mint a fresh one.

> No secret is ever baked into a shared image. The credential arrives per-instance, at enrollment
> time only.

---

## 1. OVA / VM appliance (GUI kiosk) - recommended for desktop hypervisors

1. Import the `.ova` into VMware (Workstation / Player / Fusion / ESXi) or VirtualBox and boot it.
2. The **premium first-boot kiosk** opens automatically (no SSH, no login).
3. On the **Jaringan / Network** tab, bring up networking (wired DHCP is one click).
4. On the **Enrollment** tab:
   - Set the **control-plane URL**.
   - In the **Kode aktivasi / Token** field, **type the 8-char pairing code** from the CP
     (a full token also works - the field auto-detects which you pasted).
   - Confirm. The appliance exchanges the code for the full token and activates the baked engine.
5. The GUI OVA also ships **firefox-esr** and **xfce4-screenshooter** for manual operator use
   (browse a target, grab a screenshot) from the XFCE desktop.

---

## 2. Docker container - fastest, smallest footprint

The image bakes the engine at build time; at container start it activates against your control
plane using your credential. No reusable secret is baked into the image.

Pairing-code form (recommended):

```sh
docker run -d --name vacti \
  --net=host --cap-add=NET_ADMIN --cap-add=NET_RAW \
  -e VACTI_CP_URL=https://<your-control-plane> \
  -e VACTI_PAIRING_CODE=K7X9R8W2 \
  ghcr.io/anggipradana/vacti-distro
```

Full-token form (advanced):

```sh
docker run -d --name vacti \
  --net=host --cap-add=NET_ADMIN --cap-add=NET_RAW \
  -e VACTI_URL=https://<your-control-plane> \
  -e VACTI_ENROLL_TOKEN=<full-uuid-token> \
  ghcr.io/anggipradana/vacti-distro
```

Accepted env (supplied at `docker run`, never on the image):

| Env | Meaning |
| --- | --- |
| `VACTI_CP_URL` (or `VACTI_URL` / `CP_URL`) | Control-plane base URL. **Required** - and mandatory when using a pairing code (the code is CP-scoped). |
| `VACTI_PAIRING_CODE` | 8-char pairing code. Exchanged for the full token before anything else runs. |
| `VACTI_ENROLL_TOKEN` | Full enrollment token (single-use, 3 h). Also accepts an 8-char code as its value. |
| `VACTI_TOKEN` | A producer token (skips the enroll exchange entirely). |
| `ENGINE_ID` | Optional engine id (defaults to the hostname). |
| `VACTI_LANG` | `en` or `id` for operator-facing messages (default follows `$LANG`). |

Notes:
- **Caido CLI self-heals on container start** (fetches the pinned release, currently `v0.57.0`), so
  request/response evidence capture is ready without a manual install. It is fail-open: a missing
  Caido only degrades evidence to the Playwright render, never blocks start.
- The scoped tokens are persisted to the state volume, so a restart inside the TTL comes back
  authenticated without re-minting.

---

## 3. Headless cloud / NoCloud seed (advanced)

For headless cloud or VM provisioning with no interactive kiosk, use a **NoCloud seed**: a tiny
`cidata.iso` (volume label `CIDATA`) carrying a freshly-minted full enrollment token.

```sh
# Mint a full token in the CP (Advanced > Mint for terminal install), then:
enroll/nocloud/make-seed.sh --token <ENROLL_TOKEN> --url https://<your-control-plane> --out cidata.iso
# Attach cidata.iso as a second CD-ROM and boot. Token is single-use / 3 h TTL; boot promptly.
```

The same seed works on cloud, VMware, VirtualBox, and the installed-ISO system. Cloud provider
metadata and VMware `guestinfo` are optional enhancements on the same firstboot unit. The seed and
any filled `user-data` are gitignored and must **never** be committed or redistributed - they carry
the live token.

---

## 4. Terminal install on a Debian / Kali box (full curl)

For an existing box you already SSH into with sudo: mint a **full enrollment token** (Advanced >
Mint for terminal install) and install the `.deb` from the private apt repo, authenticating apt with
the token as the HTTP Basic password. Follow the install snippet shown in the CP's **Mint for
terminal install** panel; it writes the apt source + `auth.conf` and installs `vacti-engine`.

---

## 5. What ships in the appliance

- **Full + CTF arsenal by default.** Published OVA/ISO/Docker artifacts bake the full arsenal plus
  the CTF tool set on every build. The lean web+infra set is explicit opt-in (build with
  `full_arsenal=0`).
- **No baked secret, no baked methodology.** The engine `.deb`, skill bundles, and per-engagement
  methodology are fetched from the CP, trust-gated. A stolen image is inert without a valid
  enrollment.

---

## 6. Troubleshooting

- **`401` Basic-auth challenge on `/api/pentest/enroll` or `/api/pentest/enroll/exchange`.**
  You are hitting an **old Caddyfile** version at the edge. The exchange subpath was being trapped
  by the edge Basic auth; the fix exempts the enroll base **and** its subtree (the app still
  enforces Bearer/body auth per subpath). Update the CP's Caddyfile and reload.
- **Pairing code says "not found / already used / expired".** The code is **single-use** and
  **expires in 10 minutes**. It is consumed on the first successful exchange. Mint a fresh one in
  **Settings > Engine** and retry promptly.
- **Full enrollment token rejected.** The full token is **single-use with a 3-hour TTL**. If a seed
  sat too long before boot, re-mint and rebuild the seed.
- **`VACTI_CP_URL required` when using a pairing code.** A pairing code is control-plane-scoped; it
  cannot be exchanged without the CP URL. Set `VACTI_CP_URL` (or `VACTI_URL`).
- **Too many attempts.** The exchange is rate-limited (lockout after repeated failures). Wait a
  moment, then retry with a fresh code.
- **GHCR pull returns `403` anonymously.** Public image distribution is pending a license audit; pull
  with credentials or use the OVA until it is published.
