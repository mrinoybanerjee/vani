#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_ROOT="${INSTALL_ROOT:-/Applications}"
SOURCE_APP="$ROOT/dist/Vani.app"
DESTINATION_APP="$INSTALL_ROOT/Vani.app"
STAGING_ROOT=""
STAGING_APP=""
BACKUP_ROOT=""
BACKUP_APP=""

cleanup() {
    if [[ -n "$STAGING_ROOT" && -e "$STAGING_ROOT" ]]; then
        find "$STAGING_ROOT" -depth -delete
    fi
    if [[ -n "$BACKUP_ROOT" && -d "$BACKUP_ROOT" ]]; then
        rmdir "$BACKUP_ROOT" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

INSTALL_ROOT="$INSTALL_ROOT" "$ROOT/scripts/doctor.sh"
printf '\nBuilding a release-mode Vani app. The first source build can take several minutes.\n'
CONFIGURATION=release "$ROOT/scripts/build-app.sh"

if pgrep -x Vani >/dev/null 2>&1; then
    osascript -e 'tell application id "com.mrinoy.vani" to quit' >/dev/null 2>&1 || true
    sleep 1
fi

mkdir -p "$INSTALL_ROOT"
STAGING_ROOT="$(mktemp -d "$INSTALL_ROOT/.Vani.installing.XXXXXX")"
STAGING_APP="$STAGING_ROOT/Vani.app"
ditto "$SOURCE_APP" "$STAGING_APP"
codesign --verify --deep --strict --verbose=2 "$STAGING_APP"

if [[ -e "$DESTINATION_APP" ]]; then
    BACKUP_ROOT="$(mktemp -d "$INSTALL_ROOT/.Vani.previous.XXXXXX")"
    BACKUP_APP="$BACKUP_ROOT/Vani.app"
    mv "$DESTINATION_APP" "$BACKUP_APP"
fi
if ! mv "$STAGING_APP" "$DESTINATION_APP"; then
    if [[ -e "$BACKUP_APP" && ! -e "$DESTINATION_APP" ]]; then
        if mv "$BACKUP_APP" "$DESTINATION_APP"; then
            echo "error: Vani installation failed; the previous app was restored." >&2
        else
            echo "error: Vani installation and automatic restore failed; the previous app remains at $BACKUP_APP." >&2
        fi
    else
        echo "error: Vani installation failed." >&2
    fi
    exit 1
fi

if [[ -e "$BACKUP_APP" ]]; then
    find "$BACKUP_APP" -depth -delete
fi
if [[ -n "$BACKUP_ROOT" ]]; then
    rmdir "$BACKUP_ROOT"
    BACKUP_ROOT=""
fi
if [[ -d "$STAGING_ROOT" ]]; then
    rmdir "$STAGING_ROOT"
    STAGING_ROOT=""
fi

if [[ "${VANI_SKIP_OPEN:-0}" == "1" ]]; then
    printf 'Skipped launch because VANI_SKIP_OPEN=1.\n'
else
    open "$DESTINATION_APP"
fi

printf '\nInstalled Vani at %s\n\n' "$DESTINATION_APP"
printf '%s\n' \
    'Next steps:' \
    '1. Open Vani from the menu bar.' \
    '2. Allow Microphone, Accessibility, and Input Monitoring access.' \
    '3. Download the verified 443 MiB English speech model.' \
    '4. In System Settings > Keyboard, set "Press Globe key to" to "Do Nothing".' \
    '5. Hold Left Fn, speak, then release to insert text.'

if ! codesign -dv --verbose=4 "$DESTINATION_APP" 2>&1 \
    | grep -F 'Authority=Vani Local Development' >/dev/null; then
    printf '\nNote: this app is ad-hoc signed. It works locally, but rebuilding can require fresh macOS permission grants.\n'
    printf 'See docs/BUILDING.md#stable-local-signing for the optional stable identity.\n'
fi
