#!/usr/bin/env bash
# distro/test/ci-release-contract.sh - offline regression test for the W31 CI fixes:
#   A. ci/resolve-release.sh: release/engine-ref resolution + the 0.1.0 legacy guard.
#   B. ci/fetch-engine-debs.sh: fail-loud (HTTP error, SHA256 mismatch, wrong pinned
#      version, missing .deb) against a LOCAL file:// fake apt pool + a stub gh.
#   C. Workflow structure: HF publish is workflow_call (no workflow_run) and called
#      inline after publish; Docker lives in build-docker.yml (not build.yml) with a
#      blocking smoke BEFORE the promote step and only a candidate tag on the build
#      push; arm64 never creates images-v<ver> without the amd64 gate.
#   D. Pins: caido-mcp tag identical across manifest / env / golden extras / ISO hook;
#      Dockerfile installs vacti-engine=<pinned version>.
# No network, no docker. Needs python3 (+ PyYAML for C; LOUD SKIP of C without it)
# and dpkg-deb for B (LOUD SKIP of B without it).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0
pass() { echo "  ok: $*"; }
bad()  { echo "  FAIL: $*" >&2; fail=1; }

# --- A. resolve-release.sh ------------------------------------------------------
rr() { env -i PATH="$PATH" GITHUB_OUTPUT="${T}/rr.out" "$@" bash "${ROOT}/ci/resolve-release.sh" >/dev/null 2>"${T}/rr.err"; }
get() { grep -E "^$1=" "${T}/rr.out" | tail -1 | cut -d= -f2-; }

: > "${T}/rr.out"
if rr EVENT_NAME=workflow_dispatch IN_RELEASE=0.1.0; then bad "A: release=0.1.0 without override was NOT refused"
else pass "A: release=0.1.0 (placeholder) refused without override"; fi
: > "${T}/rr.out"
if rr EVENT_NAME=workflow_dispatch IN_RELEASE=0.2.399; then bad "A: pre-0.2.400 release was NOT refused"
else pass "A: pre-0.2.400 release refused"; fi
: > "${T}/rr.out"
if rr EVENT_NAME=workflow_dispatch IN_RELEASE=0.1.0 IN_ALLOW_LEGACY=true \
   && [[ "$(get legacy)" == true && "$(get publish_latest)" == false && -z "$(get engine_ref)" ]]; then
  pass "A: legacy override builds, never advances :latest, engine floating"
else bad "A: legacy override outputs wrong: $(tr '\n' ' ' < "${T}/rr.out")"; fi
: > "${T}/rr.out"
if rr EVENT_NAME=workflow_dispatch IN_RELEASE=0.2.471 \
   && [[ "$(get release)" == 0.2.471 && "$(get engine_ref)" == 0.2.471 && "$(get publish_latest)" == true ]]; then
  pass "A: release=0.2.471 pins engine_ref=0.2.471 (P1-2)"
else bad "A: release=0.2.471 outputs wrong: $(tr '\n' ' ' < "${T}/rr.out")"; fi
: > "${T}/rr.out"
if rr EVENT_NAME=workflow_dispatch IN_RELEASE=0.2.471 IN_ENGINE_REF=v0.2.470 && [[ "$(get engine_ref)" == 0.2.470 ]]; then
  pass "A: explicit engine_ref input wins (v stripped)"
else bad "A: explicit engine_ref not honored: $(tr '\n' ' ' < "${T}/rr.out")"; fi
: > "${T}/rr.out"
if rr EVENT_NAME=push REF_NAME=v0.2.471 && [[ "$(get release)" == 0.2.471 && "$(get engine_ref)" == 0.2.471 ]]; then
  pass "A: tag push v0.2.471 -> release 0.2.471 (no 0.1.0 default on push)"
else bad "A: tag push resolution wrong: $(tr '\n' ' ' < "${T}/rr.out")"; fi
: > "${T}/rr.out"
if rr EVENT_NAME=repository_dispatch PAYLOAD_RELEASE=0.2.472 && [[ "$(get release)" == 0.2.472 && "$(get engine_ref)" == 0.2.472 ]]; then
  pass "A: engine-deb-published payload -> release + engine_ref"
