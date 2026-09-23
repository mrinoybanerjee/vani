#!/bin/bash

set -euo pipefail

INSTALL_ROOT="${INSTALL_ROOT:-/Applications}"
REMOVE_MODEL=0
DRY_RUN=0

usage() {
    cat <<'EOF'
Usage: ./scripts/uninstall-local.sh [--remove-model] [--dry-run]

  --remove-model  Also remove Vani's shared FluidAudio speech models (443 MiB, plus the
                  optional 98 MiB vocabulary model if it was downloaded).
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
VOCABULARY_MODEL_PATH="$HOME/Library/Application Support/FluidAudio/Models/parakeet-ctc-110m-coreml"

remove_path() {
    local path="$1"
    if ((DRY_RUN)); then
        printf '[dry-run] remove %s\n' "$path"
    elif [[ -e "$path" ]]; then
        find "$path" -depth -delete
        printf 'Removed %s\n' "$path"
    fi
}

wait_for_vani_exit() {
    local attempt
    for attempt in {1..20}; do
        if ! pgrep -x Vani >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.25
    done
    return 1
}

if ((DRY_RUN)); then
    printf '[dry-run] quit Vani\n'
else
    osascript -e 'tell application id "com.mrinoy.vani" to quit' >/dev/null 2>&1 || true
    if ! wait_for_vani_exit; then
        echo "error: Vani is still running. Stop any meeting, save unfinished notes, quit Vani, then retry uninstalling. No files or permissions were removed." >&2
        exit 1
    fi
fi

remove_path "$APP_PATH"
remove_path "$SUPPORT_PATH"
remove_path "$CACHE_PATH"
remove_path "$PREFERENCES_PATH"
remove_path "$SAVED_STATE_PATH"

if ((DRY_RUN)); then
    printf '[dry-run] delete defaults domain com.mrinoy.vani\n'
    printf '[dry-run] reset Microphone, Accessibility, Input Monitoring, and Screen Recording for com.mrinoy.vani\n'
else
    defaults delete com.mrinoy.vani >/dev/null 2>&1 || true
    tccutil reset Microphone com.mrinoy.vani >/dev/null 2>&1 || true
    tccutil reset Accessibility com.mrinoy.vani >/dev/null 2>&1 || true
    tccutil reset ListenEvent com.mrinoy.vani >/dev/null 2>&1 || true
    tccutil reset ScreenCapture com.mrinoy.vani >/dev/null 2>&1 || true
fi

if ((REMOVE_MODEL)); then
    remove_path "$MODEL_PATH"
    remove_path "$VOCABULARY_MODEL_PATH"
else
    printf 'Kept shared speech models in %s\n' "$(dirname "$MODEL_PATH")"
fi

if ((DRY_RUN)); then
    printf '\nDry run complete. No files or permissions were changed.\n'
else
    printf '\nVani was removed. The local signing identity and developer tools were left unchanged.\n'
fi
