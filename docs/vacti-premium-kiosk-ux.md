# Vacti appliance — Premium first-boot kiosk + short-code wizard (UX spec)

Status: implemented in `feat/premium-kiosk-shortcode`.
UI stack: **Option B — Python 3 + GTK4 + libadwaita** (Jev `~typesafe/jev-latest`
→ `typesafe/jev-1.14-20261014`, choice `B_gtk4_adw` p=1.0, confidence=1.0).

## Why this exists (operator complaint, verbatim)

> "ga bisa, kan didalam vm ga bisa copy paste, harus ada mekanisme user ketik
> lebih pendek tapi populate otomatis di BE"
> "jangan cuma UI murahan di vboxnya, kamu udah pernah bikin ui bagus, jadi
> bagusin"
> "cek empiris ova, docker dsb bekerja dengan baik end2end"

Inside a fresh VM there is no clipboard bridge, so pasting a 100+ char UUID
enrollment token is painful. The operator wants a SHORT code typed by hand that
the backend expands into the full token, inside a kiosk that looks premium (on par
with the shadcn/tailwind web console), not the previous plain `yad` notebook.

## Option comparison (empirical)

| Option | Stack | Disk added (measured) | Polish ceiling | Robustness in bare-X VM | Pick |
| --- | --- | --- | --- | --- | --- |
| A | yad GTK3 + CSS theme + fonts | ~0 (yad present) +2–20 MB fonts | ~70% — yad's fixed notebook/form widgets; operator already rejected styled yad | highest | |
| B | Python3 + GTK4 + libadwaita | **~45 MB incremental** (26 pkgs, 62 MB gross; gdk-pixbuf/cairo/pango already on image) | genuinely premium native (AdwClamp, AdwViewSwitcher, AdwEntryRow, AdwStatusPage, AdwToast) | high (standalone, py_compile, fail-open) | **✓** |
| C | webkit2gtk HTML/CSS/JS | ~200 MB (67 pkgs) — over comfortable budget | highest (matches console 1:1) | lowest (web content process, GPU quirks, hard to debug) | |

Disk budget: +50–100 MB acceptable, +500 MB rejected. B fits; C overshoots and
is the most fragile in a headless/no-GPU VM where the kiosk MUST fail open.

## Window & layout

- `AdwApplicationWindow`, **fullscreen + undecorated** (kiosk). Content centred in
  an `AdwClamp` (max 560 px) so it reads as a focused card on any resolution
  (1024×768 VGA → 2560×1440).
- Target design canvas: **960 × 640** logical; scales via Clamp.
- Vertical rhythm: 24 px outer padding, 18 px between rows, 12 px inner.

```
┌──────────────────────────────────────────────────────────────┐
│                      [ vacti lockup logo ]                     │  ← 48px mark + wordmark, centred
│              Aktivasi perangkat · Device activation            │  ← title (.title-1)
│     Lengkapi jaringan, isi kode, lalu tekan Aktivasi.          │  ← dim subtitle
│                                                                │
│        ┌───────────┬──────────────┬───────────┐               │
│        │ Jaringan  │  Enrollment  │  Opsional  │               │  ← AdwViewSwitcher (pill)
│        └───────────┴──────────────┴───────────┘               │
│   ┌────────────────────────────────────────────────────────┐  │
│   │  ( active page card — AdwPreferencesGroup rows )         │  │
│   │                                                          │  │
│   └────────────────────────────────────────────────────────┘  │
│                                                                │
│     Status: ● Terhubung 192.168.1.50   (live, dim)             │  ← global status line
│                                                                │
│                 [        Aktivasi  →        ]                  │  ← pill, suggested-action, full-width
│                      Keluar ke konsol                          │  ← flat/destructive, small
└──────────────────────────────────────────────────────────────┘
```

### Tab 1 — Jaringan (Network)
- `AdwActionRow` "Status jaringan" with a live subtitle (green ● IP / red ● belum
  terhubung), refreshed every 3 s.
- `AdwButtonRow`/suggested button **"Aktifkan koneksi kabel (DHCP)"** — the common
  NAT case; shows an inline spinner while connecting, then updates status.
- Secondary flat button **"Editor jaringan lanjutan (Wi-Fi / IP statis / 802.1x)"**
  → launches `nm-connection-editor`.

### Tab 2 — Enrollment  (the headline change)
- `AdwEntryRow` **"URL control-plane"** — prefilled/remembered on re-open.
- **ONE prominent `AdwEntryRow` "Kode aktivasi / Token"** accepting EITHER an
  8-char short code OR a full UUID token. Monospace, large. Helper caption below:
  "Ketik kode 8-karakter dari dashboard (mis. `K7PQ-3M9T`) — token lengkap juga
  boleh. / Type the 8-char code from the dashboard; a full token also works."
- **Live pattern pill** next to the field: when input matches
  `^[A-HJ-NP-Z2-9]{4}-?[A-HJ-NP-Z2-9]{4}$` → shows **"Kode pendek"** (accent);
  otherwise **"Token"** (neutral). Purely advisory.