else bad "A: payload resolution wrong: $(tr '\n' ' ' < "${T}/rr.out")"; fi
: > "${T}/rr.out"
if rr EVENT_NAME=workflow_dispatch IN_RELEASE=0.2.1000 && [[ "$(get legacy)" == false ]]; then
  pass "A: version compare is numeric (0.2.1000 >= 0.2.400)"
else bad "A: 0.2.1000 treated as legacy"; fi
: > "${T}/rr.out"
# +git build metadata (on-box apt version e.g. 0.2.504+gitd1ad9af1) must normalize to X.Y.Z and NOT
# be treated as a legacy/non-semver release (the 0.2.504/0.2.505 +git dispatch regression).
if rr EVENT_NAME=repository_dispatch PAYLOAD_RELEASE=0.2.504+gitd1ad9af1 \
   && [[ "$(get release)" == 0.2.504 && "$(get engine_ref)" == 0.2.504 && "$(get legacy)" == false ]]; then
  pass "A: +git build-metadata suffix stripped to X.Y.Z (not legacy)"
else bad "A: +git suffix not normalized: $(tr '\n' ' ' < "${T}/rr.out")"; fi

# --- B. fetch-engine-debs.sh fail-loud ------------------------------------------
if command -v dpkg-deb >/dev/null 2>&1; then
  pool="${T}/pool"; mkdir -p "${pool}/apt/pool" "${T}/bin"
  mkdeb() { # name version arch
    local d="${T}/pkg-$1-$2-$3"; mkdir -p "${d}/DEBIAN"
    printf 'Package: %s\nVersion: %s\nArchitecture: %s\nMaintainer: t <t@t>\nDescription: t\n' "$1" "$2" "$3" > "${d}/DEBIAN/control"
    dpkg-deb --build "$d" "${pool}/apt/pool/$1_$2_$3.deb" >/dev/null 2>&1
  }
  stanza() { # name version arch [sha-override]
    local f="pool/$1_$2_$3.deb" s; s="${4:-$(sha256sum "${pool}/apt/${f}" | cut -d' ' -f1)}"
    printf 'Package: %s\nVersion: %s\nArchitecture: %s\nFilename: %s\nSHA256: %s\n\n' "$1" "$2" "$3" "$f" "$s"
  }
  mkdeb vacti-engine 0.2.471 amd64; mkdeb vacti-engine-chromium 1228 amd64
  printf '#!/bin/sh\nexit 1\n' > "${T}/bin/gh"; chmod +x "${T}/bin/gh"   # GitHub tier offline + failing
  fetch() { # outdir ref [extra env...]
    local o="$1" r="$2"; shift 2
    env -i PATH="${T}/bin:$PATH" HOME="$T" VACTI_APT_URL="file://${pool}" VACTI_APT_PRODUCER_TOKEN=x \
      VACTI_ENGINE_REF="$r" VACTI_CHROMIUM_PIN="${T}/no-pin.json" VACTI_CHROMIUM_HF_BASE="file://${T}/no-hf" "$@" \
      bash "${ROOT}/ci/fetch-engine-debs.sh" amd64 "$o" >"${T}/fetch.log" 2>&1
  }
  { stanza vacti-engine 0.2.471 amd64; stanza vacti-engine-chromium 1228 amd64; } > "${pool}/apt/Packages"
  if fetch "${T}/o1" 0.2.471 && ls "${T}/o1"/vacti-engine_0.2.471_amd64.deb >/dev/null 2>&1; then
    pass "B: pinned 0.2.471 + chromium staged, sha256 verified, exit 0"
  else bad "B: happy path failed: $(tail -3 "${T}/fetch.log")"; fi
  if fetch "${T}/o2" 0.2.47; then bad "B: pin 0.2.47 accepted (substring match picked 0.2.471?)"
  elif ls "${T}/o2"/vacti-engine_0.2.471_amd64.deb >/dev/null 2>&1; then bad "B: pin 0.2.47 staged 0.2.471"
  else pass "B: pin 0.2.47 does NOT match 0.2.471 -> exit non-zero"; fi
  { stanza vacti-engine 0.2.471 amd64 "$(printf '0%.0s' {1..64})"; stanza vacti-engine-chromium 1228 amd64; } > "${pool}/apt/Packages"
  if fetch "${T}/o3" 0.2.471; then bad "B: SHA256 mismatch accepted"
  elif grep -q "SHA256 mismatch" "${T}/fetch.log"; then pass "B: SHA256 mismatch -> exit non-zero"
  else bad "B: failed but not on SHA256: $(tail -3 "${T}/fetch.log")"; fi
  rm -f "${pool}/apt/Packages"
  if fetch "${T}/o4" 0.2.471; then bad "B: unreadable apt index (HTTP/file error) accepted"
  else pass "B: unreadable apt index -> exit non-zero"; fi
  if fetch "${T}/o5" 0.2.471 VACTI_FETCH_ALLOW_THIN=1; then
    bad "B: ALLOW_THIN masked a HARD error (index read failure must stay fatal)"
  else pass "B: ALLOW_THIN never masks a hard error"; fi
  { stanza vacti-engine 0.2.471 amd64; } > "${pool}/apt/Packages"
  if fetch "${T}/o6" 0.2.471; then bad "B: missing chromium accepted (silent THIN)"
  else pass "B: missing chromium -> exit non-zero (no silent THIN)"; fi
  if fetch "${T}/o7" 0.2.471 VACTI_FETCH_ALLOW_THIN=1; then pass "B: explicit VACTI_FETCH_ALLOW_THIN=1 keeps the THIN opt-in"
  else bad "B: ALLOW_THIN=1 with only a soft miss still failed: $(tail -3 "${T}/fetch.log")"; fi
