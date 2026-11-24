#!/usr/bin/env bash
# build-tunnel.sh - the ONE place the scan-side `vacti-tunnel` SOCKS5 sidecar is compiled.
#
# WHY A SHARED SCRIPT: the connector image Dockerfile (deploy/Dockerfile.connector) bakes the tunnel
# for the in-network connector trio, and the engine .deb (vacti-pentest-engine packaging/build-deb.sh,
# fed by its release CI) stages the SAME binary at /usr/lib/vacti-engine/bin/vacti-tunnel for the
# via-connector execution path (G3a). Two independent `go build` invocations would silently drift in
# their flags (strip, trimpath, the version ldflag) and ship subtly different binaries. This script is
# the single source of truth for that build command, called by BOTH:
#   - vacti-distro CI (build-docker-connector.yml, build.yml, build-arm64.yml), and
#   - vacti-pentest-engine release CI (which sparse-checks-out this connector module at a pinned ref
#     and runs this exact script), so the flags can never diverge.
#
# The build command is BYTE-FOR-BYTE the one in deploy/Dockerfile.connector (the connector-image build):
#   CGO_ENABLED=0 GOOS=linux GOARCH=<arch> go build -trimpath \
#     -ldflags "-s -w -X main.version=${VERSION}" -o <out> ./cmd/tunnel
# Pure Go, no cgo, so cross-building for any GOARCH from any host is safe (unlike the engine's native
# node-pty); still, the callers build NATIVELY per arch where they can.
#
# Usage: connector/scripts/build-tunnel.sh <goarch> <out-file>
#   <goarch>   amd64 | arm64   (the Debian/dpkg arch name; it IS the Go GOARCH for these two)
#   <out-file> absolute or relative path to write the compiled binary to (parent dir is created)
#
# VERSION: read from connector/VERSION (the connector/tunnel release version) so the binary's embedded
# main.version matches the connector release, exactly as the Dockerfile's ${VERSION} build-arg does.
set -euo pipefail

ARCH="${1:?usage: build-tunnel.sh <goarch:amd64|arm64> <out-file>}"
OUT="${2:?usage: build-tunnel.sh <goarch:amd64|arm64> <out-file>}"

case "$ARCH" in
  amd64 | arm64) ;;
  *) echo "build-tunnel: unsupported arch '$ARCH' (want amd64|arm64)" >&2; exit 2 ;;
esac

# The connector module root is the parent of this scripts/ dir, so the script works from any CWD.
MOD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="${MOD_ROOT}/VERSION"
[ -f "$VERSION_FILE" ] || { echo "build-tunnel: missing ${VERSION_FILE}" >&2; exit 1; }
VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
[ -n "$VERSION" ] || { echo "build-tunnel: empty connector VERSION" >&2; exit 1; }

install -d "$(dirname "$OUT")"
# Resolve OUT to an absolute path BEFORE `cd $MOD_ROOT`, otherwise `go build -o $OUT`
# inside the subshell writes relative to connector/ (silent miss), then the chmod in
# the caller CWD fails with "No such file or directory". Three consecutive docker
# build-images runs failed on exactly this (0.2.493/498/500, 2026-11-23).
OUT_ABS="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"

echo "build-tunnel: compiling vacti-tunnel ${VERSION} for linux/${ARCH} -> ${OUT_ABS}" >&2
( cd "$MOD_ROOT" \
  && CGO_ENABLED=0 GOOS=linux GOARCH="$ARCH" go build -trimpath \
       -ldflags "-s -w -X main.version=${VERSION}" \
       -o "$OUT_ABS" ./cmd/tunnel )
chmod 0755 "$OUT_ABS"
echo "build-tunnel: OK ${OUT_ABS} (version ${VERSION})" >&2
