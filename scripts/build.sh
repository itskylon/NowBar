#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/toolchain.sh"
cd "$METER_ROOT"
METER_APP="$METER_ROOT/dist/NowBar.app"
mkdir -p "$METER_APP/Contents/MacOS" "$METER_APP/Contents/Resources"
swiftc "${METER_FLAGS[@]}" -O -parse-as-library -emit-library -static -emit-module -module-name AgentMeterCore \
  Sources/AgentMeterCore/*.swift -emit-module-path "$METER_BUILD/AgentMeterCore.swiftmodule" -o "$METER_BUILD/libAgentMeterCore.a"
swiftc "${METER_FLAGS[@]}" -O -I "$METER_BUILD" -L "$METER_BUILD" -lAgentMeterCore \
  Sources/AgentMeter/*.swift -o "$METER_APP/Contents/MacOS/AgentMeter"
cp resources/claude_bridge.py "$METER_APP/Contents/Resources/claude_bridge.py"
mkdir -p "$METER_APP/Contents/Resources/providers"
cp resources/providers/*.svg "$METER_APP/Contents/Resources/providers/"
mkdir -p "$METER_APP/Contents/Resources/interface"
cp resources/interface/*.svg "$METER_APP/Contents/Resources/interface/"
cp resources/Info.plist "$METER_APP/Contents/Info.plist"
for meter_localization in resources/*.lproj; do
  cp -R "$meter_localization" "$METER_APP/Contents/Resources/"
done
bash scripts/build-icon.sh
cp "$METER_BUILD/AppIcon.icns" "$METER_APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$METER_APP"
printf 'Built %s\n' "$METER_APP"
