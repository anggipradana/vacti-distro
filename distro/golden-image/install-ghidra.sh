#!/bin/sh
# install-ghidra.sh - bake Ghidra (NSA SRE) + a FULL Temurin JDK into the golden
# image as REA's native-decompile engine. MANDATORY on every image: runs
# UNCONDITIONALLY from build-golden.sh's in-guest provision step.
#
# PIN DICTATED BY REA 6.4.0, NOT by the engine's bootstrap-apt.sh. REA's
# src/ghidra/GhidraInstallationPolicy.ts hard-requires:
#   - Ghidra major==12 && minor==1 (SUPPORTED_GHIDRA_VERSION = 12.1.4), and
#   - a 64-bit FULL JDK matching Ghidra's declared application.java.min/max
#     (major 21) - a jre / jre-headless is REJECTED as runtime-only.
# So an 11.x Ghidra or an openjdk-21-jre-headless would be installed-but-UNUSABLE
# by REA. We therefore pin Ghidra 12.1.4 + the FULL Temurin 21 JDK, matching the
# exact assets + SHA256 the fleet install agent verified empirically (analyzeHeadless
# import + `rea doctor` green). Keep in sync with vacti-appliance.env (VACTI_GHIDRA_*
# / VACTI_JDK_*) and the ISO hook 0310-ghidra.hook.chroot (same body).
#
# DISTRO vs the fleet agent: the fleet writes the env into /etc/vacti-engine/engine.env
# (which exists on a LIVE, post-enroll engine). The golden image must NOT contain
# engine.env - it is a FORBIDDEN path in ci/no-secret-scan.sh (it holds scoped
# tokens, written only at first-boot enrollment). So we bake GHIDRA_INSTALL_DIR +
# JAVA_HOME via (a) /etc/environment, (b) /etc/profile.d, and (c) a systemd drop-in
# for vacti-engine.service (the actual consumer that launches the REA MCP).
#
# SIZE: Ghidra ~1GB unpacked + Temurin JDK ~0.3GB under /opt (deliberate; native RE
# on every appliance). POSIX sh; best-effort, with SHA256 integrity gating: a
# transient blip or a checksum mismatch warns and leaves Ghidra absent (REA reports
# it + runtime self-heal/minting covers it) rather than shipping a wrong binary or
# aborting a multi-GB build.
set -u

GHIDRA_VERSION="${VACTI_GHIDRA_VERSION:-12.1.4}"
GHIDRA_RELEASE_TAG="${VACTI_GHIDRA_TAG:-Ghidra_12.1.4_build}"
GHIDRA_ASSET="${VACTI_GHIDRA_ASSET:-ghidra_12.1.4_PUBLIC_20260921.zip}"
GHIDRA_SHA256="${VACTI_GHIDRA_SHA256:-ddac49f903da9d5bac833e5cc79395098b9c33cfd3279be5f31bd00387d2d4db}"
GHIDRA_DIR="${VACTI_GHIDRA_DIR:-/opt/ghidra_12.1.4_PUBLIC}"   # top-level dir inside the zip

JDK_TARBALL="${VACTI_JDK_TARBALL:-OpenJDK21U-jdk_x64_linux_hotspot_21.0.12.1_1.tar.gz}"
JDK_URL="${VACTI_JDK_URL:-https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.12.1%2B1/${JDK_TARBALL}}"
JDK_SHA256="${VACTI_JDK_SHA256:-ce79869e1307ed8ee1e2baa86a412b1eb5b75d10a01006d788a6f968bcfaee94}"
JDK_DIR="${VACTI_JDK_DIR:-/opt/jdk-21.0.12.1+1}"              # top-level dir inside the tarball

PROFD="/etc/profile.d/vacti-ghidra.sh"
UNIT_DROPIN_DIR="/etc/systemd/system/vacti-engine.service.d"
UNIT_DROPIN="${UNIT_DROPIN_DIR}/10-ghidra-env.conf"

log()  { echo "[ghidra] $*"; }
warn() { echo "[ghidra][warn] $*" >&2; }

export DEBIAN_FRONTEND=noninteractive

# Temurin tarball is x86_64-only; Ghidra itself is pure-Java (arch-agnostic).
ARCH="$(uname -m 2>/dev/null || echo unknown)"

need() { command -v "$1" >/dev/null 2>&1; }
need curl  || { apt-get install -y --no-install-recommends curl  >/dev/null 2>&1 || warn "curl install failed"; }
need unzip || { apt-get install -y --no-install-recommends unzip >/dev/null 2>&1 || warn "unzip install failed"; }

# verify <sha256> <file>  -> 0 if match
verify() { echo "$1  $2" | sha256sum -c - >/dev/null 2>&1; }

# --- 1. FULL Temurin 21 JDK (REA rejects a runtime-only JRE) -------------------
if [ -x "${JDK_DIR}/bin/javac" ]; then
  log "full JDK present: ${JDK_DIR}"
elif [ "$ARCH" != "x86_64" ]; then
  warn "arch ${ARCH} != x86_64; the pinned Temurin x64 JDK tarball does not apply here (arm64 handled separately). Skipping JDK."
