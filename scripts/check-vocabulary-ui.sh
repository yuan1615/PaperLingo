#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
mkdir -p .test-output
FIXTURE_DIR="$(mktemp -d "$PROJECT_ROOT/.test-output/word-fixture.XXXXXX")"
python3 Tests/PaperLingoUITests/word_model_fixture.py "$FIXTURE_DIR/port" > "$FIXTURE_DIR/server.log" 2>&1 &
FIXTURE_PID=$!
trap 'kill "$FIXTURE_PID" 2>/dev/null || true; wait "$FIXTURE_PID" 2>/dev/null || true' EXIT
for attempt in {1..50}; do
  if [[ -f "$FIXTURE_DIR/port" ]]; then break; fi
  sleep 0.1
done
PAPERLINGO_TEST_MODEL_PORT="$(cat "$FIXTURE_DIR/port")" \
  PAPERLINGO_UI_CHECK_SOURCE=Tests/PaperLingoUITests/VocabularyChecks.swift bash scripts/check-review-ui.sh
