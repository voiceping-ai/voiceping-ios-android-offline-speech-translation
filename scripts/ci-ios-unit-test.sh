#!/usr/bin/env bash

# CI smoke test for iOS: run a minimal XCTest suite on the latest available iOS simulator.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PROJECT_FILE="$PROJECT_DIR/VoicePingIOSAndroidOfflineSpeechTranslation.xcodeproj"
SCHEME="OfflineTranscription"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$PROJECT_DIR/build/DerivedData}"
TEST_FILTER="${IOS_TEST_FILTER:-OfflineTranscriptionTests/SessionStateTests}"

resolve_simulator_udid() {
  python3 - <<'PY'
import json
import subprocess
import sys

def runtime_version(runtime: str):
    marker = "SimRuntime.iOS-"
    if marker not in runtime:
        return (-1,)
    suffix = runtime.split(marker, 1)[1]
    try:
        return tuple(int(p) for p in suffix.split("-"))
    except ValueError:
        return (-1,)

raw = subprocess.check_output(
    ["xcrun", "simctl", "list", "devices", "available", "-j"],
    text=True,
)
devices = json.loads(raw).get("devices", {})
for runtime in sorted(devices.keys(), key=runtime_version, reverse=True):
    if "SimRuntime.iOS-" not in runtime:
        continue

    candidates = [
        d for d in devices[runtime]
        if d.get("isAvailable") and d.get("name", "").startswith("iPhone")
    ]
    if not candidates:
        continue

    # Prefer newer default devices when present.
    candidates.sort(key=lambda d: (0 if "iPhone 16" in d["name"] else 1, d["name"]))
    print(candidates[0]["udid"])
    sys.exit(0)

sys.exit(1)
PY
}

if [ -n "${IOS_DESTINATION:-}" ]; then
  DESTINATION="$IOS_DESTINATION"
else
  SIMULATOR_ID="$(resolve_simulator_udid)"
  DESTINATION="platform=iOS Simulator,id=$SIMULATOR_ID"
fi

set -o pipefail
xcodebuild test \
  -project "$PROJECT_FILE" \
  -scheme "$SCHEME" \
  -destination "$DESTINATION" \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:"$TEST_FILTER"
