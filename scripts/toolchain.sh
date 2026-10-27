#!/usr/bin/env bash
# Sourced by build/test. Uses a per-invocation workaround for duplicate CLT module maps.
set -euo pipefail
METER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
METER_BUILD="$METER_ROOT/.build/manual"
mkdir -p "$METER_BUILD" "$METER_BUILD/module-cache"
METER_SDK="$(xcrun --show-sdk-path)"
METER_FLAGS=(-swift-version 5 -sdk "$METER_SDK" -target "$(uname -m)-apple-macosx14.0" -module-cache-path "$METER_BUILD/module-cache")
if [ -f /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap ] && [ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.2.sdk ]; then
  METER_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.2.sdk
  touch "$METER_BUILD/empty.modulemap"
  cat > "$METER_BUILD/overlay.json" <<EOF
{"version":0,"roots":[{"type":"file","name":"/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap","external-contents":"$METER_BUILD/empty.modulemap"}]}
EOF
  METER_FLAGS=(-swift-version 5 -sdk "$METER_SDK" -target "$(uname -m)-apple-macosx14.0" -module-cache-path "$METER_BUILD/module-cache" -vfsoverlay "$METER_BUILD/overlay.json")
fi
