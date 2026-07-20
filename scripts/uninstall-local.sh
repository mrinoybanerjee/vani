#!/bin/bash

set -euo pipefail

INSTALL_ROOT="${INSTALL_ROOT:-/Applications}"
REMOVE_MODEL=0
DRY_RUN=0

usage() {
    cat <<'EOF'
Usage: ./scripts/uninstall-local.sh [--remove-model] [--dry-run]

  --remove-model  Also remove Vani's shared 443 MiB FluidAudio speech model.
  --dry-run       Print the paths and privacy records without changing them.
EOF
}

for argument in "$@"; do
    case "$argument" in
        --remove-model)
            REMOVE_MODEL=1
            ;;
        --dry-run)
            DRY_RUN=1
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown argument: $argument" >&2
            usage >&2
            exit 2
            ;;
    esac
done

APP_PATH="$INSTALL_ROOT/Vani.app"
SUPPORT_PATH="$HOME/Library/Application Support/Vani"
CACHE_PATH="$HOME/Library/Caches/com.mrinoy.vani"
PREFERENCES_PATH="$HOME/Library/Preferences/com.mrinoy.vani.plist"
SAVED_STATE_PATH="$HOME/Library/Saved Application State/com.mrinoy.vani.savedState"
MODEL_PATH="$HOME/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v2"

remove_path() {
    local path="$1"
    if ((DRY_RUN)); then
        printf '[dry-run] remove %s\n' "$path"
    elif [[ -e "$path" ]]; then
        find "$path" -depth -delete
        printf 'Removed %s\n' "$path"
    fi
}

if ((DRY_RUN)); then
    printf '[dry-run] quit Vani\n'
else
    osascript -e 'tell application id "com.mrinoy.vani" to quit' >/dev/null 2>&1 || true
    sleep 1
    pkill -x Vani >/dev/null 2>&1 || true
fi

remove_path "$APP_PATH"
remove_path "$SUPPORT_PATH"
remove_path "$CACHE_PATH"
remove_path "$PREFERENCES_PATH"
remove_path "$SAVED_STATE_PATH"

if ((DRY_RUN)); then
    printf '[dry-run] delete defaults domain com.mrinoy.vani\n'
    printf '[dry-run] reset Microphone, Accessibility, and Input Monitoring for com.mrinoy.vani\n'
else
    defaults delete com.mrinoy.vani >/dev/null 2>&1 || true
    tccutil reset Microphone com.mrinoy.vani >/dev/null 2>&1 || true
    tccutil reset Accessibility com.mrinoy.vani >/dev/null 2>&1 || true
    tccutil reset ListenEvent com.mrinoy.vani >/dev/null 2>&1 || true
fi

if ((REMOVE_MODEL)); then
    remove_path "$MODEL_PATH"
else
    printf 'Kept shared speech model at %s\n' "$MODEL_PATH"
fi

if ((DRY_RUN)); then
    printf '\nDry run complete. No files or permissions were changed.\n'
else
    printf '\nVani was removed. The local signing identity and developer tools were left unchanged.\n'
fi
