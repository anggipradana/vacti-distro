#!/usr/bin/env bash
# convert-cloud.sh - repackage the golden qcow2 into the CLOUD form:
# a compact qcow2 (kept as-is) + a gzip'd raw for providers that want raw.
# HEAVY-ish (disk IO) - runs in CI, not on prod.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$(cd "${HERE}/.." && pwd)/vacti-appliance.env"
OUT="${OUT_DIR:-$(cd "${HERE}/.." && pwd)/out}"
GOLDEN="${GOLDEN:-${OUT}/vacti-engine-${VACTI_RELEASE}-golden.qcow2}"
[[ -f "$GOLDEN" ]] || { echo "golden disk not found: $GOLDEN (run build-golden.sh)" >&2; exit 1; }

BASE="${OUT}/vacti-engine-${VACTI_RELEASE}"
echo "[cloud] qcow2 (cloud) = ${BASE}-cloud.qcow2"
qemu-img convert -p -O qcow2 -c "$GOLDEN" "${BASE}-cloud.qcow2"
echo "[cloud] raw.gz"
qemu-img convert -p -O raw "$GOLDEN" "${BASE}.raw"
gzip -f -9 "${BASE}.raw"
( cd "$OUT" && sha256sum "vacti-engine-${VACTI_RELEASE}-cloud.qcow2" "vacti-engine-${VACTI_RELEASE}.raw.gz" \
  > "vacti-engine-${VACTI_RELEASE}-cloud.sha256" )
echo "[cloud] done"
