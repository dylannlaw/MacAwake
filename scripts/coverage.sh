#!/bin/bash
# Runs the unit tests and fails if line coverage of the app logic is under MIN_COVERAGE (default 95).
# The SwiftUI views in MacAwakeApp.swift are left out: they are checked by looking at the --demo snapshots
# (see AGENTS.md), not by unit tests. Needs Xcode (XCTest isn't in the Command Line Tools).
set -euo pipefail
cd "$(dirname "$0")/.."
MIN="${MIN_COVERAGE:-95}"
if [[ -d /Applications/Xcode.app && -z "${DEVELOPER_DIR:-}" ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

swift test --enable-code-coverage
json="$(swift test --show-codecov-path)"
python3 - "$json" "$MIN" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))["data"][0]["files"]
need = float(sys.argv[2])
covered = total = 0
for f in sorted(data, key=lambda f: f["filename"]):
    name = f["filename"]
    if "/Sources/MacAwake/" not in name or name.endswith("MacAwakeApp.swift"):
        continue
    s = f["summary"]["lines"]
    covered += s["covered"]; total += s["count"]
    print(f"{s['percent']:6.1f}%  {s['covered']:4}/{s['count']:<4}  {name.split('/Sources/MacAwake/')[1]}")
pct = 100 * covered / total
print(f"\nCoverage of app logic: {pct:.1f}% ({covered}/{total} lines), minimum {need:.0f}%")
sys.exit(0 if pct >= need else 1)
PY