else
  echo "  !!! SKIP B: dpkg-deb not available - fetch-engine-debs fail-loud NOT exercised !!!"
fi

# --- C. workflow structure ------------------------------------------------------
if python3 -c 'import yaml' 2>/dev/null; then
  python3 - "$ROOT" <<'PY' || fail=1
import sys, yaml, os
root = sys.argv[1]
W = lambda n: yaml.safe_load(open(os.path.join(root, ".github/workflows", n)))
on = lambda w: w.get("on", w.get(True)) or {}
errs = []
def ok(m): print("  ok: C: " + m)
hf = W("publish-images-hf.yml")
if "workflow_run" in on(hf): errs.append("publish-images-hf still has a workflow_run trigger")
if "workflow_call" not in on(hf) or "workflow_dispatch" not in on(hf): errs.append("publish-images-hf needs workflow_call + workflow_dispatch")
else: ok("publish-images-hf = workflow_call + workflow_dispatch, no workflow_run")
if "github.event.inputs" in open(os.path.join(root, ".github/workflows/publish-images-hf.yml")).read():
    errs.append("publish-images-hf reads github.event.inputs (the CALLER's event under workflow_call); use inputs.*")
for name, arch in (("build.yml", "amd64"), ("build-arm64.yml", "arm64")):
    w = W(name); jobs = w["jobs"]
    j = jobs.get("publish-hf") or {}
    needs = j.get("needs", [])
    if j.get("uses") != "./.github/workflows/publish-images-hf.yml" or "publish" not in needs or j.get("with", {}).get("arch") != arch:
        errs.append("%s: publish-hf must call publish-images-hf.yml after publish with arch=%s" % (name, arch))
    else: ok("%s calls publish-images-hf inline after publish (arch=%s)" % (name, arch))
    if any("docker" in k for k in jobs): errs.append("%s still carries a Docker job (P0-3)" % name)
    if "push" in on(w): errs.append("%s still has a push trigger" % name)
    if "rel" not in [s.get("id") for s in jobs["lint"]["steps"]]: errs.append("%s: lint must run ci/resolve-release.sh (id: rel)" % name)
    if "needs.lint.outputs.engine_ref" not in str(jobs["golden"].get("env", {})): errs.append("%s: golden must take VACTI_ENGINE_REF from needs.lint.outputs.engine_ref" % name)
ok("build.yml / build-arm64.yml carry no Docker job and pin the golden engine ref")
pub = W("build-arm64.yml")["jobs"]["publish"]["steps"]
ids = [s.get("id") for s in pub]; names = [s.get("name", "") for s in pub]
gi = ids.index("amd64gate") if "amd64gate" in ids else -1
ai = next((i for i, n in enumerate(names) if n.startswith("Append ARM64")), -1)
if gi < 0 or ai < 0 or gi > ai or "amd64gate.outputs.ok" not in str(pub[ai].get("if", "")):
    errs.append("build-arm64 publish: the append step must be gated on the amd64gate step (P1-3)")
