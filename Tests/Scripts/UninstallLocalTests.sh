#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vani-uninstall-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/install/Vani.app"

# Every process-control or destructive command is replaced; the installed app and
# the user's support directory are never modified by this test.
cat > "$TEST_ROOT/bin/shim" <<'SHIM'
#!/bin/bash
set -euo pipefail
command_name="${0##*/}"
case "$command_name" in
    osascript|sleep) exit 0 ;;
    pgrep)
        count="$(cat "$VANI_UNINSTALL_TEST_COUNTER")"
        count=$((count + 1))
        printf '%s' "$count" > "$VANI_UNINSTALL_TEST_COUNTER"
        if [[ "$VANI_UNINSTALL_TEST_MODE" == refused ]] || ((count < 3)); then
            exit 0
        fi
        exit 1
        ;;
    find|defaults|tccutil|pkill)
        printf '%s\n' "$command_name" >> "$VANI_UNINSTALL_TEST_JOURNAL"
        ;;
    *) exit 99 ;;
esac
SHIM
chmod +x "$TEST_ROOT/bin/shim"
for command_name in osascript sleep pgrep find defaults tccutil pkill; do
    ln -s shim "$TEST_ROOT/bin/$command_name"
done

run_case() {
    local mode="$1"
    printf '0' > "$TEST_ROOT/counter"
    : > "$TEST_ROOT/journal"
    PATH="$TEST_ROOT/bin:$PATH" INSTALL_ROOT="$TEST_ROOT/install" \
        VANI_UNINSTALL_TEST_MODE="$mode" \
        VANI_UNINSTALL_TEST_COUNTER="$TEST_ROOT/counter" \
        VANI_UNINSTALL_TEST_JOURNAL="$TEST_ROOT/journal" \
        bash "$ROOT/scripts/uninstall-local.sh" > "$TEST_ROOT/output" 2>&1
}

if run_case refused; then
    echo 'FAIL: uninstall continued after Vani refused to quit.' >&2
    exit 1
fi
if [[ -s "$TEST_ROOT/journal" ]]; then
    echo 'FAIL: uninstall changed state before Vani finished quitting.' >&2
    exit 1
fi
if [[ "$(cat "$TEST_ROOT/output")" != *'Vani is still running'* ]]; then
    echo 'FAIL: refused quit did not explain how to retry.' >&2
    exit 1
fi

run_case delayed
if [[ "$(cat "$TEST_ROOT/counter")" != 3 ]]; then
    echo 'FAIL: uninstall did not wait for delayed shutdown.' >&2
    exit 1
fi
journal="$(cat "$TEST_ROOT/journal")"
if [[ "$journal" != *find* || "$journal" != *tccutil* || "$journal" == *pkill* ]]; then
    echo 'FAIL: uninstall did not clean up after graceful shutdown.' >&2
    exit 1
fi
echo 'Uninstall graceful-shutdown tests passed.'
