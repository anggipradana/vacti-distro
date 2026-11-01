# syntax=docker/dockerfile:1.7
# vacti-distro universal container image.
#
# The container form of the vacti pentest appliance. It reproduces the golden
# disk's capability (vacti-engine + the lean web/infra arsenal + the first-run
# enrollment flow) in a container, for ephemeral "docker run" pentest sessions
# with no VM and no ISO. It mirrors distro/golden-image/build-golden.sh: a
# Debian 13 (trixie) base, the pinned Kali apt source for the handful of
# Kali-only tools, NodeSource Node 22, then the vacti-engine .deb installed from
# the private apt repo. The arsenal is DERIVED from the engine's own manifest
# (the same single source of truth the golden and ISO builds use), so it never
# hand-drifts from the engine.
#
# NO SECRET IS BAKED. The private-repo apt credential arrives only as a BuildKit
# secret mount (id=vacti_apt_token) and its auth file is removed in the same
# layer that used it; the enrollment token is supplied per-run at "docker run",
# never on disk. The image is inert without a live vacti enrollment, exactly like
# the .deb and the disk images.
#
# Multi-arch: debian:trixie-slim publishes linux/amd64 and linux/arm64, and the
# flat vacti apt repo serves a native .deb for each (dpkg resolves the right arch
# automatically), so a single buildx invocation produces one manifest list with
# both arch children.

FROM debian:trixie-slim

# Build-time inputs. None of these is a secret (the apt token is a secret mount
# below). VACTI_APT_URL and the engine ref/version are fed from the CI env.
ARG VACTI_APT_URL="https://repo.example.com"
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

# --- vacti-engine + arsenal from the PRIVATE apt repo (credential is a secret) -
# The whole private-repo transaction lives in ONE layer with the token mounted as
# a BuildKit secret: write the auth file, install the engine, derive and install
# the arsenal from the INSTALLED engine manifest (phase order mirrors
# build-golden.sh), then remove the auth file and the private source so no
# credential and no authful source line ever lands in an image layer.
# Word-splitting of ${ENGINE_SPEC} and ${PKGS} into apt args is intentional.
# hadolint ignore=DL3008,DL3015,SC2086
RUN --mount=type=secret,id=vacti_apt_token set -eu; \
    APT_SCHEME_HOST="${VACTI_APT_URL%/}"; \
    APT_MACHINE="$(printf '%s/apt' "${APT_SCHEME_HOST}" | sed -E 's#^[a-z]+://##')"; \
    TOKEN="$(cat /run/secrets/vacti_apt_token)"; \
    install -d -m0700 /etc/apt/auth.conf.d; \
    printf 'machine %s login vacti password %s\n' "${APT_MACHINE}" "${TOKEN}" \
      > /etc/apt/auth.conf.d/vacti-engine.conf; \
    chmod 0600 /etc/apt/auth.conf.d/vacti-engine.conf; \
    printf 'deb [trusted=yes] %s/apt ./\n' "${APT_SCHEME_HOST}" \
      > /etc/apt/sources.list.d/vacti-engine.list; \
    apt-get update; \
    if [ -n "${VACTI_ENGINE_REF}" ]; then \
      ENGINE_SPEC="${VACTI_ENGINE_PKG}=${VACTI_ENGINE_REF}*"; \
    else \
      ENGINE_SPEC="${VACTI_ENGINE_PKG}"; \
    fi; \
    echo "[docker] installing ${ENGINE_SPEC}"; \
    apt-get install -y --no-install-recommends ${ENGINE_SPEC} \
      || apt-get install -y --no-install-recommends "${VACTI_ENGINE_PKG}"; \
    echo "[docker] deriving the lean arsenal from the installed engine manifest"; \
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
    echo "[docker] FINALIZE: removing the build-time apt credential + private source"; \
    rm -f /etc/apt/auth.conf.d/vacti-engine.conf; \
    rm -f /etc/apt/sources.list.d/vacti-engine.list; \
    rm -rf /var/lib/apt/lists/*

# --- FINALIZE identity + housekeeping (no credential in this layer) ------------
# Zero the machine identity so every container start is a fresh engine, drop the
# build-only staging tree and any methodology that must never ship, and prepare
# the state volume. Mirrors the golden image FINALIZE block.
RUN set -eu; \
    rm -rf /opt/vacti-build; \
    rm -rf /root/.claude /etc/vacti-engine/.claude 2>/dev/null || true; \
    rm -f /usr/sbin/policy-rc.d; \
    : > /etc/machine-id; \
    rm -f /var/lib/dbus/machine-id 2>/dev/null || true; \
    ln -sf /etc/machine-id /var/lib/dbus/machine-id 2>/dev/null || true; \
    rm -f /etc/ssh/ssh_host_* 2>/dev/null || true; \
    apt-get clean; \
    rm -rf /var/log/apt/* /tmp/* /var/tmp/* 2>/dev/null || true; \
    install -d -m0755 "${ENGINE_STATE_DIR}"

VOLUME ["/var/lib/vacti-engine"]
WORKDIR /usr/lib/vacti-engine

# The engine traps SIGTERM for a graceful finish-the-tick shutdown (matches the
# systemd unit KillSignal=SIGTERM); there is no systemd watchdog in a container,
# so Docker HEALTHCHECK + --restart replace Type=notify/WatchdogSec.
STOPSIGNAL SIGTERM
# Shell-form CMD is required here for the `||` fallback (exec form cannot express it).
# hadolint ignore=DL3025
HEALTHCHECK --interval=30s --timeout=5s --start-period=180s --retries=4 \
  CMD pgrep -f "dist/runner/cli.js" >/dev/null || exit 1

ENTRYPOINT ["/usr/local/sbin/vacti-docker-entrypoint"]
