#!/bin/sh
# install-rea.sh - bake REA (Reverse Engineer Anything, npm `rea-agents`) into
# the golden image. MANDATORY on every image: runs UNCONDITIONALLY during
# build-golden.sh's in-guest provision step (no opt-in flag), unlike the opt-in
# install-ctf-arsenal.sh.
#
# What the DISTRO bakes (and only this): the RUNTIME for REA -
#   1. a Node runtime that meets REA's engine floor (^22.19 || ^24.11 || >=26), and
#   2. the globally-installed, PINNED `rea-agents` package,
# so the engine's agent can launch the local `rea` MCP server
# (`npx -y rea-agents@<ver> mcp`, or the global `rea` bin) deterministically and
# OFFLINE on a shipped appliance.
#
# What the distro does NOT do here (by design): it does NOT register the MCP
# server in a Claude config and does NOT copy the reverse-engineer-anything skill
# onto disk. Those are the ENGINE/MINTING side's job (packaging/bootstrap-apt.sh
# + the engine .deb's baked `mcp` config + off-box skill delivery). The appliance
# ships ZERO `.claude` methodology on disk - ci/no-secret-scan.sh FAILS the build
# if any `.claude` dir is present - so writing the skill/MCP config here would
# both break that invariant and duplicate what the engine already carries.
#
# PINNED per the 2026-10-13 REA safety vetting (registry metadata showed NO
# pre/post-install scripts; --ignore-scripts is defense-in-depth). Keep the pin
# in sync with vacti-appliance.env VACTI_REA_VERSION and with the ISO path's
# live-build-config/config/hooks/normal/0300-rea.hook.chroot (same body).
#
# POSIX sh (no bashisms) so the golden installer and the ISO /bin/sh hook share
# one copy-identical body. Non-interactive, best-effort: a transient npm/registry
# blip logs a warning and lets the (multi-GB) image build continue - the engine's
# runtime self-heal / the minting installer covers any gap. Only a usage error is
# fatal.
set -u

REA_VERSION="${REA_VERSION:-6.4.0}"

log()  { echo "[rea] $*"; }
warn() { echo "[rea][warn] $*" >&2; }

export DEBIAN_FRONTEND=noninteractive

# REA requires Node ^22.19.0 || ^24.11.0 || >=26.0.0 (and npm on PATH).
node_satisfies() {
  command -v node >/dev/null 2>&1 || return 1
  command -v npm  >/dev/null 2>&1 || return 1
  v=$(node -v 2>/dev/null | sed 's/^v//')
  maj=${v%%.*}
  rest=${v#*.}
  min=${rest%%.*}
  case "$maj" in ''|*[!0-9]*) return 1 ;; esac
  case "$min" in ''|*[!0-9]*) min=0 ;; esac
  [ "$maj" -eq 22 ] && [ "$min" -ge 19 ] && return 0
  [ "$maj" -eq 24 ] && [ "$min" -ge 11 ] && return 0
  [ "$maj" -ge 26 ] && return 0
  return 1
}

# --- 1. Node floor (NodeSource 22.x satisfies ^22.19) ------------------------
if node_satisfies; then
  log "Node $(node -v 2>/dev/null) + npm present; satisfies REA floor"
else
  log "Node missing or below REA floor; installing NodeSource Node.js 22.x"
  if curl -fsSL https://deb.nodesource.com/setup_22.x | bash -; then
    apt-get install -y --no-install-recommends nodejs || warn "nodejs install failed"
  else
    warn "NodeSource setup failed (runtime self-heal / minting covers REA's Node)"
  fi
fi

# --- 2. REA (pinned, scripts ignored) ----------------------------------------
if ! command -v npm >/dev/null 2>&1; then
  warn "npm unavailable after Node provisioning; skipping rea-agents (self-heal covers it)"
else
  log "npm install -g --ignore-scripts rea-agents@${REA_VERSION}"
  if npm install -g --ignore-scripts "rea-agents@${REA_VERSION}"; then
    if rea --version >/dev/null 2>&1; then
      log "installed rea-agents: $(rea --version 2>/dev/null)"
    else
      log "rea-agents installed (global); 'rea' resolves via npx -y rea-agents@${REA_VERSION} mcp"
    fi
  else
    warn "rea-agents@${REA_VERSION} install failed (runtime self-heal / minting covers it)"
  fi
fi

# --- 3. hygiene: keep /root clean + image lean -------------------------------
# npm's global install as root writes a package cache under /root/.npm; drop it
# so the image stays lean and the no-secret scan (which greps /root) never sees a
# cached RE test fixture (REA ships sample keys/HAR) as a secret-shaped hit.
npm cache clean --force >/dev/null 2>&1 || true
rm -rf /root/.npm 2>/dev/null || true

log "REA bake complete"
