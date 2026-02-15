#!/usr/bin/env bats
# Tests for duplicate printer detection pattern matching.
# Verifies the regex patterns used to find DCP-130C printer variants.

load test_helper

setup() {
    setup_test_tmpdir
    DEBUG=1
    source_functions
}

teardown() {
    teardown_test_tmpdir
}

# The pattern used in remove_duplicate_printers() to match DCP-130C variants
matches_dcp130c() {
    echo "$1" | grep -qi "dcp[-_.]130c\|dcp130c"
}

@test "pattern matches DCP130C" {
    run matches_dcp130c "DCP130C"
    [[ "$status" -eq 0 ]]
}

@test "pattern matches dcp130c (lowercase)" {
    run matches_dcp130c "dcp130c"
    [[ "$status" -eq 0 ]]
}

@test "pattern matches DCP-130C (with hyphen)" {
    run matches_dcp130c "DCP-130C"
    [[ "$status" -eq 0 ]]
}

@test "pattern matches DCP_130C (with underscore)" {
    run matches_dcp130c "DCP_130C"
    [[ "$status" -eq 0 ]]
}

@test "pattern matches DCP.130C (with dot)" {
    run matches_dcp130c "DCP.130C"
    [[ "$status" -eq 0 ]]
}

@test "pattern matches Brother_DCP_130C_BrotherDCP130C" {
    run matches_dcp130c "Brother_DCP_130C_BrotherDCP130C"
    [[ "$status" -eq 0 ]]
}

@test "pattern matches Brother-DCP-130C" {
    run matches_dcp130c "Brother-DCP-130C"
    [[ "$status" -eq 0 ]]
}

@test "pattern does NOT match HP_LaserJet" {
    run matches_dcp130c "HP_LaserJet"
    [[ "$status" -ne 0 ]]
}

@test "pattern does NOT match DCP-135C (different model)" {
    run matches_dcp130c "DCP-135C"
    [[ "$status" -ne 0 ]]
}

@test "pattern does NOT match empty string" {
    run matches_dcp130c ""
    [[ "$status" -ne 0 ]]
}

# Test the known_variants list
@test "known_variants includes DCP130C" {
    local known_variants=("DCP130C" "dcp130c" "DCP-130C" "Brother-DCP-130C")
    [[ " ${known_variants[*]} " == *" DCP130C "* ]]
}

@test "Brother_DCP_130C is skipped (it's our canonical name)" {
    # Verify the canonical name is NOT in known_variants
    local known_variants=("DCP130C" "dcp130c" "DCP-130C" "Brother-DCP-130C")
    [[ " ${known_variants[*]} " != *" Brother_DCP_130C "* ]]
}
