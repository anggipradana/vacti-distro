# shellcheck shell=bash
# manifest-lib.sh - read the engine arsenal manifest (packaging/arsenal-manifest.json)
# and emit the apt package set for a flavour. SOURCED by gen-live-build-list.sh.
#
# The manifest is the single source of truth shipped by the engine (inside the
# vacti-engine .deb at /usr/lib/vacti-engine/packaging/arsenal-manifest.json, and
# vendored next to this file as arsenal-manifest.json for host-side and offline
# generation). This library NEVER hand-maintains a package list: it derives every
# arsenal flavour from the manifest.
#
# Flavours (selector):
#   full  - the whole apt core superset (.apt.core)           == VACTI_FULL_ARSENAL=1
#   lean  - the core MINUS the per-vertical sets              == baked default
#           (.apt.core - union(.apt.verticals.*))
#   ctf   - the CTF apt set (.apt.ctf)                        == VACTI_CTF_ARSENAL=1
#
# JSON is parsed with jq when present (the build guest + the ISO container have
# it), else python3 (host / CI / dev-box). One of the two is required.

# emit one package per line for the requested flavour.
#   manifest_pkgs <manifest.json> <full|lean|ctf>
manifest_pkgs() {
  _ml_manifest="$1"
  _ml_sel="$2"
  if [ ! -f "$_ml_manifest" ]; then
    echo "[manifest-lib] manifest not found: ${_ml_manifest}" >&2
    return 1
  fi
  if command -v jq >/dev/null 2>&1; then
    case "$_ml_sel" in
      full) jq -r '.apt.core[]' "$_ml_manifest" ;;
      lean) jq -r '(.apt.core - ([.apt.verticals[]] | add)) | .[]' "$_ml_manifest" ;;
      ctf)  jq -r '.apt.ctf[]' "$_ml_manifest" ;;
      *) echo "[manifest-lib] unknown selector: ${_ml_sel}" >&2; return 2 ;;
    esac
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$_ml_manifest" "$_ml_sel" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
sel = sys.argv[2]
apt = m["apt"]
core = list(apt.get("core", []))
ctf = list(apt.get("ctf", []))
vu = {x for arr in apt.get("verticals", {}).values() for x in arr}
if sel == "full":
    out = core
elif sel == "lean":
    out = [p for p in core if p not in vu]
elif sel == "ctf":
    out = ctf
else:
    sys.stderr.write("[manifest-lib] unknown selector: %s\n" % sel)
    sys.exit(2)
sys.stdout.write("\n".join(out) + ("\n" if out else ""))
PY
  else
    echo "[manifest-lib] neither jq nor python3 available to parse ${_ml_manifest}" >&2
    return 3
  fi
}
