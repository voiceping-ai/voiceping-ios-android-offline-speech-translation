#!/usr/bin/env bash
# Build a longer English WAV fixture for model throughput evaluation.
# Usage:
#   scripts/prepare-long-eval-audio.sh [input_wav] [output_wav]
#
# Env:
#   TARGET_SECONDS (default: 30)
#   COPY_TO_TMP (default: 1)   -> copy output to /private/tmp/test_speech.wav
#   PUSH_ANDROID (default: 0)  -> adb push output to /data/local/tmp/test_speech.wav

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

INPUT_WAV="${1:-$PROJECT_DIR/artifacts/benchmarks/seed_en_eval.wav}"
OUTPUT_WAV="${2:-$PROJECT_DIR/artifacts/benchmarks/long_en_eval.wav}"
TARGET_SECONDS="${TARGET_SECONDS:-30}"
COPY_TO_TMP="${COPY_TO_TMP:-1}"
PUSH_ANDROID="${PUSH_ANDROID:-0}"

if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "ERROR: ffmpeg is required but was not found in PATH."
    exit 1
fi

if ! command -v ffprobe >/dev/null 2>&1; then
    echo "ERROR: ffprobe is required but was not found in PATH."
    exit 1
fi

if [ ! -f "$INPUT_WAV" ]; then
    echo "ERROR: input WAV not found: $INPUT_WAV"
    exit 1
fi

mkdir -p "$(dirname "$OUTPUT_WAV")"

SOURCE_DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$INPUT_WAV")
if [ -z "$SOURCE_DURATION" ]; then
    echo "ERROR: could not read duration from: $INPUT_WAV"
    exit 1
fi

REPEAT_COUNT=$(python3 - "$SOURCE_DURATION" "$TARGET_SECONDS" <<'PY'
import math, sys
src = float(sys.argv[1])
target = float(sys.argv[2])
print(max(1, math.ceil(target / src) + 1))
PY
)

MANIFEST="$(mktemp)"
cleanup() {
    rm -f "$MANIFEST"
}
trap cleanup EXIT

for _ in $(seq 1 "$REPEAT_COUNT"); do
    printf "file '%s'\n" "$INPUT_WAV" >>"$MANIFEST"
done

ffmpeg -y \
    -f concat -safe 0 -i "$MANIFEST" \
    -ac 1 -ar 16000 -c:a pcm_s16le \
    -t "$TARGET_SECONDS" \
    "$OUTPUT_WAV" >/dev/null 2>&1

OUT_DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUTPUT_WAV")
OUT_SIZE=$(du -h "$OUTPUT_WAV" | awk '{print $1}')

echo "Created long evaluation fixture:"
echo "  input:      $INPUT_WAV"
echo "  output:     $OUTPUT_WAV"
echo "  duration:   ${OUT_DURATION}s"
echo "  target:     ${TARGET_SECONDS}s"
echo "  repeats:    $REPEAT_COUNT"
echo "  file size:  $OUT_SIZE"

if [ "$COPY_TO_TMP" = "1" ]; then
    cp "$OUTPUT_WAV" /private/tmp/test_speech.wav
    echo "Copied to /private/tmp/test_speech.wav (iOS auto-test path)"
fi

if [ "$PUSH_ANDROID" = "1" ]; then
    if command -v adb >/dev/null 2>&1; then
        adb push "$OUTPUT_WAV" /data/local/tmp/test_speech.wav >/dev/null
        echo "Pushed to /data/local/tmp/test_speech.wav (Android auto-test path)"
    elif [ -x "$HOME/Library/Android/sdk/platform-tools/adb" ]; then
        "$HOME/Library/Android/sdk/platform-tools/adb" push \
            "$OUTPUT_WAV" /data/local/tmp/test_speech.wav >/dev/null
        echo "Pushed via SDK adb to /data/local/tmp/test_speech.wav"
    else
        echo "WARN: PUSH_ANDROID=1 but adb was not found."
    fi
fi
