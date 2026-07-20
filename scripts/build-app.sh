#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
APP_PATH="$ROOT/dist/Vani.app"
BUILD_ROOT="$ROOT/.build"
mkdir -p "$BUILD_ROOT"
STAGING_ROOT="$(mktemp -d "$BUILD_ROOT/vani-app.XXXXXX")"
STAGING_APP="$STAGING_ROOT/Vani.app"
LOCAL_SIGNING_IDENTITY="Vani Local Development"
if [[ -n "${CODESIGN_IDENTITY+x}" ]]; then
    IDENTITY="$CODESIGN_IDENTITY"
elif security find-identity -v -p codesigning 2>/dev/null \
    | grep -Fq "\"$LOCAL_SIGNING_IDENTITY\""; then
    IDENTITY="$LOCAL_SIGNING_IDENTITY"
else
    IDENTITY="-"
fi
DEFAULT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
DEFAULT_BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/Resources/Info.plist")"
VERSION="${VERSION:-$DEFAULT_VERSION}"
BUILD_NUMBER="${BUILD_NUMBER:-$DEFAULT_BUILD_NUMBER}"

if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    echo "error: VERSION must contain one to three numeric components." >&2
    exit 1
fi
if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
    echo "error: BUILD_NUMBER must be numeric." >&2
    exit 1
fi

cleanup() {
    if [[ -d "$STAGING_ROOT" ]]; then
        find "$STAGING_ROOT" -depth -delete
    fi
}
trap cleanup EXIT

if [[ "$(uname -m)" != "arm64" ]]; then
    echo "error: Vani v1 requires an Apple Silicon Mac." >&2
    exit 1
fi

cd "$ROOT"
swift build -c "$CONFIGURATION" --arch arm64
BIN_PATH="$(swift build -c "$CONFIGURATION" --arch arm64 --show-bin-path)"

mkdir -p "$STAGING_APP/Contents/MacOS" "$STAGING_APP/Contents/Resources"
install -m 0755 "$BIN_PATH/Vani" "$STAGING_APP/Contents/MacOS/Vani"
install -m 0644 "$ROOT/Resources/Info.plist" "$STAGING_APP/Contents/Info.plist"
install -m 0644 "$ROOT/Resources/AppIcon.icns" "$STAGING_APP/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$STAGING_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$STAGING_APP/Contents/Info.plist"

if [[ "$IDENTITY" == "-" ]]; then
    codesign \
        --force \
        --sign - \
        --options runtime \
        --entitlements "$ROOT/Resources/Vani.entitlements" \
        "$STAGING_APP"
else
    SIGNING_ARGUMENTS=(
        --force \
        --sign "$IDENTITY" \
        --options runtime \
        --entitlements "$ROOT/Resources/Vani.entitlements" \
    )
    if [[ "${CODESIGN_TIMESTAMP:-auto}" == "1" \
        || ( "${CODESIGN_TIMESTAMP:-auto}" == "auto" \
            && "$IDENTITY" == Developer\ ID\ Application* ) ]]; then
        SIGNING_ARGUMENTS+=(--timestamp)
    fi
    codesign "${SIGNING_ARGUMENTS[@]}" "$STAGING_APP"
fi

codesign --verify --deep --strict --verbose=2 "$STAGING_APP"
plutil -lint "$STAGING_APP/Contents/Info.plist"

mkdir -p "$ROOT/dist"
if [[ -e "$APP_PATH" ]]; then
    find "$APP_PATH" -depth -delete
fi
mv "$STAGING_APP" "$APP_PATH"

echo "$APP_PATH"
