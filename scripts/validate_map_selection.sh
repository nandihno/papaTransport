#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Compile production selection and array helpers unchanged, omitting only the
# adjacent SwiftUI controls so these checks need no app/theme/UI test host.
python3 - "$REPO_ROOT" "$WORK" <<'PY'
import pathlib, sys
repo, work = map(pathlib.Path, sys.argv[1:])
source = (repo / "PapaTransport/Views/Common/MapRouteSelection.swift").read_text()
before_ui, after_ui = source.split("struct MapRouteSelectionControls: View {", 1)
_, helpers = after_ui.split("extension Array where Element == NearbyBusStop {", 1)
(work / "MapRouteSelection.swift").write_text(
    before_ui + "extension Array where Element == NearbyBusStop {" + helpers
)
vehicles = (repo / "PapaTransport/Services/QLDVehiclePositionService.swift").read_text()
model, _ = vehicles.split("/// Live vehicle positions for South East Queensland.", 1)
(work / "LiveVehicle.swift").write_text(model)
PY

xcrun swiftc -module-cache-path "$WORK/module-cache" -parse-as-library \
    -swift-version 6 -default-isolation MainActor \
    "$REPO_ROOT/PapaTransport/Models/BusModels.swift" \
    "$WORK/LiveVehicle.swift" \
    "$WORK/MapRouteSelection.swift" \
    "$REPO_ROOT/PapaTransport/Views/Common/MapSheetPresentation.swift" \
    "$REPO_ROOT/PapaTransport/Views/Common/DepartureGrouping.swift" \
    "$REPO_ROOT/scripts/validate_map_selection.swift" -o "$WORK/checks"
"$WORK/checks"