- Caption: "Berlaku 3 jam, sekali pakai. / Valid 3 h, single-use."

### Tab 3 — Opsional (Optional)
- `AdwEntryRow` "Proxy HTTP(S)".
- `AdwPasswordEntryRow` "Tailscale auth key".
- Caption: "Kosongkan bila tidak dipakai. / Leave blank if unused."

## Short-code → token flow (pattern detection)

1. Normalize the Kode/Token field: strip spaces, uppercase.
2. If it matches `^[A-HJ-NP-Z2-9]{4}-?[A-HJ-NP-Z2-9]{4}$` (Crockford-ish alphabet,
   excludes I/O/0/1) → treat as **short code**:
   - `POST ${CP_URL}/api/pentest/enroll/exchange`, body `{"code":"<normalized,
     hyphen-stripped, uppercase>"}`, `Content-Type: application/json`.
   - 200 `{"token":"<full>"}` → continue with the full token.
   - 404 → "Kode tidak ditemukan. / Code not found."
   - 410 → "Kode sudah dipakai atau kedaluwarsa (sekali pakai, 3 jam). / Code
     already used or expired."
   - 429 → "Terlalu banyak percobaan. Tunggu sebentar lalu coba lagi. / Too many
     attempts, wait and retry."
   - network/other → "Gangguan jaringan saat menukar kode. / Network error while
     exchanging the code."
3. Else → treat the input as a **full token**, skip the exchange.
4. BOTH paths converge: write `/etc/vacti-engine/enroll.token` (line 1 = token,
   line 2 = url, mode 0600) and start the existing first-boot enroll unit — the
   enroll POST itself stays in `vacti-firstboot` (single source of truth).

## State machine (one busy overlay, non-blocking)

Work runs on a worker thread; UI updates marshalled via `GLib.idle_add`.

| State | UI |
| --- | --- |
| idle | wizard interactive |
| validating | inline AdwBanner if URL/code missing or CP unreachable |
| exchanging | overlay spinner "Menukar kode aktivasi… / Exchanging code…" |
| enrolling | overlay spinner "Mendaftarkan perangkat… mengunduh engine (sekali, ~1–3 mnt). / Enrolling… pulling engine (one-time)." |
| error | AdwToast (id + en), wizard re-enabled, inputs preserved |
| success | `AdwStatusPage` ✓ "Aktivasi berhasil / Activation complete" + "Desktop akan terbuka — VM reboot dalam 10 dtk / rebooting in 10s" countdown → reboot |

## Error / loading / success copy (id · en)

- Missing fields: "URL dan kode wajib diisi (tab Enrollment). / URL and code are required."
- Unreachable CP: "Tidak bisa menjangkau {url}. Cek tab Jaringan lalu coba lagi. / Can't reach {url}. Check the Network tab."
- Exchange errors: see flow above (404/410/429/network).
- Enroll incomplete: "Enrollment belum selesai — token mungkin kedaluwarsa/terpakai. Mint ulang di dashboard. Detail: journalctl -u {unit}. / Enrollment didn't complete."
- Success: ✓ celebration + 10 s reboot countdown.

## Colour palette (brand, dark kiosk)

| Token | Hex | Use |
| --- | --- | --- |
| navy-900 | `#0E347E` | window bg accents / header gradient base |
| blue-600 | `#1F5BD6` | **accent** (buttons, switcher, focus) |
| sky-400 | `#37B6FF` | accent hover / pattern pill |
| sky-200 | `#8FD4FF` | subtle highlights |
| red-500 | `#FF5A5A` | destructive / error |
| white | `#FFFFFF` | primary text on dark |

Applied via `libadwaita` dark base + a brand `Gtk.CssProvider`
(`/usr/local/share/vacti-kiosk/vacti-kiosk.css`): accent recolour, a navy→blue
header gradient behind the logo, pill-shaped suggested button, rounded 16 px
cards. Fail-soft: missing CSS/logo still renders the stock dark theme.

## Type scale

| Role | GTK style class | ~px |
| --- | --- | --- |
| Title | `.title-1` | 26 |
| Section / tab | `.title-4` | 16 |
| Body | default | 14 |
| Caption / helper | `.caption` / `.dim-label` | 11 |
| Code/Token field | `.monospace` | 16 |

## Robustness / fail-open (unchanged guarantees)

- `vacti-activate` (bash) still owns tty1, Xorg/xinit launch, the headless split,
  `graphical_possible()` gate, and the systemd fail-open fallback.
- `run_wizard` preflights GTK4+Adw import; on success launches the Python kiosk,
  else falls back to the (restyled, short-code-aware) `yad` notebook, else
  `zenity`. Any kiosk crash → systemd `OnFailure` getty. The box is never bricked.
- Thin-bootstrap IP protection, polkit rules, `enroll.token` format all unchanged.
- Headless whiptail path (`vacti-headless-activate.service` + `vacti-netsetup`)
  untouched.
