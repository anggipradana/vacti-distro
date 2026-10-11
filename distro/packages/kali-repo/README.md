# Option A: Kali apt repo as a pinned package source

The engine needs ~6 tools that are not in Debian `main`: `nuclei`, `httpx-toolkit`,
`naabu`, `feroxbuster`, `seclists`, `commix`. **Option A** (the operator-approved
default) supplies them from the Kali rolling archive added as an ordinary,
**priority-100 pinned** apt source. This is a *package source only* - no Kali
branding, marks, or metapackages land in the image (legal-clean per the Debian
derivative posture in `../../README.md` and `NOTICE.md`).

## What the build driver does (golden image and live-build both)

```sh
# 1. fetch the public archive signing key (NOT a credential)
curl -fsSL https://archive.kali.org/archive-key.asc \
  | gpg --dearmor -o /usr/share/keyrings/kali-archive-keyring.gpg

# 2. drop the source line + the priority-100 pin
install -m0644 kali.list     /etc/apt/sources.list.d/kali.list
install -m0644 kali-pin.pref /etc/apt/preferences.d/kali-pin

# 3. apt-get update; the 6 tools now resolve, nothing else is overridden
```

The pin (`Pin-Priority: 100`, `Pin: release o=Kali`) guarantees the Debian base
(libc, kernel, systemd, every `main` package) is never pulled from Kali.

## Option B: fully Kali-free (`VACTI_NO_KALI_REPO=1`)

Skip the Kali source entirely; the engine's existing runtime fallbacks cover the
same 6 tools:

- `nuclei`, `httpx-toolkit` (httpx), `naabu`, `dnsx`, `katana` - `go install`
- `feroxbuster` - pinned GitHub release binary
- `seclists` - `git clone` of danielmiessler/SecLists into `/usr/share/seclists`
- `commix` - `git clone` of commixproject/commix

Option B produces an image with zero Kali apt metadata at the cost of a slower,
network-dependent first provisioning for those tools.
