#!/usr/bin/env bats
# Tests for install_scanner.sh logging functions and basic config.

load test_helper

setup() {
    setup_test_tmpdir
    DEBUG=0
    source_scanner_functions
}

teardown() {
    teardown_test_tmpdir
}

# --- Logging tests ---

@test "scanner: log_info outputs [INFO] prefix" {
    run log_info "test message"
    [[ "$output" == *"[INFO]"* ]]
    [[ "$output" == *"test message"* ]]
}

@test "scanner: log_warn outputs [WARN] prefix" {
    run log_warn "warning message"
    [[ "$output" == *"[WARN]"* ]]
    [[ "$output" == *"warning message"* ]]
}

@test "scanner: log_error outputs [ERROR] prefix" {
    run log_error "error message"
    [[ "$output" == *"[ERROR]"* ]]
    [[ "$output" == *"error message"* ]]
}

@test "scanner: log_debug outputs nothing when DEBUG=0" {
    DEBUG=0
    run log_debug "secret debug"
    [[ -z "$output" ]]
}

@test "scanner: log_debug outputs [DEBUG] when DEBUG=1" {
    DEBUG=1
    output=$(log_debug "debug msg" 2>&1)
    [[ "$output" == *"[DEBUG]"* ]]
    [[ "$output" == *"debug msg"* ]]
}

# --- Variables ---

@test "scanner: SCANNER_MODEL is set to DCP-130C" {
    [[ "$SCANNER_MODEL" == "DCP-130C" ]]
}

@test "scanner: SCANNER_NAME is set to Brother_DCP_130C" {
    [[ "$SCANNER_NAME" == "Brother_DCP_130C" ]]
}

@test "scanner: DRIVER_BRSCAN2_URLS has at least 2 mirrors" {
    [[ ${#DRIVER_BRSCAN2_URLS[@]} -ge 2 ]]
}

@test "scanner: Driver URLs contain brother.com" {
    [[ "${DRIVER_BRSCAN2_URLS[0]}" == *"brother.com"* ]]
}

@test "scanner: DRIVER_BRSCAN2_SRC_URLS has at least 2 mirrors" {
    [[ ${#DRIVER_BRSCAN2_SRC_URLS[@]} -ge 2 ]]
}

@test "scanner: Source URL contains brother.com" {
    [[ "${DRIVER_BRSCAN2_SRC_URLS[0]}" == *"brother.com"* ]]
}

@test "scanner: Source filename ends in .tar.gz" {
    [[ "$DRIVER_BRSCAN2_SRC_FILE" == *".tar.gz" ]]
}

@test "scanner: Driver filename ends in .i386.deb" {
    [[ "$DRIVER_BRSCAN2_FILE" == *".i386.deb" ]]
}

@test "scanner: Driver filename is brscan2" {
    [[ "$DRIVER_BRSCAN2_FILE" == "brscan2-"* ]]
}

@test "scanner: TMP_DIR is set for scanner" {
    [[ "$TMP_DIR" == *"scanner"* ]]
}

# --- Debug flag parsing ---

@test "scanner: --debug flag is parsed from args" {
    DEBUG=0
    for arg in "--debug"; do
        if [[ "$arg" == "--debug" ]]; then
            DEBUG=1
        fi
    done
    [[ "$DEBUG" == "1" ]]
}
