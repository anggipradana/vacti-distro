#!/usr/bin/env bash
#
# test-readme-render.sh
#
# Unit test for the README-render block of scripts/publish-images-to-hf.sh.
#
# It extracts the anchored "readme-render-begin .. readme-render-end" block
# verbatim from the real script and runs ONLY that block against synthetic HF
# tree inputs, with curl / huggingface-cli stubbed. This exercises the actual
# shipping code (no re-implementation), covering the arch-completeness rule:
#   (a) latest version amd64-only (older version complete) -> headline stays on
#       the complete version + "Building: v<partial> (arm64 pending)".
#   (b) latest version has BOTH arches                     -> plain "Latest release".
#   (c) tree unavailable / both OVAs missing               -> legacy fallback.
#   (d) VACTI_HF_README_ARCH_COMPLETE=0                    -> legacy behaviour.
# Plus an idempotency check (same input -> identical README).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/../publish-images-to-hf.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: cannot find ${SCRIPT}" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SNIPPET="${WORK}/render-block.sh"
sed -n '/readme-render-begin/,/readme-render-end/p' "$SCRIPT" > "$SNIPPET"
[ -s "$SNIPPET" ] || { echo "FAIL: could not extract render block (anchors missing)" >&2; exit 1; }

PASS=0
FAIL=0
ok()  { echo "  ok: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1" >&2; FAIL=$((FAIL+1)); }

# Build a tree.json fixture from newline-separated "path" entries given on stdin.
make_tree() {
  local out="$1"
  {
    printf '['
    local first=1 p
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      if [ "$first" = 1 ]; then first=0; else printf ','; fi
      printf '{"type":"file","path":"%s"}' "$p"
    done
    printf ']'
  } > "$out"
}

# render <tag> <version> <tree_file|-> <flag|->
# Runs the extracted render block in an isolated subshell, echoes the README.
# Passing "-" for tree_file simulates an unavailable tree (curl stubbed to fail).
render() {
  local tag="$1" ver="$2" treef="$3" flag="${4:--}"
  local stage="${WORK}/stage-${tag}"
  rm -rf "$stage"; mkdir -p "$stage/renamed"
  # Local fallback files, used only when the remote tree is unavailable.
  : > "$stage/renamed/vacti-distro-9.9.9-amd64-gui.vmware.ova"
  : > "$stage/renamed/SHA256SUMS"
  (
    set -euo pipefail
    STAGE="$stage"
    RENAMED="$stage/renamed"
    RESOLVE_BASE="https://example/resolve/main"
    API_BASE="https://example/api"
    VERSION="$ver"
    if [ "$treef" != "-" ]; then VACTI_HF_TREE_FILE="$treef"; else VACTI_HF_TREE_FILE=""; fi
    if [ "$flag" != "-" ]; then VACTI_HF_README_ARCH_COMPLETE="$flag"; fi
    # Stub network + upload tools so only the pure render logic runs.
    curl() { return 1; }
    huggingface-cli() { return 0; }
    # shellcheck disable=SC1090
    source "$SNIPPET"
    cat "$README"
  )
}

contains()     { grep -qF -- "$2" <<<"$1"; }
not_contains() { ! grep -qF -- "$2" <<<"$1"; }

# --- (a) latest amd64-only, previous version complete ------------------------
make_tree "${WORK}/tree-a.json" <<'EOF'
v0.2.422/vacti-distro-0.2.422-amd64-gui.vmware.ova
v0.2.422/vacti-distro-0.2.422-amd64-gui.vbox.ova
v0.2.422/vacti-distro-0.2.422-arm64-gui.vmware.ova
v0.2.422/vacti-distro-0.2.422-arm64-gui.vbox.ova
v0.2.422/SHA256SUMS
v0.2.423/vacti-distro-0.2.423-amd64-gui.vmware.ova
v0.2.423/vacti-distro-0.2.423-amd64-gui.vbox.ova
v0.2.423/SHA256SUMS
EOF
out="$(render a 0.2.423 "${WORK}/tree-a.json")"
echo "[case a] amd64-only latest, older complete"
contains "$out" "## Latest complete release: v0.2.422" && ok "headline = complete v0.2.422" || bad "wrong headline: $out"
contains "$out" "Building: v0.2.423 (arm64 pending)"   && ok "building note present"         || bad "missing building note"
contains "$out" "/v0.2.422/vacti-distro-0.2.422-arm64-gui.vmware.ova" && ok "table lists arm64 of complete ver" || bad "table missing arm64"
not_contains "$out" "v0.2.423/vacti-distro-0.2.423-amd64" && ok "partial ver not in table" || bad "partial files leaked into table"

# --- (b) latest has both arches ----------------------------------------------
make_tree "${WORK}/tree-b.json" <<'EOF'
v0.2.422/vacti-distro-0.2.422-amd64-gui.vmware.ova
v0.2.422/vacti-distro-0.2.422-arm64-gui.vmware.ova
v0.2.423/vacti-distro-0.2.423-amd64-gui.vmware.ova
v0.2.423/vacti-distro-0.2.423-amd64-gui.vbox.ova
v0.2.423/vacti-distro-0.2.423-arm64-gui.vmware.ova
v0.2.423/vacti-distro-0.2.423-arm64-gui.vbox.ova
v0.2.423/SHA256SUMS
EOF
out="$(render b 0.2.423 "${WORK}/tree-b.json")"
echo "[case b] latest both arches"
contains "$out" "## Latest release: v0.2.423" && ok "plain latest headline" || bad "wrong headline: $out"
not_contains "$out" "Building:" && ok "no building note"                    || bad "unexpected building note"
contains "$out" "/v0.2.423/vacti-distro-0.2.423-arm64-gui.vbox.ova" && ok "arm64 listed" || bad "arm64 missing"

# --- (c) tree unavailable / both OVAs missing -> legacy fallback -------------
out="$(render c 9.9.9 -)"
echo "[case c] tree unavailable, both arches missing"
contains "$out" "## Latest release: v9.9.9" && ok "legacy headline on fallback" || bad "wrong fallback headline: $out"
not_contains "$out" "Building:" && ok "no building note on fallback"           || bad "unexpected building note"
contains "$out" "vacti-distro-9.9.9-amd64-gui.vmware.ova" && ok "local files used" || bad "local fallback files missing"

# --- (d) flag OFF -> legacy headline = published version ----------------------
out="$(render d 0.2.423 "${WORK}/tree-a.json" 0)"
echo "[case d] flag disabled (legacy)"
contains "$out" "## Latest release: v0.2.423" && ok "legacy headline = published ver" || bad "flag-off wrong headline: $out"
not_contains "$out" "Latest complete release" && ok "no complete-release wording"     || bad "complete wording leaked with flag off"
not_contains "$out" "Building:" && ok "no building note with flag off"                || bad "building note with flag off"

# --- (e) idempotency: same input twice -> identical output -------------------
o1="$(render e 0.2.423 "${WORK}/tree-a.json")"
o2="$(render e 0.2.423 "${WORK}/tree-a.json")"
echo "[case e] idempotency"
[ "$o1" = "$o2" ] && ok "two runs identical" || bad "non-idempotent render"

echo
echo "PASS=${PASS} FAIL=${FAIL}"
[ "$FAIL" -eq 0 ]
