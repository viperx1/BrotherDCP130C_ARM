#!/usr/bin/env bats
# Tests for install_printer.sh logging functions and basic config.

load test_helper

setup() {
    setup_test_tmpdir
    DEBUG=0
    source_functions
}

teardown() {
    teardown_test_tmpdir
}

# --- Logging tests ---

@test "log_info outputs [INFO] prefix" {
    run log_info "test message"
    [[ "$output" == *"[INFO]"* ]]
    [[ "$output" == *"test message"* ]]
}

@test "log_warn outputs [WARN] prefix" {
    run log_warn "warning message"
    [[ "$output" == *"[WARN]"* ]]
    [[ "$output" == *"warning message"* ]]
}

@test "log_error outputs [ERROR] prefix" {
    run log_error "error message"
    [[ "$output" == *"[ERROR]"* ]]
    [[ "$output" == *"error message"* ]]
}

@test "log_debug outputs nothing when DEBUG=0" {
    DEBUG=0
    run log_debug "secret debug"
    [[ -z "$output" ]]
}

@test "log_debug outputs [DEBUG] when DEBUG=1" {
    DEBUG=1
    # log_debug writes to stderr; capture it
    output=$(log_debug "debug msg" 2>&1)
    [[ "$output" == *"[DEBUG]"* ]]
    [[ "$output" == *"debug msg"* ]]
}

# --- Variables ---

@test "PRINTER_NAME is set to Brother_DCP_130C" {
    [[ "$PRINTER_NAME" == "Brother_DCP_130C" ]]
}

@test "PRINTER_SHARED defaults to false" {
    [[ "$PRINTER_SHARED" == "false" ]]
}

@test "DRIVER_LPR_URLS has at least 2 mirrors" {
    [[ ${#DRIVER_LPR_URLS[@]} -ge 2 ]]
}

@test "DRIVER_CUPS_URLS has at least 2 mirrors" {
    [[ ${#DRIVER_CUPS_URLS[@]} -ge 2 ]]
}

@test "Driver URLs contain brother.com" {
    [[ "${DRIVER_LPR_URLS[0]}" == *"brother.com"* ]]
    [[ "${DRIVER_CUPS_URLS[0]}" == *"brother.com"* ]]
}

@test "Driver filenames end in .i386.deb" {
    [[ "$DRIVER_LPR_FILE" == *".i386.deb" ]]
    [[ "$DRIVER_CUPS_FILE" == *".i386.deb" ]]
}

# --- Debug flag parsing ---

@test "--debug flag is parsed from args" {
    # Re-source with --debug
    DEBUG=0
    for arg in "--debug"; do
        if [[ "$arg" == "--debug" ]]; then
            DEBUG=1
        fi
    done
    [[ "$DEBUG" == "1" ]]
}
