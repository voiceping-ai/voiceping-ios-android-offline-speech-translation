#!/bin/bash
# Android User Flow E2E Tests - Runs all 10 UiAutomator user flow patterns
# Usage: ./scripts/android-userflow-test.sh [test_method ...]
# If no test methods provided, runs all 10 tests.
# Examples:
#   ./scripts/android-userflow-test.sh                          # all tests
#   ./scripts/android-userflow-test.sh test_01_micButtonToggle   # single test

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ANDROID_DIR="$PROJECT_DIR/VoicePingIOSAndroidOfflineSpeechTranslationAndroid"
EVIDENCE_DIR="$PROJECT_DIR/artifacts/e2e/android/userflow"
TEST_CLASS="com.voiceping.offlinetranscription.e2e.UserFlowE2ETest"
TEST_RUNNER="com.voiceping.offlinetranscription.test/androidx.test.runner.AndroidJUnitRunner"

ALL_TESTS=(
    "test_01_micButtonToggle"
    "test_02_micRecordAndTranscribe"
    "test_03_settingsBottomSheet"
    "test_04_settingsToggleVAD"
    "test_05_changeModelFlow"
    "test_06_saveAndViewHistory"
    "test_07_copyTranscript"
    "test_08_clearTranscription"
    "test_09_recordWhileNoModel"
    "test_10_historyDeleteItem"
)

if [ $# -gt 0 ]; then
    TESTS=("$@")
else
    TESTS=("${ALL_TESTS[@]}")
fi

echo "=== Android User Flow E2E Tests ==="
echo "Tests to run: ${TESTS[*]}"
echo "Evidence directory: $EVIDENCE_DIR"
echo ""

# Clean device evidence directory
adb shell rm -rf /sdcard/Documents/e2e/userflow/ 2>/dev/null || true
adb shell mkdir -p /sdcard/Documents/e2e/userflow/

# Build test APK
echo "Building test APK..."
cd "$ANDROID_DIR"
JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home \
    ./gradlew assembleDebug assembleDebugAndroidTest --quiet 2>&1 | tail -5

# Install app + test APK
echo "Installing app and test APKs..."
adb install -r app/build/outputs/apk/debug/app-debug.apk 2>/dev/null || true
adb install -r app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk 2>/dev/null || true

echo ""

PASS_COUNT=0
FAIL_COUNT=0

for TEST_METHOD in "${TESTS[@]}"; do
    echo "--- Running: $TEST_METHOD ---"

    RESULT=$(adb shell am instrument -w \
        -e class "${TEST_CLASS}#${TEST_METHOD}" \
        "$TEST_RUNNER" 2>&1 || true)

    if echo "$RESULT" | grep -q "OK (1 test)"; then
        PASS_COUNT=$((PASS_COUNT + 1))
        echo "  PASS"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        # Extract failure reason
        FAILURE=$(echo "$RESULT" | grep -A2 "FAILURES" || echo "unknown")
        echo "  FAIL: $FAILURE"
    fi

    echo ""
done

# Pull all evidence
echo "Pulling evidence screenshots..."
mkdir -p "$EVIDENCE_DIR"
adb pull /sdcard/Documents/e2e/userflow/ "$EVIDENCE_DIR/" 2>/dev/null || true

# Count screenshots
PNG_COUNT=$(find "$EVIDENCE_DIR" -name "*.png" 2>/dev/null | wc -l | tr -d ' ')

echo ""
echo "=== User Flow Test Summary ==="
echo "Total: ${#TESTS[@]} | Pass: $PASS_COUNT | Fail: $FAIL_COUNT"
echo "Screenshots captured: $PNG_COUNT"
echo "Evidence directory: $EVIDENCE_DIR"
