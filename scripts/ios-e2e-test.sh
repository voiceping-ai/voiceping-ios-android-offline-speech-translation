#!/bin/zsh
# iOS E2E Test Script - Cycles through all models, captures evidence
# Usage: ./scripts/ios-e2e-test.sh [--xcuitest] [model_id ...]
# If no model_ids provided, runs all 11 models.
# --xcuitest: Use XCUITest runner instead of simctl (captures via XCUIScreenshot)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

SIMULATOR_ID="578CBE53-DFDD-4BC5-874C-5F96A59A5C64"
IOS_DEVICE_ID="${IOS_DEVICE_ID:-}"
USE_REAL_DEVICE=false
EVIDENCE_DIR="${EVIDENCE_DIR:-$PROJECT_DIR/artifacts/e2e/ios}"
WAV_SOURCE="${EVAL_WAV_PATH:-$PROJECT_DIR/artifacts/benchmarks/long_en_eval.wav}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$PROJECT_DIR/build/DerivedData}"
USE_XCUITEST=false

if [ -n "$IOS_DEVICE_ID" ]; then
    USE_REAL_DEVICE=true
    USE_XCUITEST=true
fi

ALL_MODELS=(
    "sensevoice-small"
    "parakeet-tdt-v3"
)

# Parse arguments
POSITIONAL=()
while [ $# -gt 0 ]; do
    case "$1" in
        --xcuitest) USE_XCUITEST=true; shift ;;
        *) POSITIONAL+=("$1"); shift ;;
    esac
done

if [ ${#POSITIONAL[@]} -gt 0 ]; then
    MODELS=("${POSITIONAL[@]}")
else
    MODELS=("${ALL_MODELS[@]}")
fi

# Wait time per model (seconds) - larger models need more time for download + inference
get_wait_time() {
    local model=$1
    case "$model" in
        whisper-large-v3-turbo*|omnilingual-300m) echo 480 ;;
        whisper-small|parakeet-tdt-v3) echo 300 ;;
        whisper-base) echo 240 ;;
        *) echo 120 ;;
    esac
}

echo "=== iOS E2E Test Suite ==="
echo "Mode: $([ "$USE_XCUITEST" = true ] && echo "XCUITest" || echo "simctl")"
echo "Target: $([ "$USE_REAL_DEVICE" = true ] && echo "real-device:$IOS_DEVICE_ID" || echo "simulator:$SIMULATOR_ID")"
echo "Models to test: ${MODELS[*]}"
echo "Audio fixture: $WAV_SOURCE"
echo "Evidence directory: $EVIDENCE_DIR"
echo ""

# Setup
mkdir -p "$EVIDENCE_DIR"

if [ ! -f "$WAV_SOURCE" ]; then
    echo "ERROR: WAV source not found: $WAV_SOURCE"
    exit 1
fi

# Copy test WAV to /tmp (macOS filesystem, accessible from simulator)
cp "$WAV_SOURCE" /private/tmp/test_speech.wav
echo "Test WAV placed at /private/tmp/test_speech.wav"

# Ensure simulator is booted only when using simulator mode
if [ "$USE_REAL_DEVICE" = false ]; then
    xcrun simctl boot "$SIMULATOR_ID" 2>/dev/null || true
    sleep 3
fi

