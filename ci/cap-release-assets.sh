#!/usr/bin/env bash
# cap-release-assets.sh - enforce the GitHub Release per-asset size cap WITHOUT
# failing the build.
#
# GitHub Releases reject a single asset larger than 2 GiB. A full-arsenal image
# (qcow2 / raw.gz / ova / iso) can exceed that, and arm64 doubles the number of
# such assets. Rather than let the publish step hard-fail (softprops/action-gh-
# release aborts the whole release on an over-limit upload), this script moves any
# over-cap artifact OUT of the release staging dir into <dir>/over-cap/ and logs a
# warning, so the release still publishes every in-limit asset. The over-cap files
# remain available for the full-fidelity path (gh run download of the workflow
# artifacts, and the operator-gated R2 mirror) and stay listed in MANIFEST.sha256.
#
# This solves NEITHER the cap itself NOR the R2 wiring (both are separate,
# operator-gated work): it only keeps the pipeline green when an asset is too big.
#
# Usage: cap-release-assets.sh <release-dir> [max-bytes]
#   max-bytes defaults to 2147483648 (2 GiB, the GitHub Release per-asset limit).
set -euo pipefail

DIR="${1:?usage: cap-release-assets.sh <release-dir> [max-bytes]}"
MAX_BYTES="${2:-2147483648}"

[ -d "$DIR" ] || { echo "[cap] release dir not found: $DIR" >&2; exit 2; }

OVER_DIR="${DIR}/over-cap"
skipped=0

# Only the publishable asset types; never touch MANIFEST / sha256 sidecars.
while IFS= read -r f; do
  [ -f "$f" ] || continue
  size="$(stat -c%s "$f" 2>/dev/null || echo 0)"
  if [ "$size" -gt "$MAX_BYTES" ]; then
    mkdir -p "$OVER_DIR"
    echo "[cap][WARN] $(basename "$f") is ${size} bytes (> ${MAX_BYTES} GitHub Release cap); moving to over-cap/ and continuing. Retrieve it via 'gh run download' or the R2 mirror." >&2
    mv -f "$f" "$OVER_DIR/"
    skipped=$((skipped + 1))
  fi
done < <(find "$DIR" -maxdepth 1 -type f \( -name '*.qcow2' -o -name '*.raw.gz' -o -name '*.ova' -o -name '*.iso' \) | sort)

if [ "$skipped" -gt 0 ]; then
  echo "[cap] ${skipped} asset(s) exceeded the ${MAX_BYTES}-byte cap and were held back from the Release (pipeline continues)."
else
  echo "[cap] no asset exceeded the ${MAX_BYTES}-byte cap; all stay in the Release."
fi
exit 0
