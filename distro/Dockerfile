# syntax=docker/dockerfile:1.7
# vacti-distro universal container image.
#
# The container form of the vacti pentest appliance. It ships the lean web/infra
# arsenal + the enrollment flow in a container, for ephemeral "docker run" pentest
# sessions with no VM and no ISO. It mirrors distro/golden-image/build-golden.sh: a
# Debian 13 (trixie) base, the pinned Kali apt source for the handful of Kali-only
# tools, NodeSource Node 22, then the arsenal DERIVED from the vendored engine
# manifest snapshot.
#
# THIN-BOOTSTRAP: the vacti-engine package is NOT baked into the image. The engine
# .deb (dist + prompt-bundle + skill-bundle = the real IP, plus its bundled
# Chromium) is pulled at CONTAINER START by the entrypoint from the private apt
# repo, using the per-run enrollment token. A published image therefore carries NO
# engine code and NO plain-text methodology for anyone to inspect.
#
# NO SECRET AND NO PRIVATE HOST ARE BAKED. The arsenal comes entirely from public
# sources (Debian + the pinned Kali repo + NodeSource), so the build needs neither
# the private apt repo nor its credential: there is no secret mount and no private
# source line in any layer. The enrollment token (and the control-plane URL) are
# supplied per-run at "docker run", never on disk. The image is inert without a
# live vacti enrollment.
#
# Multi-arch: debian:trixie-slim publishes linux/amd64 and linux/arm64, and the
# flat vacti apt repo serves a native .deb for each (dpkg resolves the right arch
# automatically), so a single buildx invocation produces one manifest list with
# both arch children.

# =============================================================================
# Stage 1 (builder): the full install, INCLUDING the private-apt transaction.
# This stage is never published; its history may name the private apt host.
# =============================================================================
FROM debian:trixie-slim AS builder

# Build-time inputs. None of these is a secret (the apt token is a secret mount
# below). VACTI_APT_URL and the engine ref/version are fed from the CI env.
# The ARG default is EMPTY on purpose so no private host is baked into metadata;
# CI supplies the real value with --build-arg VACTI_APT_URL=...
ARG VACTI_APT_URL=""
ARG VACTI_ENGINE_PKG="vacti-engine"
ARG VACTI_ENGINE_REF=""
ARG VACTI_FULL_ARSENAL="0"
ARG VACTI_NO_KALI_REPO="0"
ARG NODE_MAJOR="22"

ENV DEBIAN_FRONTEND=noninteractive \
    APP=/usr/lib/vacti-engine \
    ENGINE_STATE_DIR=/var/lib/vacti-engine \
    PLAYWRIGHT_BROWSERS_PATH=/usr/lib/vacti-engine/ms-playwright \
    DISPLAY=:0 \
    VACTI_AUTO_UPDATE=0

# Fail a piped RUN if any stage of the pipe fails (curl | gpg, curl | bash).
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Arsenal derivation inputs (the manifest generator plus its data) and the
# container entrypoint. Staged under a build-only dir that the FINALIZE layer
# removes, so no methodology or package manifest ships on the image.
COPY distro/packages/ /opt/vacti-build/packages/
COPY distro/golden-image/docker-entrypoint.sh /usr/local/sbin/vacti-docker-entrypoint

