#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/toolchain.sh"
cd "$METER_ROOT"
python3 -m unittest discover -s Tests -p 'test_*.py' -v
for meter_check in Tests/*Smoke.swift; do
  meter_name="$(basename "$meter_check" .swift)"
  swiftc "${METER_FLAGS[@]}" -parse-as-library Sources/AgentMeterCore/*.swift "$meter_check" -o "$METER_BUILD/$meter_name"
  "$METER_BUILD/$meter_name"
done
swiftc "${METER_FLAGS[@]}" -parse-as-library -emit-library -static -emit-module -module-name AgentMeterCore \
  Sources/AgentMeterCore/*.swift -emit-module-path "$METER_BUILD/AgentMeterCore.swiftmodule" -o "$METER_BUILD/libAgentMeterCore.a"
swiftc "${METER_FLAGS[@]}" -parse-as-library -I "$METER_BUILD" -L "$METER_BUILD" -lAgentMeterCore \
  Sources/AgentMeter/Store.swift Sources/AgentMeter/SystemServices.swift Tests/StoreAcceptance.swift -o "$METER_BUILD/StoreAcceptance"
"$METER_BUILD/StoreAcceptance"
swiftc "${METER_FLAGS[@]}" -parse-as-library -I "$METER_BUILD" -L "$METER_BUILD" -lAgentMeterCore \
  Sources/AgentMeter/UsageHistoryStore.swift Tests/HistoryWindowAcceptance.swift -o "$METER_BUILD/HistoryWindowAcceptance"
"$METER_BUILD/HistoryWindowAcceptance"
swiftc "${METER_FLAGS[@]}" -parse-as-library -I "$METER_BUILD" -L "$METER_BUILD" -lAgentMeterCore \
  Sources/AgentMeter/Store.swift Sources/AgentMeter/SystemServices.swift Sources/AgentMeter/UsageHistoryStore.swift \
  Tests/LanguageAcceptance.swift -o "$METER_BUILD/LanguageAcceptance"
"$METER_BUILD/LanguageAcceptance"
