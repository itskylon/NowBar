#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/toolchain.sh"
cd "$METER_ROOT"
mkdir -p "$METER_BUILD/panel-interaction"
python3 - "$METER_BUILD/panel-interaction/main.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Sources/AgentMeter/main.swift').read_text()
prefix, separator, _ = source.partition('if CommandLine.arguments.contains("--diagnose") {')
if not separator:
    raise SystemExit('App entry point was not found')
Path(sys.argv[1]).write_text(prefix + Path('Tests/PanelInteractionAcceptance.swift').read_text())
PY
meter_sources=()
for meter_source in Sources/AgentMeter/*.swift; do
  if [[ "$meter_source" != Sources/AgentMeter/main.swift ]]; then meter_sources+=("$meter_source"); fi
done
swiftc "${METER_FLAGS[@]}" -I "$METER_BUILD" -L "$METER_BUILD" -lAgentMeterCore \
  "${meter_sources[@]}" "$METER_BUILD/panel-interaction/main.swift" -o "$METER_BUILD/PanelInteractionAcceptance"
"$METER_BUILD/PanelInteractionAcceptance" --demo
