#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULTS_DIR="$ROOT/.build/benchmarks"
RESULT="$RESULTS_DIR/latest.json"
TEST_FILTER="fiveHundredSequentialDictationsRemainReadyAndBoundDiagnostics"

mkdir -p "$RESULTS_DIR"
cd "$ROOT"
swift test -c release list >/dev/null
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
TEST_OUTPUT="$(swift test -c release --skip-build --filter "$TEST_FILTER")"
printf '%s\n' "$TEST_OUTPUT"
ELAPSED_SECONDS="$(
    printf '%s\n' "$TEST_OUTPUT" \
        | sed -nE 's/.*Test run with 1 test passed after ([0-9.]+) seconds.*/\1/p' \
        | tail -n 1
)"
if [[ ! "$ELAPSED_SECONDS" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo "error: could not read the reliability harness duration." >&2
    exit 1
fi

plutil -create xml1 "$RESULT"
plutil -insert schemaVersion -integer 1 "$RESULT"
plutil -insert recordedAt -string "$STARTED_AT" "$RESULT"
plutil -insert commit -string "$(git rev-parse --short HEAD)" "$RESULT"
plutil -insert hardware -string "$(sysctl -n machdep.cpu.brand_string)" "$RESULT"
plutil -insert operatingSystem -string "$(sw_vers -productVersion)" "$RESULT"
plutil -insert configuration -string "release" "$RESULT"
plutil -insert model -string "mock" "$RESULT"
plutil -insert metrics -json "{\"cycles\":500,\"harness_elapsed_seconds\":$ELAPSED_SECONDS}" "$RESULT"
plutil -convert json "$RESULT"

echo "$RESULT"
