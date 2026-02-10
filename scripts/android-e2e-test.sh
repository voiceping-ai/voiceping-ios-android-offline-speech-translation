#!/bin/zsh
# Android E2E Test Script - Cycles through all models, captures evidence
# Usage: ./scripts/android-e2e-test.sh [model_id ...]
# If no model_ids provided, runs all Android models.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ADB="${ADB_PATH:-$HOME/Library/Android/sdk/platform-tools/adb}"
PACKAGE="${PACKAGE:-}"
EVIDENCE_DIR="${EVIDENCE_DIR:-$PROJECT_DIR/artifacts/e2e/android}"
WAV_SOURCE="${EVAL_WAV_PATH:-$PROJECT_DIR/artifacts/benchmarks/long_en_eval.wav}"
GRADLE_DIR="$PROJECT_DIR/VoicePingIOSAndroidOfflineSpeechTranslationAndroid"
TEST_CLASS="com.voiceping.offlinetranscription.e2e.AllModelsE2ETest"
INSTRUMENT_TIMEOUT_SEC="${INSTRUMENT_TIMEOUT_SEC:-480}"
export JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home

if [ -z "$PACKAGE" ]; then
    PACKAGE=$(python3 - <<'PY'
import pathlib, re, sys
p = pathlib.Path("VoicePingIOSAndroidOfflineSpeechTranslationAndroid/app/build.gradle.kts")
txt = p.read_text(encoding="utf-8")
m = re.search(r'applicationId\s*=\s*"([^"]+)"', txt)
if not m:
    sys.exit(1)
print(m.group(1))
PY
)
fi

if [ -z "$PACKAGE" ]; then
    echo "ERROR: could not resolve Android applicationId"
    exit 1
fi

ALL_MODELS=(
    "sensevoice-small"
    "parakeet-tdt-0.6b-v2-int8"
)

# Map model-id to test method name
typeset -A TEST_METHODS
TEST_METHODS=(
    sensevoice-small test_sensevoiceSmall
    parakeet-tdt-0.6b-v2-int8 test_parakeetTdtV3
)

# Use provided models or all
if [ $# -gt 0 ]; then
    MODELS=("$@")
else
    MODELS=("${ALL_MODELS[@]}")
fi

echo "=== Android E2E Test Suite ==="
echo "Package: $PACKAGE"
echo "Models to test: ${MODELS[*]}"
echo "Audio fixture: $WAV_SOURCE"
echo "Per-model timeout: ${INSTRUMENT_TIMEOUT_SEC}s"
echo "Evidence directory: $EVIDENCE_DIR"
echo ""

# Setup
mkdir -p "$EVIDENCE_DIR"

if [ ! -f "$WAV_SOURCE" ]; then
    echo "ERROR: WAV source not found: $WAV_SOURCE"
    exit 1
fi

# Verify device connected
$ADB wait-for-device
echo "Device connected: $($ADB devices | grep -v 'List' | head -1)"

# Push test WAV
$ADB push "$WAV_SOURCE" /data/local/tmp/test_speech.wav
echo "Test WAV pushed to device."

# Build and install
echo "Building debug APK..."
(cd "$GRADLE_DIR" && ./gradlew assembleDebug assembleDebugAndroidTest 2>&1 | tail -3)
echo "Installing..."
(cd "$GRADLE_DIR" && ./gradlew installDebug installDebugAndroidTest 2>&1 | tail -3)
echo ""

PASS_COUNT=0
FAIL_COUNT=0

instrument_timeout_for_model() {
    local model_id="$1"
    case "$model_id" in
        parakeet-tdt-0.6b-v2-int8) echo 1800 ;;
        *) echo "$INSTRUMENT_TIMEOUT_SEC" ;;
    esac
}

ensure_instrumentation_installed() {
    if ! $ADB shell pm list instrumentation | grep -q "$PACKAGE.test/androidx.test.runner.AndroidJUnitRunner"; then
        echo "  Instrumentation missing; reinstalling app + androidTest APK..."
        (cd "$GRADLE_DIR" && ./gradlew installDebug installDebugAndroidTest 2>&1 | tail -3)
    fi
}

