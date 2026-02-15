#!/bin/zsh
# iOS E2E Test Script - Cycles through all models, captures evidence
# Usage: IOS_DEVICE_ID=<udid> ./scripts/ios-e2e-test.sh [model_id ...]
# If no model_ids provided, runs all default models.
# Requires IOS_DEVICE_ID environment variable (real device UDID).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

IOS_DEVICE_ID="${IOS_DEVICE_ID:-}"
EVIDENCE_DIR="${EVIDENCE_DIR:-$PROJECT_DIR/artifacts/e2e/ios}"
WAV_SOURCE="${EVAL_WAV_PATH:-$PROJECT_DIR/artifacts/benchmarks/long_en_eval.wav}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$PROJECT_DIR/build/DerivedData}"
BUNDLE_ID="com.voiceping.offline-transcription"

if [ -z "$IOS_DEVICE_ID" ]; then
    echo "ERROR: IOS_DEVICE_ID environment variable is required."
    echo "Usage: IOS_DEVICE_ID=<device-udid> $0 [model_id ...]"
    echo ""
    echo "Find your device UDID with: xcrun devicectl list devices"
    exit 1
fi

ALL_MODELS=(
    "sensevoice-small"
    "parakeet-tdt-v3"
    "apple-speech"
)

# Parse arguments
if [ $# -gt 0 ]; then
    MODELS=("$@")
else
    MODELS=("${ALL_MODELS[@]}")
fi

# Wait time per model (seconds) - larger models need more time for download + inference
get_wait_time() {
    local model=$1
    case "$model" in
        whisper-large-v3-turbo*|omnilingual-300m) echo 480 ;;
        whisper-small) echo 300 ;;
        parakeet-tdt-v3) echo 900 ;;
        whisper-base) echo 240 ;;
        *) echo 120 ;;
    esac
}

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
    apple-speech test_appleSpeech
)

echo "=== iOS E2E Test Suite ==="
echo "Device: $IOS_DEVICE_ID"
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

# Copy test WAV to /tmp (accessible from device via XCUITest)
cp "$WAV_SOURCE" /private/tmp/test_speech.wav
echo "Test WAV placed at /private/tmp/test_speech.wav"

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

    # Run individual XCUITest on real device
    RESULT=$(xcodebuild test \
        -project "$PROJECT_DIR/VoicePingIOSAndroidOfflineSpeechTranslation.xcodeproj" \
        -scheme OfflineTranscription \
        -destination "id=$IOS_DEVICE_ID" \
        -only-testing:"OfflineTranscriptionUITests/AllModelsE2ETest/$METHOD" \
        -resultBundlePath "$MODEL_DIR/result.xcresult" \
        -allowProvisioningUpdates \
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

    PNG_COUNT=$(find "$MODEL_DIR" -maxdepth 1 -name "*.png" 2>/dev/null | wc -l | tr -d ' ')
    echo "  Screenshots: $PNG_COUNT"
    echo ""
done

echo "=== E2E Test Summary ==="
echo "Total: ${#MODELS[@]} | Pass: $PASS_COUNT | Fail: $FAIL_COUNT"
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
