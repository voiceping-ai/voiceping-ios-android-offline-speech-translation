#!/usr/bin/env bash
# Downloads external dependencies not shipped in the repository.
# Run once after cloning:  ./setup-deps.sh

set -euo pipefail

SHERPA_VERSION="1.12.23"
SHERPA_AAR="sherpa-onnx-${SHERPA_VERSION}.aar"
LIBS_DIR="$(cd "$(dirname "$0")" && pwd)/app/libs"

mkdir -p "$LIBS_DIR"

if [ -f "$LIBS_DIR/$SHERPA_AAR" ]; then
    echo "✓ $SHERPA_AAR already present"
else
    echo "Downloading $SHERPA_AAR (≈37 MB)…"
    curl -L --fail -o "$LIBS_DIR/$SHERPA_AAR" \
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/v${SHERPA_VERSION}/${SHERPA_AAR}"
    echo "✓ Downloaded $SHERPA_AAR"
fi
