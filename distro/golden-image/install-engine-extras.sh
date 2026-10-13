#!/bin/sh
# install-engine-extras.sh - bake the engine's MANDATORY-by-default NON-apt tools
# that the package lists cannot express, into the BASE image (NOT gated on
# VACTI_FULL_ARSENAL). These are part of the canonical mandatory set confirmed by
# engine 0.2.302: CORE + web3 + REA + Ghidra. Runs UNCONDITIONALLY from
# build-golden.sh's provision step, AFTER the engine .deb + arsenal install (so
# `go`, `pipx`, the vacti-engine user, and curl/git are present).
#
# Mirrors packaging/bootstrap-apt.sh install METHODS, adapted for the distro:
#   (1) interactsh-client + gau  -> GOBIN=/usr/local/bin go install (pinned)   [step_apt go-fallbacks]
#   (2) jwt_tool                 -> git clone -> /opt/jwt_tool (run by path)   [step_jwt_tool]
#   (3) web3: slither + Foundry  -> pipx (/opt/pipx -> /usr/local/bin) + foundryup (/opt/foundry -> /usr/local/bin)  [step_web3_arsenal]
#   (4) Caido CLI + caido-mcp-server -> engine-home caido-cli + go-built MCP    [step_caido]
#
# DISTRO ADAPTATION of the engine's "as the engine user" installs: the engine runs
# slither/foundry as ${ENGINE_USER} into its home, then SYMLINKS the real binaries
# onto /usr/local/bin for service-PATH reachability. On a build-time image the
# engine user is a --system nologin account, so we install into SYSTEM locations
# (/opt/pipx, /opt/foundry) with the bin dir ON the global PATH (/usr/local/bin) -
# the same reachability outcome (the distro's own install-ctf-arsenal.sh pipx
# pattern), without the root-pipx-unreachable trap. Caido is path-coupled to the
# engine home (start-arsenal launches ${ENGINE_HOME}/caido/caido-cli), so it is
# installed into the resolved engine home.
#
# Invariants: zero .claude on disk (nothing here writes one); /root is cleaned so
# the no-secret scan sees no go/pip module cache; pinned go-tool + Caido versions
# (slither/foundry/jwt_tool are unpinned exactly as the engine leaves them).
# POSIX sh; best-effort - a transient blip warns and the (multi-GB) build continues
# (runtime self-heal / minting covers any gap). Only the apt VPN client
# globalprotect-openconnect is handled elsewhere (packages/web-lean.list).
set -u

INTERACTSH_VERSION="${VACTI_INTERACTSH_VERSION:-v1.2.4}"
GAU_VERSION="${VACTI_GAU_VERSION:-v2.2.4}"
CAIDO_VERSION="${VACTI_CAIDO_VERSION:-v0.57.0}"
CAIDO_MCP_TAG="${VACTI_CAIDO_MCP_TAG:-v1.1.0}"
JWT_TOOL_REPO="https://github.com/ticarpi/jwt_tool.git"
JWT_TOOL_DIR="/opt/jwt_tool"
FOUNDRY_DIR="/opt/foundry"

log()  { echo "[extras] $*"; }
warn() { echo "[extras][warn] $*" >&2; }
need() { command -v "$1" >/dev/null 2>&1; }

export DEBIAN_FRONTEND=noninteractive
ARCH="$(uname -m 2>/dev/null || echo unknown)"

# Resolve the engine service user + home (created by the vacti-engine .deb postinst
# during the arsenal install above). Fall back to the engine's own defaults.
ENGINE_USER="vacti-engine"
getent passwd "$ENGINE_USER" >/dev/null 2>&1 || ENGINE_USER=""
ENGINE_HOME=""
[ -n "$ENGINE_USER" ] && ENGINE_HOME="$(getent passwd "$ENGINE_USER" 2>/dev/null | cut -d: -f6)"
[ -n "$ENGINE_HOME" ] || ENGINE_HOME="/opt/vacti-engine"

