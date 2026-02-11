#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BASE_SPEC="$REPO_DIR/project.yml"
LOCAL_SPEC="$REPO_DIR/project.local.yml"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is required. Install with: brew install xcodegen" >&2
  exit 1
fi

SPEC="$BASE_SPEC"
if [ -f "$LOCAL_SPEC" ]; then
  SPEC="$LOCAL_SPEC"
fi

echo "Generating Xcode project from $(basename "$SPEC")..."
xcodegen generate --spec "$SPEC"

if [ "$SPEC" = "$BASE_SPEC" ]; then
  cat <<'EOF'
Generated without local signing overrides.
For physical device builds, copy project.local.yml.example to project.local.yml,
set DEVELOPMENT_TEAM and bundle identifiers, then run this script again.
EOF
fi