run_instrumentation_with_timeout() {
    local method="$1"
    local timeout_sec="$2"
    python3 - "$ADB" "$PACKAGE" "$TEST_CLASS" "$method" "$timeout_sec" <<'PY'
import subprocess
import sys

adb, package, test_class, method, timeout = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5])
cmd = [
    adb, "shell", "am", "instrument", "-w",
    "-e", "class", f"{test_class}#{method}",
    f"{package}.test/androidx.test.runner.AndroidJUnitRunner",
]

try:
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=timeout, check=False)
    sys.stdout.write(proc.stdout or "")
    sys.exit(proc.returncode)
except subprocess.TimeoutExpired as exc:
    out = exc.stdout or ""
    if isinstance(out, bytes):
        out = out.decode("utf-8", "replace")
    sys.stdout.write(out)
    sys.stdout.write(f"\nTIMEOUT: instrumentation exceeded {timeout}s\n")
    subprocess.run([adb, "shell", "am", "force-stop", package], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    subprocess.run([adb, "shell", "am", "force-stop", f"{package}.test"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    sys.exit(124)
PY
}

for MODEL_ID in "${MODELS[@]}"; do
    MODEL_DIR="$EVIDENCE_DIR/$MODEL_ID"
    rm -rf "$MODEL_DIR"
    mkdir -p "$MODEL_DIR"
    METHOD=${TEST_METHODS[$MODEL_ID]}
    MODEL_TIMEOUT_SEC=$(instrument_timeout_for_model "$MODEL_ID")

    echo "--- Testing: $MODEL_ID ($METHOD) ---"
    echo "  Instrument timeout: ${MODEL_TIMEOUT_SEC}s"
    ensure_instrumentation_installed
    # Avoid cross-app overlay contamination from previous runs.
    $ADB shell am force-stop "$PACKAGE" 2>/dev/null || true
    $ADB shell am force-stop "com.voiceping.transcribe" 2>/dev/null || true
    $ADB shell rm -rf "/sdcard/Documents/e2e/$MODEL_ID" 2>/dev/null || true
    $ADB shell rm -f "/sdcard/Android/data/$PACKAGE/files/e2e_result_${MODEL_ID}.json" 2>/dev/null || true

    # Run individual test
    $ADB logcat -c
    set +e
    RESULT=$(run_instrumentation_with_timeout "$METHOD" "$MODEL_TIMEOUT_SEC")
    INSTRUMENT_EXIT=$?
    set -e

    if echo "$RESULT" | grep -q "OK (1 test)"; then
        echo "  Test passed"
    elif [ "$INSTRUMENT_EXIT" -eq 124 ] || echo "$RESULT" | grep -q "TIMEOUT:"; then
        echo "  Test timed out after ${MODEL_TIMEOUT_SEC}s"
    else
        echo "  Test may have failed. Output:"
        echo "$RESULT" | tail -5
    fi

    # Pull evidence files individually
    for f in 01_model_selected.png 02_model_loaded.png 03_inference_result.png result.json; do
        $ADB pull "/sdcard/Documents/e2e/$MODEL_ID/$f" "$MODEL_DIR/$f" 2>/dev/null || true
    done

    # Check result.json (may be in subdir if adb pull created one)
    RESULT_FILE="$MODEL_DIR/result.json"
    if [ -f "$RESULT_FILE" ]; then
        PASS=$(python3 -c "import json; r=json.load(open('$RESULT_FILE')); print('PASS' if r['pass'] else 'FAIL')" 2>/dev/null || echo "UNKNOWN")
        TRANSCRIPT=$(python3 -c "import json; r=json.load(open('$RESULT_FILE')); print(r.get('transcript','')[:80])" 2>/dev/null || echo "")
        DURATION=$(python3 -c "import json; r=json.load(open('$RESULT_FILE')); print(f\"{r.get('duration_ms',0):.0f}ms\")" 2>/dev/null || echo "")

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

    # Count screenshots
    PNG_COUNT=$(find "$MODEL_DIR" -name "*.png" 2>/dev/null | wc -l | tr -d ' ')
    echo "  Screenshots: $PNG_COUNT"
    echo ""
done

# Generate summary report
echo "=== E2E Test Summary ==="
echo "Total: ${#MODELS[@]} | Pass: $PASS_COUNT | Fail: $FAIL_COUNT"
echo ""

# Generate audit report
REPORT_FILE="$EVIDENCE_DIR/audit_report.md"
cat > "$REPORT_FILE" << 'HEADER'
# Android E2E Audit Report

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
