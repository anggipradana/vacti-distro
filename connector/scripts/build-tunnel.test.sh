#!/usr/bin/env bash
# build-tunnel.test.sh - prove connector/scripts/build-tunnel.sh compiles vacti-tunnel with the EXACT same
# go build flags as the connector image (deploy/Dockerfile.connector), for each arch, and that it can never
# silently drift from the Dockerfile.
#
# It runs build-tunnel.sh against a fake `go` on PATH that records its argv + the CGO_ENABLED/GOOS/GOARCH
# env, then asserts:
#   1. the recorded invocation equals the canonical flag sequence (CGO_ENABLED=0, GOOS=linux, trimpath,
#      ldflags "-s -w -X main.version=<VERSION>", -o <out>, ./cmd/tunnel) with the correct per-arch GOARCH;
#   2. that same canonical flag sequence is literally present in deploy/Dockerfile.connector (so a Dockerfile
#      edit that changes the flags fails THIS test until build-tunnel.sh is updated to match).
#
# Run: bash connector/scripts/build-tunnel.test.sh
set -euo pipefail

MOD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="${MOD_ROOT}/scripts/build-tunnel.sh"
DOCKERFILE="${MOD_ROOT}/deploy/Dockerfile.connector"
VERSION="$(tr -d '[:space:]' < "${MOD_ROOT}/VERSION")"
for f in "$HELPER" "$DOCKERFILE"; do [ -f "$f" ] || { echo "FAIL: missing $f"; exit 1; }; done

PASS=0
ok()  { echo "  ok: $*"; PASS=$((PASS + 1)); }
die() { echo "FAIL: $*" >&2; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
SHIM="${WORK}/bin"; mkdir -p "$SHIM"
cat > "${SHIM}/go" <<'EOF'
#!/usr/bin/env bash
{ echo "ARGV:$*"; echo "ENV:CGO_ENABLED=${CGO_ENABLED-} GOOS=${GOOS-} GOARCH=${GOARCH-}"; } > "$GO_SHIM_LOG"
prev=""; out=""; for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
[ -n "$out" ] && : > "$out"
exit 0
EOF
chmod +x "${SHIM}/go"

# --- 2. the canonical flags must literally appear in the Dockerfile (drift both ways) ----
# Dockerfile line: go build -trimpath -ldflags "-s -w -X main.version=${VERSION}" -o /out/vacti-tunnel ./cmd/tunnel
grep -Eq 'CGO_ENABLED=0 GOOS=\$TARGETOS GOARCH=\$TARGETARCH' "$DOCKERFILE" \
  || die "Dockerfile no longer sets CGO_ENABLED=0 GOOS=\$TARGETOS GOARCH=\$TARGETARCH - update the helper + this test together"
grep -Eq 'go build -trimpath -ldflags "-s -w -X main\.version=\$\{VERSION\}" -o /out/vacti-tunnel \./cmd/tunnel' "$DOCKERFILE" \
  || die "Dockerfile tunnel build flags changed - update build-tunnel.sh + this test together"
ok "Dockerfile.connector still carries the canonical tunnel build flags"

# --- 1. the helper reproduces those flags for each arch, with the right GOARCH ----------
for arch in amd64 arm64; do
  export GO_SHIM_LOG="${WORK}/go-${arch}.log"
  PATH="${SHIM}:${PATH}" bash "$HELPER" "$arch" "${WORK}/vacti-tunnel-${arch}" >/dev/null 2>&1 \
    || die "helper failed for ${arch}"
  argv="$(sed -n 's/^ARGV://p' "$GO_SHIM_LOG")"
  env_line="$(sed -n 's/^ENV://p' "$GO_SHIM_LOG")"
  want_argv="build -trimpath -ldflags -s -w -X main.version=${VERSION} -o ${WORK}/vacti-tunnel-${arch} ./cmd/tunnel"
  want_env="CGO_ENABLED=0 GOOS=linux GOARCH=${arch}"
  [ "$argv" = "$want_argv" ] || die "${arch} go argv mismatch:\n  got:  ${argv}\n  want: ${want_argv}"
  [ "$env_line" = "$want_env" ] || die "${arch} go env mismatch:\n  got:  ${env_line}\n  want: ${want_env}"
  ok "${arch}: go invocation == Dockerfile flags (GOOS=linux, GOARCH=${arch}, -ldflags -s -w -X main.version=${VERSION})"
done

echo "PASS: build-tunnel.test.sh (${PASS} assertions)"