# Make `go` resolvable for the go-install fallbacks (Debian golang-go = /usr/bin/go;
# a manual toolchain may be at /usr/local/go/bin).
need go || { [ -x /usr/local/go/bin/go ] && PATH="/usr/local/go/bin:$PATH" && export PATH; }

# --- (1) interactsh-client + gau (pinned go installs -> /usr/local/bin) --------
if need go; then
  if need interactsh-client; then
    log "interactsh-client already present"
  else
    log "go install interactsh-client@${INTERACTSH_VERSION} -> /usr/local/bin"
    GOBIN=/usr/local/bin go install "github.com/projectdiscovery/interactsh/cmd/interactsh-client@${INTERACTSH_VERSION}" \
      || warn "interactsh-client go install failed (OOB/SSRF confirmation degrades)"
  fi
  if need gau; then
    log "gau already present"
  else
    log "go install gau@${GAU_VERSION} -> /usr/local/bin"
    GOBIN=/usr/local/bin go install "github.com/lc/gau/v2/cmd/gau@${GAU_VERSION}" \
      || warn "gau go install failed (passive URL mining falls back to katana/wayback)"
  fi
else
  warn "go unavailable; skipping interactsh-client + gau"
fi

# --- (2) jwt_tool (git clone -> /opt/jwt_tool; run via python3 by path) --------
if [ -d "${JWT_TOOL_DIR}/.git" ]; then
  log "jwt_tool already cloned (${JWT_TOOL_DIR})"
elif need git; then
  log "jwt_tool: cloning -> ${JWT_TOOL_DIR}"
  if git clone --depth 1 "$JWT_TOOL_REPO" "$JWT_TOOL_DIR" >/dev/null 2>&1; then
    chmod -R a+rX "$JWT_TOOL_DIR" 2>/dev/null || true
    log "jwt_tool: cloned (run via 'python3 ${JWT_TOOL_DIR}/jwt_tool.py')"
  else
    warn "jwt_tool clone failed; JWT attacks degrade until installed"
  fi
else
  warn "git unavailable; skipping jwt_tool"
fi

# --- (3) web3 arsenal: slither (pipx) + Foundry (forge/cast/anvil) -------------
# slither: pipx into a SYSTEM home with the bin dir on the global PATH (reachable
# by the engine service, no root-pipx-unreachable trap). Mirrors install-ctf-arsenal.sh.
if need pipx; then
  if [ -x /usr/local/bin/slither ]; then
    log "web3: slither already installed"
  else
    log "pipx: installing slither-analyzer (web3 static analysis) -> /usr/local/bin"
    PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin PIP_BREAK_SYSTEM_PACKAGES=1 \
      pipx install slither-analyzer >/dev/null 2>&1 \
      || warn "pipx install slither-analyzer failed (web3 vertical degrades)"
  fi
else
  warn "web3: pipx not found; skipping slither-analyzer"
fi
# Foundry: official installer into a SYSTEM FOUNDRY_DIR, then symlink forge/cast/anvil
# onto /usr/local/bin. curl|bash is network-flaky -> bounded 3x retry (mirror engine).
if need curl; then
  if [ -x /usr/local/bin/forge ] && [ -x /usr/local/bin/cast ] && [ -x /usr/local/bin/anvil ]; then
    log "web3: foundry (forge/cast/anvil) already installed"
  else
    log "web3: installing Foundry (forge/cast/anvil) -> ${FOUNDRY_DIR}"
    mkdir -p "$FOUNDRY_DIR"
    _ok=0
    for _try in 1 2 3; do
      if env HOME=/root FOUNDRY_DIR="$FOUNDRY_DIR" sh -c 'curl -L --fail -m 180 https://foundry.paradigm.xyz | bash' >/dev/null 2>&1 \
         && env HOME=/root FOUNDRY_DIR="$FOUNDRY_DIR" "${FOUNDRY_DIR}/bin/foundryup" >/dev/null 2>&1; then
        _ok=1; break
      fi
      warn "web3: Foundry install attempt ${_try}/3 failed; retrying"
      sleep $(( _try * 3 ))
    done
    if [ "$_ok" = "1" ]; then
      for _fb in forge cast anvil; do
        [ -x "${FOUNDRY_DIR}/bin/${_fb}" ] && ln -sf "${FOUNDRY_DIR}/bin/${_fb}" "/usr/local/bin/${_fb}" \
          && log "linked ${_fb} -> ${FOUNDRY_DIR}/bin/${_fb}"
      done
    else
      warn "web3: Foundry install failed after 3 attempts; forge/cast/anvil unavailable until installed"
    fi
  fi