else: ok("arm64 append gated on amd64gate (never creates images-v<ver> alone)")
d = W("build-docker.yml"); dj = d["jobs"]["docker-publish-ghcr"]
if dj.get("continue-on-error"): errs.append("docker job is continue-on-error")
steps = dj["steps"]; sn = [s.get("name", "") for s in steps]
if any(s.get("continue-on-error") for s in steps): errs.append("a docker step is continue-on-error (smoke must block)")
si = next((i for i, n in enumerate(sn) if n.startswith('Smoke test BOTH')), -1)
pi = next((i for i, n in enumerate(sn) if n.startswith('Promote')), -1)
bi = next((i for i, s in enumerate(steps) if s.get("id") == "build"), -1)
if not (0 <= bi < si < pi): errs.append("docker: order must be build(candidate) -> smoke -> promote")
else: ok("docker: build candidate -> blocking smoke (both arches) -> promote")
if "candidate" not in str(steps[bi].get("with", {}).get("tags", "")) or "latest" in str(steps[bi].get("with", {}).get("tags", "")):
    errs.append("docker: the build step must push only the candidate tag")
run = steps[si].get("run", "") if si >= 0 else ""
if "amd64 arm64" not in run: errs.append("docker smoke must test both amd64 and arm64")
if "publish_latest" not in str(steps[pi].get("env", {})) if pi >= 0 else True: errs.append("docker promote must gate :latest on publish_latest")
wa = open(os.path.join(root, ".github/workflows/watch-engine-apt.yml")).read()
if "build-docker.yml" not in wa: errs.append("watch-engine-apt must dispatch build-docker.yml")
for e in errs: sys.stderr.write("  FAIL: C: " + e + "\n")
sys.exit(1 if errs else 0)
PY
else
  echo "  !!! SKIP C: PyYAML not available - workflow structure NOT checked !!!"
fi

# --- D. pins ----------------------------------------------------------------------
m="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pins"]["caido_mcp"])' "${ROOT}/distro/packages/arsenal-manifest.json")"
e="$(sed -n 's/^VACTI_CAIDO_MCP_TAG="${VACTI_CAIDO_MCP_TAG:-\(v[0-9.]*\)}".*/\1/p' "${ROOT}/distro/vacti-appliance.env")"
x="$(sed -n 's/^CAIDO_MCP_TAG="${VACTI_CAIDO_MCP_TAG:-\(v[0-9.]*\)}".*/\1/p' "${ROOT}/distro/golden-image/install-engine-extras.sh")"
h="$(sed -n 's/^CAIDO_MCP_TAG="\(v[0-9.]*\)".*/\1/p' "${ROOT}/distro/live-build-config/config/hooks/normal/0320-engine-extras.hook.chroot")"
if [[ -n "$m" && "$m" == "$e" && "$m" == "$x" && "$m" == "$h" ]]; then pass "D: caido-mcp pin ${m} identical in manifest/env/extras/ISO hook"
else bad "D: caido-mcp pin drift manifest=${m} env=${e} extras=${x} hook=${h}"; fi
for f in "${ROOT}/distro/golden-image/install-engine-extras.sh" "${ROOT}/distro/live-build-config/config/hooks/normal/0320-engine-extras.hook.chroot"; do
  grep -q 'cmd/caido-mcp-server' "$f" && grep -q 'GOTOOLCHAIN=auto' "$f" \
    && pass "D: $(basename "$f") builds the v2+ cmd/ layout with GOTOOLCHAIN=auto" \
    || bad "D: $(basename "$f") cannot build caido-mcp-server v2+ (cmd/ layout, go>=1.25)"
done
grep -q '"${VACTI_ENGINE_PKG}=${ENGINE_VER}"' "${ROOT}/distro/Dockerfile" \
  && pass "D: Dockerfile installs vacti-engine=<pinned version>" || bad "D: Dockerfile does not pin vacti-engine to VACTI_ENGINE_REF"

[[ "$fail" -eq 0 ]] && echo "  ci-release-contract: PASS" || { echo "  ci-release-contract: FAIL" >&2; exit 1; }