# --- XCUITest mode ---
if [ "$USE_XCUITEST" = true ]; then
    # Map model IDs to test method names
    typeset -A XCUI_METHODS
    XCUI_METHODS=(
        whisper-tiny test_whisperTiny
        whisper-base test_whisperBase
        whisper-small test_whisperSmall
        whisper-large-v3-turbo test_whisperLargeV3Turbo
        whisper-large-v3-turbo-compressed test_whisperLargeV3TurboCompressed
        moonshine-tiny test_moonshineTiny
        moonshine-base test_moonshineBase
        sensevoice-small test_sensevoiceSmall
        zipformer-20m test_zipformer20m
        omnilingual-300m test_omnilingual300m
        parakeet-tdt-v3 test_parakeetTdtV3
    )

    PASS_COUNT=0
    FAIL_COUNT=0

    for MODEL_ID in "${MODELS[@]}"; do
        METHOD=${XCUI_METHODS[$MODEL_ID]}
        MODEL_DIR="$EVIDENCE_DIR/$MODEL_ID"
        mkdir -p "$MODEL_DIR"

        echo "--- Testing: $MODEL_ID (XCUITest: $METHOD) ---"

        # Clean previous results
        rm -f "/private/tmp/e2e_result_${MODEL_ID}.json"
        rm -rf "/tmp/e2e_evidence/${MODEL_ID}"

        # Run individual XCUITest
        DESTINATION_ARG="platform=iOS Simulator,id=$SIMULATOR_ID"
        if [ "$USE_REAL_DEVICE" = true ]; then
            DESTINATION_ARG="id=$IOS_DEVICE_ID"
        fi

        RESULT=$(xcodebuild test \
            -project "$PROJECT_DIR/VoicePingIOSAndroidOfflineSpeechTranslation.xcodeproj" \
            -scheme OfflineTranscription \
            -destination "$DESTINATION_ARG" \
            -only-testing:"OfflineTranscriptionUITests/AllModelsE2ETest/$METHOD" \
            -resultBundlePath "$MODEL_DIR/result.xcresult" \
            2>&1 || true)

        if echo "$RESULT" | grep -q "Test Suite.*passed"; then
            echo "  XCUITest passed"
        elif echo "$RESULT" | grep -q "TEST_FAILED"; then
            echo "  XCUITest failed"
        fi

        # Collect evidence from /tmp/e2e_evidence/{modelId}/ (written by test)
        if [ -d "/tmp/e2e_evidence/$MODEL_ID" ]; then
            cp -r "/tmp/e2e_evidence/$MODEL_ID/"* "$MODEL_DIR/" 2>/dev/null || true
        fi

        # Also check /tmp result.json
        RESULT_FILE="/private/tmp/e2e_result_${MODEL_ID}.json"
        if [ -f "$RESULT_FILE" ] && [ ! -f "$MODEL_DIR/result.json" ]; then
            cp "$RESULT_FILE" "$MODEL_DIR/result.json"
        fi

        # Report
        if [ -f "$MODEL_DIR/result.json" ]; then
            PASS=$(python3 -c "import json; r=json.load(open('$MODEL_DIR/result.json')); print('PASS' if r['pass'] else 'FAIL')" 2>/dev/null || echo "UNKNOWN")
            TRANSCRIPT=$(python3 -c "import json; r=json.load(open('$MODEL_DIR/result.json')); print(r.get('transcript','')[:80])" 2>/dev/null || echo "")
            DURATION=$(python3 -c "import json; r=json.load(open('$MODEL_DIR/result.json')); print(f\"{r.get('duration_ms',0):.0f}ms\")" 2>/dev/null || echo "")

            if [ "$PASS" = "PASS" ]; then
                PASS_COUNT=$((PASS_COUNT + 1))
                echo "  PASS ($DURATION) - $TRANSCRIPT"
            else
                FAIL_COUNT=$((FAIL_COUNT + 1))
                echo "  FAIL ($DURATION) - $TRANSCRIPT"
            fi
        else
            FAIL_COUNT=$((FAIL_COUNT + 1))
            echo "  NO RESULT - result.json not found"
        fi

        PNG_COUNT=$(ls "$MODEL_DIR"/*.png 2>/dev/null | wc -l | tr -d ' ')
        echo "  Screenshots: $PNG_COUNT"
        echo ""
    done

    echo "=== E2E Test Summary (XCUITest) ==="
    echo "Total: ${#MODELS[@]} | Pass: $PASS_COUNT | Fail: $FAIL_COUNT"
    echo "Evidence directory: $EVIDENCE_DIR"
    exit 0
fi

# --- simctl mode (default) ---

if [ "$USE_REAL_DEVICE" = true ]; then
    echo "ERROR: simctl mode is not supported for real devices. Use --xcuitest or set IOS_DEVICE_ID."
    exit 1
fi

# Build latest app in repo-local DerivedData
echo "Building app..."
xcodebuild \
    -project "$PROJECT_DIR/VoicePingIOSAndroidOfflineSpeechTranslation.xcodeproj" \
    -scheme OfflineTranscription \
    -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    build >/tmp/ios_e2e_build.log
APP_PATH="$DERIVED_DATA_PATH/Build/Products/Debug-iphonesimulator/OfflineTranscription.app"
if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: built app not found at $APP_PATH"
    exit 1
fi

APP_BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_PATH/Info.plist" 2>/dev/null || true)
if [ -z "$APP_BUNDLE_ID" ]; then
    echo "ERROR: could not resolve app bundle identifier from $APP_PATH/Info.plist"
    exit 1
fi

# Install latest app
xcrun simctl install "$SIMULATOR_ID" "$APP_PATH"
echo "App installed. Bundle ID: $APP_BUNDLE_ID"
echo ""

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

for MODEL_ID in "${MODELS[@]}"; do
    MODEL_DIR="$EVIDENCE_DIR/$MODEL_ID"
    mkdir -p "$MODEL_DIR"

    WAIT=$(get_wait_time "$MODEL_ID")
    echo "--- Testing: $MODEL_ID (timeout: ${WAIT}s) ---"

    # Terminate any running instance
    xcrun simctl terminate "$SIMULATOR_ID" "$APP_BUNDLE_ID" 2>/dev/null || true
    sleep 2

    # Clean up previous result BEFORE launching
    RESULT_FILE="/private/tmp/e2e_result_${MODEL_ID}.json"
    rm -f "$RESULT_FILE"

    # Launch with auto-test
    xcrun simctl launch "$SIMULATOR_ID" "$APP_BUNDLE_ID" --auto-test --model-id "$MODEL_ID" 2>/dev/null
    echo "  Launched. Waiting for download + load + transcription..."

    # Take initial screenshot after brief delay
    sleep 5
    xcrun simctl io "$SIMULATOR_ID" screenshot "$MODEL_DIR/01_model_loading.png" 2>/dev/null

    # Wait for transcription to complete
    ELAPSED=5

    while [ $ELAPSED -lt $WAIT ]; do
        sleep 10
        ELAPSED=$((ELAPSED + 10))

        # Check if result.json appeared
        if [ -f "$RESULT_FILE" ]; then
            echo "  Result file found after ${ELAPSED}s"
            break
        fi

        # Take periodic screenshot during download
        if [ $((ELAPSED % 30)) -eq 0 ]; then
            xcrun simctl io "$SIMULATOR_ID" screenshot "$MODEL_DIR/02_progress_${ELAPSED}s.png" 2>/dev/null
            echo "  Progress screenshot at ${ELAPSED}s"
        fi
    done

    # Take final screenshot (inference result)
    sleep 3
    xcrun simctl io "$SIMULATOR_ID" screenshot "$MODEL_DIR/03_inference_result.png" 2>/dev/null

    # Copy result.json
    if [ -f "$RESULT_FILE" ]; then
        cp "$RESULT_FILE" "$MODEL_DIR/result.json"
        PASS=$(python3 -c "import json; r=json.load(open('$RESULT_FILE')); print('PASS' if r['pass'] else 'FAIL')" 2>/dev/null || echo "UNKNOWN")
        TRANSCRIPT=$(python3 -c "import json; r=json.load(open('$RESULT_FILE')); print(r['transcript'][:80])" 2>/dev/null || echo "")
        DURATION=$(python3 -c "import json; r=json.load(open('$RESULT_FILE')); print(f\"{r['duration_ms']:.0f}ms\")" 2>/dev/null || echo "")

        if [ "$PASS" = "PASS" ]; then
            PASS_COUNT=$((PASS_COUNT + 1))
            echo "  PASS ($DURATION) - $TRANSCRIPT"
        else
            FAIL_COUNT=$((FAIL_COUNT + 1))
            echo "  FAIL ($DURATION) - $TRANSCRIPT"
        fi
    else
        SKIP_COUNT=$((SKIP_COUNT + 1))
        echo "  TIMEOUT - no result.json after ${WAIT}s"
        echo "{\"model_id\": \"$MODEL_ID\", \"pass\": false, \"error\": \"timeout after ${WAIT}s\"}" > "$MODEL_DIR/result.json"
    fi

    echo ""
done

# Generate summary report
echo "=== E2E Test Summary ==="
echo "Total: ${#MODELS[@]} | Pass: $PASS_COUNT | Fail: $FAIL_COUNT | Timeout: $SKIP_COUNT"
echo ""

# Generate audit report
REPORT_FILE="$EVIDENCE_DIR/audit_report.md"
cat > "$REPORT_FILE" << 'HEADER'
# iOS E2E Audit Report

| Model | Engine | Pass | Duration | Transcript (first 60 chars) |
|-------|--------|------|----------|----------------------------|
HEADER

for MODEL_ID in "${MODELS[@]}"; do
    RESULT_FILE="$EVIDENCE_DIR/$MODEL_ID/result.json"
    if [ -f "$RESULT_FILE" ]; then
        ROW=$(python3 -c "
import json
r = json.load(open('$RESULT_FILE'))
model = r.get('model_id', '$MODEL_ID')
engine = r.get('engine', 'unknown')
p = 'PASS' if r.get('pass', False) else 'FAIL'
d = f\"{r.get('duration_ms', 0):.0f}ms\"
t = r.get('transcript', '')[:60].replace('|', '\\|')
err = r.get('error', '')
if err: t = f'ERROR: {err[:50]}'
print(f'| {model} | {engine} | {p} | {d} | {t} |')
" 2>/dev/null || echo "| $MODEL_ID | ? | ? | ? | parse error |")
        echo "$ROW" >> "$REPORT_FILE"
    fi
done

echo "" >> "$REPORT_FILE"
echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$REPORT_FILE"

echo "Audit report: $REPORT_FILE"
echo "Evidence directory: $EVIDENCE_DIR"
