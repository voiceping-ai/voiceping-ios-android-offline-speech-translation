#!/bin/zsh
# iOS UI Flow Tests Runner
# Runs all 10 user flow tests, collects screenshots, generates report.
# Usage: IOS_DEVICE_ID=<udid> ./scripts/ios-ui-flow-tests.sh [test_name ...]
# Requires IOS_DEVICE_ID environment variable (real device UDID).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
IOS_DEVICE_ID="${IOS_DEVICE_ID:-}"
EVIDENCE_DIR="${EVIDENCE_DIR:-$PROJECT_DIR/artifacts/ui-flow-tests/ios}"
WAV_SOURCE="${EVAL_WAV_PATH:-$PROJECT_DIR/artifacts/benchmarks/long_en_eval.wav}"
SCREENSHOT_DIR="/tmp/ui_flow_evidence"
SCHEME="OfflineTranscription"
TEST_CLASS="OfflineTranscriptionUITests/UserFlowUITests"
BUNDLE_ID="com.voiceping.offline-transcription"

if [ -z "$IOS_DEVICE_ID" ]; then
    echo "ERROR: IOS_DEVICE_ID environment variable is required."
    echo "Usage: IOS_DEVICE_ID=<device-udid> $0 [test_name ...]"
    echo ""
    echo "Find your device UDID with: xcrun devicectl list devices"
    exit 1
fi

ALL_TESTS=(
    "test_01_appLaunchAndModelLoad"
    "test_02_testFileTranscription"
    "test_03_recordButtonStates"
    "test_04_settingsNavigation"
    "test_05_saveAndHistory"
    "test_06_historyEmptyAndDelete"
    "test_07_settingsCopyAndClear"
    "test_08_modelSwitchInSettings"
    "test_09_tabSwitchPreservesState"
    "test_10_modelSetupOnboarding"
)

# Parse arguments
if [ $# -gt 0 ]; then
    TESTS=("$@")
else
    TESTS=("${ALL_TESTS[@]}")
fi

echo "=== iOS UI Flow Test Suite ==="
echo "Device: $IOS_DEVICE_ID"
echo "Tests to run: ${TESTS[*]}"
echo "Evidence directory: $EVIDENCE_DIR"
echo ""

# Setup
mkdir -p "$EVIDENCE_DIR"
rm -rf "$SCREENSHOT_DIR"
mkdir -p "$SCREENSHOT_DIR"

# Copy test WAV to /tmp
if [ -f "$WAV_SOURCE" ]; then
    cp "$WAV_SOURCE" /private/tmp/test_speech.wav
    echo "Test WAV placed at /private/tmp/test_speech.wav"
else
    echo "WARNING: Test WAV not found at $WAV_SOURCE"
fi

PASS_COUNT=0
FAIL_COUNT=0
typeset -A RESULTS

for TEST_NAME in "${TESTS[@]}"; do
    echo "--- Running: $TEST_NAME ---"
    TEST_DIR="$EVIDENCE_DIR/$TEST_NAME"
    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_DIR"

    # Run individual XCUITest on real device
    RESULT=$(xcodebuild test \
        -project "$PROJECT_DIR/VoicePingIOSAndroidOfflineSpeechTranslation.xcodeproj" \
        -scheme "$SCHEME" \
        -destination "id=$IOS_DEVICE_ID" \
        -only-testing:"$TEST_CLASS/$TEST_NAME" \
        -allowProvisioningUpdates \
        2>&1 || true)

    # Check pass/fail
    if echo "$RESULT" | grep -q "Test Suite.*passed"; then
        echo "  PASSED"
        PASS_COUNT=$((PASS_COUNT + 1))
        RESULTS[$TEST_NAME]="PASS"
    else
        echo "  FAILED"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        RESULTS[$TEST_NAME]="FAIL"
        # Save xcodebuild output for debugging
        echo "$RESULT" > "$TEST_DIR/xcodebuild_output.log"
    fi

    # Collect screenshots from /tmp
    SRC_DIR="$SCREENSHOT_DIR/$TEST_NAME"
    if [ -d "$SRC_DIR" ]; then
        cp "$SRC_DIR"/*.png "$TEST_DIR/" 2>/dev/null
    fi

    PNG_COUNT=$(ls "$TEST_DIR"/*.png 2>/dev/null | wc -l | tr -d ' ')
    echo "  Screenshots: $PNG_COUNT"
    echo ""
done

# Summary
TOTAL=${#TESTS[@]}
echo "=== UI Flow Test Summary ==="
echo "Total: $TOTAL | Pass: $PASS_COUNT | Fail: $FAIL_COUNT"
echo ""

for TEST_NAME in "${TESTS[@]}"; do
    echo "  ${RESULTS[$TEST_NAME]:-SKIP}: $TEST_NAME"
done

echo ""

# Generate markdown report
REPORT_FILE="$EVIDENCE_DIR/report.md"
cat > "$REPORT_FILE" << 'HEADER'
# iOS UI Flow Test Report

| Test | Result | Screenshots |
|------|--------|-------------|
HEADER

for TEST_NAME in "${TESTS[@]}"; do
    TEST_DIR="$EVIDENCE_DIR/$TEST_NAME"
    PNG_COUNT=$(ls "$TEST_DIR"/*.png 2>/dev/null | wc -l | tr -d ' ')
    STATUS="${RESULTS[$TEST_NAME]:-SKIP}"
    echo "| $TEST_NAME | $STATUS | $PNG_COUNT |" >> "$REPORT_FILE"
done

echo "" >> "$REPORT_FILE"
echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$REPORT_FILE"

echo "Report: $REPORT_FILE"
echo "Evidence: $EVIDENCE_DIR"
