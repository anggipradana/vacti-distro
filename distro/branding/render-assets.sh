#!/usr/bin/env bash
# render-assets.sh - regenerate every raster branding asset from its committed
# SVG source. The SVG sources are self-contained (the wordmark is baked to vector
# paths), so this needs only an SVG rasteriser and no fonts. It is reproducible
# and idempotent: re-running it reproduces the committed PNGs bit-for-similar.
#
# Rasteriser auto-detected, in order: rsvg-convert, then inkscape, then cairosvg
# (python module). Install any one of them if none is present, for example:
#   apt-get install librsvg2-bin        # provides rsvg-convert
#   apt-get install inkscape
#   pipx run cairosvg ...               # or a venv with cairosvg
#
# This is a developer/CI helper, not part of the image build: the build drivers
# copy the already-rendered PNGs. Run it after editing an SVG source.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAL="$(cd "${HERE}/../live-build-config/calamares/branding/vacti" 2>/dev/null && pwd || true)"

RASTER=""
if command -v rsvg-convert >/dev/null 2>&1; then RASTER=rsvg
elif command -v inkscape >/dev/null 2>&1;    then RASTER=inkscape
elif python3 -c 'import cairosvg' >/dev/null 2>&1; then RASTER=cairosvg
else
  echo "[render] no SVG rasteriser found (need rsvg-convert, inkscape, or python3 cairosvg)" >&2
  exit 1
fi
echo "[render] using: ${RASTER}"

# render <src.svg> <dst.png> <width> <height>   (0 = let the rasteriser decide)
render() {
  local src="$1" dst="$2" w="$3" h="$4"
  [[ -f "$src" ]] || { echo "[render][skip] missing source: $src" >&2; return 0; }
  mkdir -p "$(dirname "$dst")"
  case "$RASTER" in
    rsvg)
      local args=()
      [[ "$w" != 0 ]] && args+=(-w "$w")
      [[ "$h" != 0 ]] && args+=(-h "$h")
      rsvg-convert "${args[@]}" -o "$dst" "$src" ;;
    inkscape)
      local args=(--export-type=png "--export-filename=$dst")
      [[ "$w" != 0 ]] && args+=("--export-width=$w")
      [[ "$h" != 0 ]] && args+=("--export-height=$h")
      inkscape "$src" "${args[@]}" >/dev/null 2>&1 ;;
    cairosvg)
      python3 - "$src" "$dst" "$w" "$h" <<'PY'
import sys, cairosvg
src, dst, w, h = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
kw = {}
if w: kw["output_width"] = w
if h: kw["output_height"] = h
cairosvg.svg2png(url=src, write_to=dst, **kw)
PY
      ;;
  esac
  echo "[render] ${dst}"
}

L="${HERE}/logo"
# logomark (height-driven, square-ish)
for px in 512 256 128 64; do render "${L}/svg/vacti-logomark.svg" "${L}/png/vacti-logomark-${px}.png" 0 "$px"; done
# square icon
for px in 256 128 64 48 32 16; do render "${L}/svg/vacti-icon.svg" "${L}/png/vacti-icon-${px}.png" "$px" "$px"; done
# lockups
render "${L}/svg/vacti-lockup-horizontal-light.svg" "${L}/png/vacti-lockup-horizontal-light.png" 0 200
render "${L}/svg/vacti-lockup-stacked-light.svg"    "${L}/png/vacti-lockup-stacked-light.png"    0 520

# wallpapers
render "${HERE}/wallpaper/vacti-wallpaper-1920x1080.svg" "${HERE}/wallpaper/vacti-wallpaper-1920x1080.png" 1920 1080
render "${HERE}/wallpaper/vacti-wallpaper-2560x1440.svg" "${HERE}/wallpaper/vacti-wallpaper-2560x1440.png" 2560 1440

# greeter
render "${HERE}/greeter/vacti-greeter-1920x1080.svg" "${HERE}/greeter/vacti-greeter-1920x1080.png" 1920 1080

# grub (splash + theme background are the same art)
render "${HERE}/grub/vacti-grub-1920x1080.svg" "${HERE}/grub/splash.png"          1920 1080
render "${HERE}/grub/vacti-grub-1920x1080.svg" "${HERE}/grub/theme/background.png" 1920 1080

# plymouth
render "${HERE}/plymouth/vacti/vacti-plymouth-bg-1920x1080.svg" "${HERE}/plymouth/vacti/background.png"   1920 1080
render "${HERE}/plymouth/vacti/vacti-plymouth-logo.svg"         "${HERE}/plymouth/vacti/logo.png"         0 460
render "${HERE}/plymouth/vacti/vacti-progress-box.svg"          "${HERE}/plymouth/vacti/progress_box.png" 600 8
render "${HERE}/plymouth/vacti/vacti-progress-bar.svg"          "${HERE}/plymouth/vacti/progress_bar.png" 600 8

# calamares (GUI installer branding)
if [[ -n "${CAL}" ]]; then
  render "${L}/svg/vacti-icon.svg"      "${CAL}/logo.png"    160 160
  render "${CAL}/welcome.svg"           "${CAL}/welcome.png" 900 420
fi

echo "[render] done"