elif need curl; then
  log "downloading Temurin 21 JDK -> /opt/${JDK_TARBALL}"
  if curl -fsSL --retry 4 --retry-delay 3 -m 600 -o "/opt/${JDK_TARBALL}" "$JDK_URL"; then
    if verify "$JDK_SHA256" "/opt/${JDK_TARBALL}"; then
      ( cd /opt && tar -xzf "${JDK_TARBALL}" ) && log "JDK extracted -> ${JDK_DIR}" || warn "JDK extract failed"
      [ -x "${JDK_DIR}/bin/javac" ] && ln -sfn "${JDK_DIR}" /opt/temurin-21 || warn "javac missing after extract (${JDK_DIR})"
    else
      warn "JDK sha256 MISMATCH; discarding download (will not ship a wrong JDK)"
    fi
    rm -f "/opt/${JDK_TARBALL}"
  else
    warn "JDK download failed; Ghidra will lack a usable JDK until self-heal/minting installs one"
  fi
else
  warn "curl unavailable; skipping JDK"
fi

# --- 2. Ghidra 12.1.4 (pinned release zip -> /opt) ----------------------------
if [ -x "${GHIDRA_DIR}/support/analyzeHeadless" ]; then
  log "Ghidra present: ${GHIDRA_DIR}"
elif need curl && need unzip; then
  url="https://github.com/NationalSecurityAgency/ghidra/releases/download/${GHIDRA_RELEASE_TAG}/${GHIDRA_ASSET}"
  log "downloading Ghidra ${GHIDRA_VERSION} -> /opt/${GHIDRA_ASSET} (~543MB)"
  if curl -fsSL --retry 4 --retry-delay 3 -m 900 -o "/opt/${GHIDRA_ASSET}" "$url"; then
    if verify "$GHIDRA_SHA256" "/opt/${GHIDRA_ASSET}"; then
      if unzip -q -o "/opt/${GHIDRA_ASSET}" -d /opt; then
        [ -x "${GHIDRA_DIR}/support/analyzeHeadless" ] \
          || GHIDRA_DIR="$(find /opt -maxdepth 1 -type d -name 'ghidra_12.1.4*' 2>/dev/null | sort | tail -1)"
        if [ -n "${GHIDRA_DIR}" ] && [ -x "${GHIDRA_DIR}/support/analyzeHeadless" ]; then
          chmod +x "${GHIDRA_DIR}/ghidraRun" "${GHIDRA_DIR}/support/analyzeHeadless" 2>/dev/null || true
          ln -sfn "${GHIDRA_DIR}" /opt/ghidra
          ln -sf "${GHIDRA_DIR}/ghidraRun" /usr/local/bin/ghidra 2>/dev/null || true
          ln -sf "${GHIDRA_DIR}/support/analyzeHeadless" /usr/local/bin/analyzeHeadless 2>/dev/null || true
          log "installed ${GHIDRA_DIR} + symlinked ghidra/analyzeHeadless onto PATH"
        else
          warn "analyzeHeadless missing after extract; Ghidra unusable"
        fi
      else
        warn "Ghidra unzip failed; Ghidra unavailable"
      fi
    else
      warn "Ghidra sha256 MISMATCH; discarding download (will not ship a wrong binary)"
    fi
    rm -f "/opt/${GHIDRA_ASSET}"
  else
    warn "Ghidra download failed (${url}); unavailable until self-heal/minting installs it"
  fi
else
  warn "curl/unzip missing; skipping Ghidra"
fi

# --- 3. bake GHIDRA_INSTALL_DIR + JAVA_HOME into the image ---------------------
GH_ROOT=""
[ -x "${GHIDRA_DIR}/support/analyzeHeadless" ] && GH_ROOT="${GHIDRA_DIR}"
JAVA_HOME_DIR=""
[ -x "${JDK_DIR}/bin/javac" ] && JAVA_HOME_DIR="${JDK_DIR}"

# (a) login-shell env
{
  echo "# vacti: Ghidra 12.1.4 + Temurin JDK 21 for REA's native decompile path."
  [ -n "${GH_ROOT}" ]       && echo "export GHIDRA_INSTALL_DIR=${GH_ROOT}"
  [ -n "${JAVA_HOME_DIR}" ] && echo "export JAVA_HOME=${JAVA_HOME_DIR}"
} > "$PROFD"
chmod 0644 "$PROFD"

# (b) system-wide env (PAM) - idempotent
sed -i '/^GHIDRA_INSTALL_DIR=/d; /^JAVA_HOME=/d' /etc/environment 2>/dev/null || true
[ -n "${GH_ROOT}" ]       && echo "GHIDRA_INSTALL_DIR=${GH_ROOT}" >> /etc/environment
[ -n "${JAVA_HOME_DIR}" ] && echo "JAVA_HOME=${JAVA_HOME_DIR}" >> /etc/environment

# (c) systemd drop-in for the engine service (the real consumer that spawns the
#     REA MCP). Not a secret -> passes ci/no-secret-scan. Inert if the unit is absent.
if [ -n "${GH_ROOT}" ] || [ -n "${JAVA_HOME_DIR}" ]; then
  mkdir -p "$UNIT_DROPIN_DIR"
  {
    echo "# vacti: REA native-decompile env (Ghidra + JDK). Generated by install-ghidra.sh."
    echo "[Service]"
    [ -n "${GH_ROOT}" ]       && echo "Environment=GHIDRA_INSTALL_DIR=${GH_ROOT}"
    [ -n "${JAVA_HOME_DIR}" ] && echo "Environment=JAVA_HOME=${JAVA_HOME_DIR}"
  } > "$UNIT_DROPIN"
  chmod 0644 "$UNIT_DROPIN"
fi

log "Ghidra bake complete (GHIDRA_INSTALL_DIR=${GH_ROOT:-unset}, JAVA_HOME=${JAVA_HOME_DIR:-unset})"
