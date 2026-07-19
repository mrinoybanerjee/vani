#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULTS_DIR="$ROOT/.build/benchmarks"
RESULT="$RESULTS_DIR/latest.json"
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
START_SECONDS="$(date +%s)"

mkdir -p "$RESULTS_DIR"
cd "$ROOT"
swift test -c release --filter fiveHundredSequentialDictationsRemainReadyAndBoundDiagnostics
ELAPSED_SECONDS="$(( $(date +%s) - START_SECONDS ))"

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
