#!/usr/bin/env bash
# install-ctf-arsenal.sh - the CTF tool set installer (VACTI_CTF_ARSENAL=1).
#
# Runs INSIDE the guest during build-golden.sh's provision step, invoked ONLY
# when VACTI_CTF_ARSENAL=1. Self-contained: it installs the apt half (from a CTF
# apt list DERIVED from the engine manifest, passed in by provision.sh via
# gen-live-build-list.sh VACTI_GEN_MODE=ctf-apt) PLUS the non-apt half (ruby gems, pipx tools, the
# GEF gdb plugin, and an exploitdb git fallback). It is deliberately kept lean -
# NO sagemath (~2GB), NO Ghidra (JDK + hundreds of MB), NO stegsolve (java GUI,
# useless on a headless appliance).
#
# Design:
#   - Default OFF. kind=ctf engagements otherwise self-heal the heavy tools
#     post-boot; baking them is an operator opt-in for a CTF-ready appliance.
#   - Every install is BEST-EFFORT: a tool that will not install here logs a
#     warning and the build continues (runtime self-heal / the operator covers
#     the gap). Only a usage error in THIS script is fatal.
#   - Non-interactive throughout (DEBIAN_FRONTEND, gem --no-document, pipx
#     --force), suitable for virt-customize / live-build with no TTY.
#
# This script (and the generated CTF apt list) are staged under /opt/vacti-build,
# which build-golden.sh's FINALIZE step rm -rf's before the disk is sealed - so no
# CTF tool manifest or installer is left on the shipped image.
#
# Usage: install-ctf-arsenal.sh [CTF_LIST_PATH]
#   CTF_LIST_PATH  apt package list (default: /opt/vacti-build/ctf-apt.list). When
#                  absent (a dev-box run), it is derived from the engine manifest
#                  via the sibling packages/gen-live-build-list.sh (ctf-apt mode).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CTF_LIST="${1:-/opt/vacti-build/ctf-apt.list}"
if [[ ! -f "$CTF_LIST" ]]; then
  # dev-box / fallback: derive the CTF apt set from the engine manifest.
  _gen="${HERE}/../packages/gen-live-build-list.sh"
  if [[ -x "$_gen" ]]; then
    CTF_LIST="$(mktemp)"
    VACTI_GEN_MODE=ctf-apt "$_gen" "$CTF_LIST" >/dev/null 2>&1 || true
  fi
fi

export DEBIAN_FRONTEND=noninteractive
export PIP_BREAK_SYSTEM_PACKAGES=1   # trixie PEP-668; pipx is isolated anyway
export GEM_HOME="${GEM_HOME:-/var/lib/gems}"

log()  { echo "[ctf] $*"; }
warn() { echo "[ctf][warn] $*" >&2; }

# Make pipx-installed tools available on PATH for every user, now and at boot.
export PIPX_HOME="/opt/pipx"
export PIPX_BIN_DIR="/usr/local/bin"
mkdir -p "$PIPX_HOME" "$PIPX_BIN_DIR"

# --- 1. apt half (from the manifest-derived CTF apt list) --------------------
if [[ -f "$CTF_LIST" ]]; then
  mapfile -t CTF_PKGS < <(sed -e 's/#.*$//' -e 's/[[:space:]]\+$//' "$CTF_LIST" | grep -vE '^[[:space:]]*$')
  log "apt: installing ${#CTF_PKGS[@]} CTF packages from $(basename "$CTF_LIST")"
  apt-get update -y || warn "apt-get update failed; continuing best-effort"
  if ! apt-get install -y --no-install-recommends "${CTF_PKGS[@]}"; then
    warn "bulk CTF apt install hit a snag; retrying per-package"
    for p in "${CTF_PKGS[@]}"; do
      apt-get install -y --no-install-recommends "$p" \
        || warn "apt package '$p' not installable here (self-heal/operator covers it)"
    done
  fi
else
  warn "CTF apt list not found at $CTF_LIST; skipping apt half"
fi

# --- 2. ruby gems (not in Debian: zsteg, one_gadget) -------------------------
if command -v gem >/dev/null 2>&1; then
  for g in zsteg one_gadget; do
    log "gem: installing ${g}"
    gem install --no-document "$g" || warn "gem '${g}' install failed (best-effort)"
  done
else
  warn "ruby/gem unavailable; skipping zsteg + one_gadget"
fi

# --- 3. pipx tools (not in Debian main: volatility3, RsaCtfTool) -------------
if command -v pipx >/dev/null 2>&1; then
  log "pipx: installing volatility3"
  pipx install --force volatility3 || warn "pipx volatility3 install failed (best-effort)"
  log "pipx: installing RsaCtfTool (from upstream git)"
  pipx install --force "git+https://github.com/RsaCtfTool/RsaCtfTool.git" \
    || warn "pipx RsaCtfTool install failed (best-effort; heavy optional deps)"
else
  warn "pipx unavailable; skipping volatility3 + RsaCtfTool"
fi

# --- 4. GEF (lightweight gdb plugin for pwn) ---------------------------------
# GEF is a single ~1MB Python script - the lean CTF-standard gdb enhancement.
# We deliberately prefer it over pwndbg, whose setup.sh pulls hundreds of MB of
# pip deps; an operator who needs pwndbg specifically can add it post-boot.
if command -v gdb >/dev/null 2>&1; then
  log "installing GEF gdb plugin (lean; pwndbg deliberately skipped)"
  if curl -fsSL -o /opt/gef.py https://raw.githubusercontent.com/hugsy/gef/main/gef.py; then
    printf 'source /opt/gef.py\n' > /etc/gdb/gdbinit.d/gef.gdb 2>/dev/null \
      || { mkdir -p /etc/gdb/gdbinit.d && printf 'source /opt/gef.py\n' > /etc/gdb/gdbinit.d/gef.gdb; } \
      || printf '\nsource /opt/gef.py\n' >> /etc/gdb/gdbinit
  else
    warn "GEF download failed (best-effort)"
  fi
else
  warn "gdb unavailable; skipping GEF"
fi

# --- 5. exploitdb / searchsploit git fallback --------------------------------
# apt (Kali source) is the primary path; if searchsploit is still missing, clone
# the upstream database and symlink the binary.
if ! command -v searchsploit >/dev/null 2>&1; then
  log "exploitdb: apt did not supply searchsploit; cloning upstream database"
  if git clone --depth 1 https://gitlab.com/exploit-database/exploitdb.git /opt/exploitdb; then
    ln -sf /opt/exploitdb/searchsploit /usr/local/bin/searchsploit
  else
    warn "exploitdb git clone failed (best-effort)"
  fi
fi

log "CTF arsenal install complete (best-effort tools may have been skipped above)"
