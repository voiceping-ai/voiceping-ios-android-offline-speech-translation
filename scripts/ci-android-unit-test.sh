#!/usr/bin/env bash

# CI smoke test for Android: build debug APK and run a minimal unit test suite.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_DIR="$PROJECT_DIR/VoicePingIOSAndroidOfflineSpeechTranslationAndroid"

# Keep this minimal and stable while still exercising app-level test wiring.
TEST_FILTER="${ANDROID_TEST_FILTER:-com.voiceping.offlinetranscription.service.AsrEngineTest}"

cd "$APP_DIR"
chmod +x ./gradlew ./setup-deps.sh

./setup-deps.sh
./gradlew --no-daemon assembleDebug
./gradlew --no-daemon testDebugUnitTest --tests "$TEST_FILTER"
