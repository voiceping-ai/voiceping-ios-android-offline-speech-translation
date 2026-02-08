#!/usr/bin/env bash
# Run end-to-end throughput evaluation for iOS + Android and update README charts/tables.
#
# Usage:
#   scripts/run-inference-benchmarks.sh
#
# Env:
#   TARGET_SECONDS (default: 30)  -> length of generated English fixture
#   RUN_IOS (default: 1)
#   RUN_ANDROID (default: 1)
#   IOS_XCUITEST (default: 0)     -> set to 1 to use --xcuitest mode

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

TARGET_SECONDS="${TARGET_SECONDS:-30}"
RUN_IOS="${RUN_IOS:-1}"
RUN_ANDROID="${RUN_ANDROID:-1}"
IOS_XCUITEST="${IOS_XCUITEST:-0}"

AUDIO_FIXTURE="$PROJECT_DIR/artifacts/benchmarks/long_en_eval.wav"

echo "=== Inference Benchmark Run ==="
echo "Project:        $PROJECT_DIR"
echo "Target seconds: $TARGET_SECONDS"
echo "Run iOS:        $RUN_IOS"
echo "Run Android:    $RUN_ANDROID"
echo "iOS XCUITest:   $IOS_XCUITEST"
echo ""

TARGET_SECONDS="$TARGET_SECONDS" "$SCRIPT_DIR/prepare-long-eval-audio.sh" \
    "$PROJECT_DIR/artifacts/benchmarks/seed_en_eval.wav" \
    "$AUDIO_FIXTURE"

if [ "$RUN_IOS" = "1" ]; then
    echo ""
    echo "--- Running iOS E2E per-model benchmark ---"
    if [ "$IOS_XCUITEST" = "1" ]; then
        EVAL_WAV_PATH="$AUDIO_FIXTURE" "$SCRIPT_DIR/ios-e2e-test.sh" --xcuitest
    else
        EVAL_WAV_PATH="$AUDIO_FIXTURE" "$SCRIPT_DIR/ios-e2e-test.sh"
    fi
fi

if [ "$RUN_ANDROID" = "1" ]; then
    echo ""
    echo "--- Running Android E2E per-model benchmark ---"
    EVAL_WAV_PATH="$AUDIO_FIXTURE" "$SCRIPT_DIR/android-e2e-test.sh"
fi

echo ""
echo "--- Generating charts + README benchmark section ---"
python3 "$SCRIPT_DIR/generate-inference-report.py" \
    --audio "$AUDIO_FIXTURE" \
    --update-readme

echo ""
echo "Benchmark run completed."