else
  warn "web3: curl not found; skipping Foundry"
fi

# --- (4) Caido CLI (guest-mode proxy/evidence) + caido-mcp-server --------------
# caido-cli is path-coupled to the engine home (start-arsenal launches
# ${ENGINE_HOME}/caido/caido-cli), so install it there; the MCP server is a
# system-wide /usr/local/bin binary.
caido_dir="${ENGINE_HOME}/caido"
caido_bin="${caido_dir}/caido-cli"
if [ -x "$caido_bin" ]; then
  log "Caido CLI already installed (${caido_bin})"
elif need curl; then
  case "$ARCH" in
    x86_64|amd64)   caido_arch="x86_64" ;;
    aarch64|arm64)  caido_arch="aarch64" ;;
    *)              caido_arch="x86_64"; warn "caido: unknown arch ${ARCH}; trying x86_64" ;;
  esac
  url="https://caido.download/releases/${CAIDO_VERSION}/caido-cli-${CAIDO_VERSION}-linux-${caido_arch}.tar.gz"
  log "caido: downloading ${CAIDO_VERSION} (${caido_arch}) -> ${caido_dir}"
  mkdir -p "$caido_dir"
  if curl -sL --fail -m 180 -o "${caido_dir}/caido-cli.tar.gz" "$url" && tar xzf "${caido_dir}/caido-cli.tar.gz" -C "$caido_dir"; then
    rm -f "${caido_dir}/caido-cli.tar.gz"
    chmod +x "$caido_bin" 2>/dev/null || true
    [ -n "$ENGINE_USER" ] && chown -R "${ENGINE_USER}:${ENGINE_USER}" "$caido_dir" 2>/dev/null || true
    log "caido: installed (${caido_bin})"
  else
    warn "caido: download failed (${url}); Caido capture self-heals post-boot"
    rm -f "${caido_dir}/caido-cli.tar.gz" 2>/dev/null || true
  fi
else
  warn "curl not found; skipping Caido CLI"
fi
# caido-mcp-server (community): go build -> /usr/local/bin (so the Caido MCP wires).
if [ -x /usr/local/bin/caido-mcp-server ]; then
  log "caido-mcp-server already installed"
elif need go && need git; then
  log "caido-mcp-server: building ${CAIDO_MCP_TAG} -> /usr/local/bin"
  _src="$(mktemp -d)"
  if git clone --depth 1 --branch "$CAIDO_MCP_TAG" https://github.com/c0tton-fluff/caido-mcp-server.git "$_src" >/dev/null 2>&1 \
     && ( cd "$_src" && GOFLAGS=-mod=mod go build -o /usr/local/bin/caido-mcp-server . >/dev/null 2>&1 ); then
    chmod +x /usr/local/bin/caido-mcp-server 2>/dev/null || true
    printf '%s\n' "$CAIDO_MCP_TAG" > /usr/local/bin/caido-mcp-server.version 2>/dev/null || true
    log "caido-mcp-server: built (${CAIDO_MCP_TAG})"
  else
    warn "caido-mcp-server build failed; the Caido MCP self-heals/minting covers it"
  fi
  rm -rf "$_src" 2>/dev/null || true
else
  warn "go/git unavailable; skipping caido-mcp-server"
fi

# --- hygiene: keep /root clean (no-secret scan greps /root) + image lean -------
go clean -cache -modcache >/dev/null 2>&1 || true
rm -rf /root/go /root/.cache /root/.foundry /root/.npm /root/.rustup /root/.cargo 2>/dev/null || true

log "engine-extras bake complete (engine_home=${ENGINE_HOME})"