# --- base deps + public package sources (Kali pinned prio 100, NodeSource 22) --
# No credential here, so this layer is cacheable and public. policy-rc.d blocks
# postinst from trying to START services (there is no running init in a build);
# deb-systemd-helper still records the enable symlinks offline.
# hadolint ignore=DL3008,DL3015
RUN set -eu; \
    printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d; \
    chmod 0755 /usr/sbin/policy-rc.d; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg jq procps xauth xvfb; \
    if [ "${VACTI_NO_KALI_REPO}" != "1" ]; then \
      curl -fsSL https://archive.kali.org/archive-key.asc \
        | gpg --dearmor -o /usr/share/keyrings/kali-archive-keyring.gpg; \
      install -m0644 /opt/vacti-build/packages/kali-repo/kali.list \
        /etc/apt/sources.list.d/kali.list; \
      install -m0644 /opt/vacti-build/packages/kali-repo/kali-pin.pref \
        /etc/apt/preferences.d/kali-pin; \
    fi; \
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -; \
    chmod 0755 /opt/vacti-build/packages/gen-live-build-list.sh; \
    chmod 0755 /usr/local/sbin/vacti-docker-entrypoint; \
    rm -rf /var/lib/apt/lists/*

# --- arsenal from PUBLIC sources (Debian + pinned Kali + NodeSource) -----------
# THIN-BOOTSTRAP: the vacti-engine package is NOT installed here. The engine .deb
# (dist + prompt-bundle + skill-bundle = the real IP, plus its bundled Chromium)
# is pulled at CONTAINER START by the entrypoint (vacti-docker-entrypoint), using
# the per-run enrollment token, so no engine code or methodology ever lands in a
# published image layer. No private apt repo and no secret are needed at build: the
# arsenal is DERIVED from the VENDORED manifest snapshot and installed entirely
# from Debian + the pinned Kali repo + NodeSource. Word-splitting of ${PKGS} into
# apt args is intentional.
# hadolint ignore=DL3008,DL3015,SC2086
RUN set -eu; \
    apt-get update; \
    echo "[docker] deriving the lean arsenal from the vendored engine manifest"; \
    VACTI_FULL_ARSENAL="${VACTI_FULL_ARSENAL}" VACTI_CTF_ARSENAL="0" \
      /opt/vacti-build/packages/gen-live-build-list.sh /opt/vacti-build/arsenal.list \
      || echo "[docker][warn] arsenal list generation reported an issue"; \
    PKGS="$(grep -vE '^[[:space:]]*(#|$)' /opt/vacti-build/arsenal.list 2>/dev/null || true)"; \
    if [ -n "${PKGS}" ]; then \
      echo "[docker] installing arsenal (best-effort)"; \
      apt-get install -y --no-install-recommends ${PKGS} || { \
        echo "[docker] bulk arsenal install hit a snag; retrying per-package"; \
        for p in ${PKGS}; do \
          apt-get install -y --no-install-recommends "$p" \
            || echo "[docker][warn] $p not installable here (runtime self-heal covers it)"; \
        done; \
      }; \
    else \
      echo "[docker][warn] arsenal list empty; relying on runtime self-heal"; \
    fi; \
    rm -rf /var/lib/apt/lists/*

# --- FINALIZE identity + housekeeping (no credential in this layer) ------------
# Zero the machine identity so every container start is a fresh engine, drop the
# build-only staging tree and any methodology that must never ship, and prepare
# the state volume. Mirrors the golden image FINALIZE block. Runs in the builder
# so the transferred root filesystem is already finalized and clean.
RUN set -eu; \
    rm -rf /opt/vacti-build; \
    rm -rf /root/.claude /etc/vacti-engine/.claude 2>/dev/null || true; \
    rm -f /usr/sbin/policy-rc.d; \
    : > /etc/machine-id; \
    rm -f /var/lib/dbus/machine-id 2>/dev/null || true; \
    ln -sf /etc/machine-id /var/lib/dbus/machine-id 2>/dev/null || true; \
    rm -f /etc/ssh/ssh_host_* 2>/dev/null || true; \
    apt-get clean; \
    rm -rf /var/log/apt/* /tmp/* /var/tmp/* /var/cache/apt/archives/*.deb 2>/dev/null || true; \
    install -d -m0755 "${ENGINE_STATE_DIR}"

# =============================================================================
# Stage 2 (final, published): a fresh base that ingests the builder's fully
# installed and finalized root filesystem. This stage performs NO apt operation
# and references NO private host: the only thing it pulls from the builder is the
# complete installed filesystem, streamed over a build-time bind mount so no
# intermediate tarball is persisted in a layer. The resulting image therefore
# carries the identical install state (arsenal packages, Chromium shared-lib
# closure, dpkg database, base runtime) - but NOT the vacti-engine package, which
# the entrypoint installs at container start.
# =============================================================================
FROM debian:trixie-slim

# Runtime environment (ENV is image metadata, not filesystem, so it is declared
# here; it is identical to the builder's runtime env). None of these name a
# private host.
ENV DEBIAN_FRONTEND=noninteractive \
    APP=/usr/lib/vacti-engine \
    ENGINE_STATE_DIR=/var/lib/vacti-engine \
    PLAYWRIGHT_BROWSERS_PATH=/usr/lib/vacti-engine/ms-playwright \
    DISPLAY=:0 \
    VACTI_AUTO_UPDATE=0

# Fail the transfer pipe if the producing tar errors (otherwise the extracting
# tar's exit status would mask a partial stream).
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Ingest the builder's finalized root filesystem. The builder stage is bind
# mounted read-only at /builder-root and its contents are streamed straight into
# the final layer (tar | tar), so every installed file, user/group, systemd unit,
# chromium, the dpkg database, and the arsenal land here byte-for-byte. The
# pseudo/volatile directories are excluded so docker's own runtime mounts
# (/proc, /sys, /dev, /tmp, /run) are not shadowed by empty build-time dirs, and
# /etc/resolv.conf, /etc/hostname and /etc/hosts are excluded because docker
# bind-mounts them (read-only here, regenerated per-run) and they cannot be
# overwritten by the extract.
# hadolint ignore=DL3059
RUN --mount=type=bind,from=builder,source=/,target=/builder-root,readonly set -eu; \
    tar -C /builder-root --numeric-owner --one-file-system -p -cf - \
      --exclude=./proc --exclude=./sys --exclude=./dev \
      --exclude=./tmp --exclude=./run --exclude=./builder-root \
      --exclude=./var/cache/apt/archives --exclude=./var/lib/apt/lists \
      --exclude=./etc/resolv.conf --exclude=./etc/hostname --exclude=./etc/hosts \
      . \
    | tar -C / --numeric-owner -p -xf -

VOLUME ["/var/lib/vacti-engine"]
# THIN-BOOTSTRAP: do NOT WORKDIR into /usr/lib/vacti-engine - that would create the
# engine dir (empty) in the published image. The engine tree is created by the
# first-boot/container-start install; the entrypoint cd's into $APP after it installs.
WORKDIR /

# The engine traps SIGTERM for a graceful finish-the-tick shutdown (matches the
# systemd unit KillSignal=SIGTERM); there is no systemd watchdog in a container,
# so Docker HEALTHCHECK + --restart replace Type=notify/WatchdogSec.
STOPSIGNAL SIGTERM
# Shell-form CMD is required here for the `||` fallback (exec form cannot express it).
# hadolint ignore=DL3025
HEALTHCHECK --interval=30s --timeout=5s --start-period=180s --retries=4 \
  CMD pgrep -f "dist/runner/cli.js" >/dev/null || exit 1

ENTRYPOINT ["/usr/local/sbin/vacti-docker-entrypoint"]
