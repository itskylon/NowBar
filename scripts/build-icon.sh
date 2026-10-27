#!/usr/bin/env bash
set -euo pipefail
meter_root="$(cd "$(dirname "$0")/.." && pwd)"
meter_iconset="$meter_root/.build/manual/NowBar.iconset"
mkdir -p "$meter_iconset"
for meter_size in 16 32 128 256 512; do
  sips -z "$meter_size" "$meter_size" "$meter_root/resources/branding/nowbar.png" \
    --out "$meter_iconset/icon_${meter_size}x${meter_size}.png" >/dev/null
  meter_retina=$((meter_size * 2))
  sips -z "$meter_retina" "$meter_retina" "$meter_root/resources/branding/nowbar.png" \
    --out "$meter_iconset/icon_${meter_size}x${meter_size}@2x.png" >/dev/null
done
iconutil -c icns "$meter_iconset" -o "$meter_root/.build/manual/AppIcon.icns"
