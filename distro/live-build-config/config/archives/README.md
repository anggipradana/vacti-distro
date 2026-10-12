# archives

live-build processes `config/archives/*` very early, during the `chroot_prep`
archives stage, and apt-updates every source there BEFORE any `config/includes.*`
overlay (which carries the vacti credential + TLS-off) is laid down. So the vacti
private source does NOT live here - it cannot be authenticated at that point and a
401/TLS failure there is fatal. It is staged instead into
`config/includes.chroot_before_packages/etc/apt/` by `build-iso.sh` (source +
build-time auth.conf + TLS-off), which lands right before package installation and
is stripped by the `0900-remove-build-auth` hook before squashfs.

- `kali.list.chroot` + `kali.pref.chroot` - Option A Kali package source, pinned
  prio 100. Its signing key (`kali.key.chroot`) is materialized by `build-iso.sh`
  at build time; a `.key.chroot` IS installed by the archives stage before its
  apt-update, so the Kali source (unlike the authenticated vacti source) is fine here.
