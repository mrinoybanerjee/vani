#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_ROOT="${INSTALL_ROOT:-/Applications}"
SOURCE_APP="$ROOT/dist/Vani.app"
DESTINATION_APP="$INSTALL_ROOT/Vani.app"
STAGING_APP="$INSTALL_ROOT/.Vani.installing.$$.app"

cleanup() {
    if [[ -e "$STAGING_APP" ]]; then
        find "$STAGING_APP" -depth -delete
    fi
}
trap cleanup EXIT

CONFIGURATION=release "$ROOT/scripts/build-app.sh"

if pgrep -x Vani >/dev/null 2>&1; then
    osascript -e 'tell application id "com.mrinoy.vani" to quit' >/dev/null 2>&1 || true
    sleep 1
fi

mkdir -p "$INSTALL_ROOT"
ditto "$SOURCE_APP" "$STAGING_APP"
codesign --verify --deep --strict --verbose=2 "$STAGING_APP"

if [[ -e "$DESTINATION_APP" ]]; then
    find "$DESTINATION_APP" -depth -delete
fi
mv "$STAGING_APP" "$DESTINATION_APP"
open "$DESTINATION_APP"

echo "$DESTINATION_APP"
