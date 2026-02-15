#!/bin/bash
# Test helper for install_printer.sh tests.
# Sources functions from the main script without executing main().
# Provides mock utilities for system commands.

# Absolute path to the project root
export PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SCRIPT="$PROJECT_ROOT/install_printer.sh"

# Create a temporary directory for test artifacts
setup_test_tmpdir() {
    TEST_TMPDIR=$(mktemp -d)
    export TEST_TMPDIR
}

teardown_test_tmpdir() {
    [[ -d "$TEST_TMPDIR" ]] && rm -rf "$TEST_TMPDIR"
}

# Source only the functions from install_printer.sh without running main().
# We do this by extracting everything before the final "main" call.
source_functions() {
    # Disable set -e and the main call when sourcing
    local tmp_script
    tmp_script=$(mktemp)
    # Remove 'set -e', the final 'main' call, and any 'exit' calls
    sed -e 's/^set -e/# set -e (disabled for testing)/' \
        -e '/^[[:space:]]*main\([[:space:]]\|$\)/d' \
        "$SCRIPT" > "$tmp_script"
    # shellcheck disable=SC1090
    source "$tmp_script"
    rm -f "$tmp_script"
}
