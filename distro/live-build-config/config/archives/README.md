# archives

- `vacti.list.chroot` - the vacti private apt source line (public; no creds).
- `vacti.key.chroot` - PLACEHOLDER for the repo signing key (ASCII-armored).
  The vacti repo uses `[trusted=yes]` over an authenticated HTTPS channel, so a
  signing key is optional; drop the real key here if the repo is signed.
- `kali.list.chroot` + `kali-pin` - Option A Kali package source, pinned prio 100.
