#!/bin/bash

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_ROOT="${INSTALL_ROOT:-/Applications}"
MINIMUM_DISK_KIB=$((3 * 1024 * 1024))
LOCAL_SIGNING_IDENTITY="Vani Local Development"
MODEL_DIRECTORY="$HOME/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v2"
ERROR_COUNT=0
WARNING_COUNT=0

ok() {
    printf '[ok] %s\n' "$1"
}

info() {
    printf '[info] %s\n' "$1"
}

warn() {
    WARNING_COUNT=$((WARNING_COUNT + 1))
    printf '[warn] %s\n' "$1"
}

fail() {
    ERROR_COUNT=$((ERROR_COUNT + 1))
    printf '[error] %s\n' "$1" >&2
}

printf 'Vani setup doctor\n\n'

if [[ "$(uname -s)" == "Darwin" ]]; then
    ok "macOS detected"
else
    fail "Vani v1 requires macOS."
fi

ARCHITECTURE="$(uname -m)"
if [[ "$ARCHITECTURE" == "arm64" ]]; then
    ok "Apple Silicon detected"
else
    fail "Vani v1 requires Apple Silicon; detected $ARCHITECTURE."
fi

if command -v sw_vers >/dev/null 2>&1; then
    MACOS_VERSION="$(sw_vers -productVersion)"
    MACOS_MAJOR="${MACOS_VERSION%%.*}"
    if [[ "$MACOS_MAJOR" =~ ^[0-9]+$ ]] && ((MACOS_MAJOR >= 14)); then
        ok "macOS $MACOS_VERSION"
    else
        fail "Vani requires macOS 14 or newer; detected $MACOS_VERSION."
    fi
else
    fail "Could not read the macOS version with sw_vers."
fi

if command -v git >/dev/null 2>&1; then
    ok "$(git --version)"
else
    fail "Git is missing. Run xcode-select --install, then try again."
fi

if xcode-select -p >/dev/null 2>&1; then
    ok "Apple developer tools are selected"
else
    fail "Apple developer tools are missing. Run xcode-select --install, then try again."
fi

if command -v swift >/dev/null 2>&1; then
    SWIFT_VERSION="$(swift --version 2>/dev/null | head -n 1)"
    SWIFT_MAJOR="$(printf '%s\n' "$SWIFT_VERSION" | sed -nE 's/.*Swift version ([0-9]+).*/\1/p')"
    if [[ "$SWIFT_MAJOR" =~ ^[0-9]+$ ]] && ((SWIFT_MAJOR >= 6)); then
        ok "$SWIFT_VERSION"
    else
        fail "Vani requires Swift 6 or newer; detected ${SWIFT_VERSION:-an unknown version}."
    fi
else
    fail "Swift is missing. Run xcode-select --install, then try again."
fi

AVAILABLE_KIB="$(df -Pk "$ROOT" | awk 'NR == 2 { print $4 }')"
if [[ "$AVAILABLE_KIB" =~ ^[0-9]+$ ]] && ((AVAILABLE_KIB >= MINIMUM_DISK_KIB)); then
    AVAILABLE_GIB="$(awk -v kib="$AVAILABLE_KIB" 'BEGIN { printf "%.1f", kib / 1024 / 1024 }')"
    ok "$AVAILABLE_GIB GiB free disk space"
else
    fail "At least 3 GiB of free disk space is required for source builds and the speech model."
fi

if security find-identity -v -p codesigning 2>/dev/null \
    | grep -F "\"$LOCAL_SIGNING_IDENTITY\"" >/dev/null; then
    ok "Stable local signing identity found"
else
    warn "No '$LOCAL_SIGNING_IDENTITY' identity was found. Installation will work, but rebuilt ad-hoc apps can require fresh permissions. See docs/BUILDING.md."
fi

if [[ -d "$MODEL_DIRECTORY" ]]; then
    MODEL_MIB="$(du -sk "$MODEL_DIRECTORY" | awk '{ printf "%.0f", $1 / 1024 }')"
    info "English speech model present ($MODEL_MIB MiB); Vani verifies its manifest before loading"
else
    info "English speech model is not installed; Vani will offer a verified 443 MiB download"
fi

INSTALLED_APP="$INSTALL_ROOT/Vani.app"
if [[ -d "$INSTALLED_APP" ]]; then
    if codesign --verify --deep --strict "$INSTALLED_APP" >/dev/null 2>&1; then
        ok "Existing $INSTALLED_APP signature is valid"
    else
        warn "Existing $INSTALLED_APP has an invalid signature and will be replaced during installation."
    fi
fi

printf '\n'
if ((ERROR_COUNT > 0)); then
    printf 'Vani is not ready to build: %d error(s), %d warning(s).\n' "$ERROR_COUNT" "$WARNING_COUNT" >&2
    exit 1
fi

printf 'Vani is ready to build with %d warning(s).\n' "$WARNING_COUNT"
