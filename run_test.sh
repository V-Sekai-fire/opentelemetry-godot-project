#!/usr/bin/env bash
# Run the OpenTelemetry collector connectivity test.
# Usage: ./run_test.sh [--collector http://host:4318]
set -euo pipefail

GODOT="${GODOT:-../opentelemetry-godot/bin/godot.macos.editor.dev.double.arm64}"
COLLECTOR="${1:-http://localhost:4318}"

if [[ ! -x "$GODOT" ]]; then
  echo "ERROR: Godot binary not found at $GODOT"
  echo "Build it first: cd ../opentelemetry-godot && scons target=editor dev_mode=yes arch=arm64"
  exit 1
fi

echo "Starting collector stack..."
docker compose up -d
echo "Waiting for collector to be ready..."
sleep 3

echo "Running Godot test against $COLLECTOR ..."
"$GODOT" --headless --path "$(pwd)" -- --collector "$COLLECTOR"
STATUS=$?

echo ""
if [[ $STATUS -eq 0 ]]; then
  echo "✓ Test passed. View traces at http://localhost:16686 (Jaeger UI)"
else
  echo "✗ Test failed (exit $STATUS)"
fi

exit $STATUS
