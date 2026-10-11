#!/usr/bin/env bash
# fanout.sh - the deterministic conversion fan-out. Given the one golden qcow2,
# repackage it into every requested VM/cloud form by delegating to the per-form
# convert-*.sh scripts. Every form is a repackaging of the SAME rootfs, so they
# are provably the same engine. Also emits the NoCloud seed TEMPLATE note (no
# token baked). HEAVY-ish - runs in CI, not on prod.
#
# Usage: fanout.sh [cloud] [vmware-ova] [vbox-ova] [all]   (default: all)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISTRO_DIR="$(cd "${HERE}/.." && pwd)"
# shellcheck source=/dev/null
source "${DISTRO_DIR}/vacti-appliance.env"
OUT="${OUT_DIR:-${DISTRO_DIR}/out}"
GOLDEN="${GOLDEN:-${OUT}/vacti-engine-${VACTI_RELEASE}-golden.qcow2}"
[[ -f "$GOLDEN" ]] || { echo "[fanout] golden disk not found: $GOLDEN (run build-golden.sh first)" >&2; exit 1; }

forms=("$@"); [[ ${#forms[@]} -eq 0 ]] && forms=(all)

run_cloud() { "${HERE}/convert-cloud.sh"; }
run_vmware(){ "${HERE}/convert-vmware-ova.sh"; }
run_vbox()  { "${HERE}/convert-vbox-ova.sh"; }

for f in "${forms[@]}"; do
  case "$f" in
    cloud)       run_cloud ;;
    vmware-ova)  run_vmware ;;
    vbox-ova)    run_vbox ;;
    all)         run_cloud; run_vmware; run_vbox ;;
    *) echo "[fanout] unknown form: $f (cloud|vmware-ova|vbox-ova|all)" >&2; exit 2 ;;
  esac
done

echo "[fanout] NoCloud seed ships as a TEMPLATE only (no token baked):"
echo "         ${DISTRO_DIR}/enroll/nocloud/make-seed.sh --token <TOK> --url <CP>"
echo "[fanout] reproducibility manifest:"
( cd "$OUT" && sha256sum ./*.qcow2 ./*.raw.gz ./*.ova 2>/dev/null > "vacti-engine-${VACTI_RELEASE}-manifest.sha256" || true )
echo "[fanout] done; artifacts in ${OUT}"
