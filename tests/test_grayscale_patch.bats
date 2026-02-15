#!/usr/bin/env bats
# Tests for the grayscale filter patch (BRMonoColor translation).
# Verifies the sed injection correctly translates ColorModel=Gray to
# BRMonoColor=BrMono in the Brother filter script.

load test_helper

setup() {
    setup_test_tmpdir
    DEBUG=1
    source_functions
}

teardown() {
    teardown_test_tmpdir
}

# Create a minimal mock Brother filter script
create_mock_filter() {
    cat > "$TEST_TMPDIR/brlpdwrapperdcp130c" << 'EOF'
#!/bin/bash
# Mock Brother filter
echo "OPTIONS=$5"
echo "FILE=$6"
EOF
    chmod 755 "$TEST_TMPDIR/brlpdwrapperdcp130c"
}

# Apply the same sed patch that install_printer.sh uses
apply_grayscale_patch() {
    local filter="$1"
    sed -i '1 a\
# --- Grayscale patch: translate CUPS ColorModel to Brother BRMonoColor ---\
# CUPS maps IPP print-color-mode=monochrome to ColorModel=Gray,\
# but the Brother driver reads BRMonoColor instead of ColorModel.\
case "$5" in\
  *ColorModel=Gray*|*print-color-mode=monochrome*)\
    set -- "$1" "$2" "$3" "$4" "$(echo "$5" | sed '\''s/BRMonoColor=BrColor/BRMonoColor=BrMono/g'\'') BRMonoColor=BrMono" "$6"\
    ;;\
esac\
# --- End grayscale patch ---' "$filter"
}

@test "grayscale patch adds BRMonoColor=BrMono for ColorModel=Gray" {
    create_mock_filter
    apply_grayscale_patch "$TEST_TMPDIR/brlpdwrapperdcp130c"

    run bash "$TEST_TMPDIR/brlpdwrapperdcp130c" job1 user1 title1 1 \
        "ColorModel=Gray BRMonoColor=BrColor media=a4" input.pdf
    [[ "$output" == *"BRMonoColor=BrMono"* ]]
}

@test "grayscale patch adds BRMonoColor=BrMono for print-color-mode=monochrome" {
    create_mock_filter
    apply_grayscale_patch "$TEST_TMPDIR/brlpdwrapperdcp130c"

    run bash "$TEST_TMPDIR/brlpdwrapperdcp130c" job1 user1 title1 1 \
        "print-color-mode=monochrome media=a4" input.pdf
    [[ "$output" == *"BRMonoColor=BrMono"* ]]
}

@test "grayscale patch does NOT modify color mode options" {
    create_mock_filter
    apply_grayscale_patch "$TEST_TMPDIR/brlpdwrapperdcp130c"

    run bash "$TEST_TMPDIR/brlpdwrapperdcp130c" job1 user1 title1 1 \
        "ColorModel=RGB BRMonoColor=BrColor media=a4" input.pdf
    [[ "$output" == *"BRMonoColor=BrColor"* ]]
    [[ "$output" != *"BRMonoColor=BrMono"* ]]
}

@test "grayscale patch replaces BrColor with BrMono in existing options" {
    create_mock_filter
    apply_grayscale_patch "$TEST_TMPDIR/brlpdwrapperdcp130c"

    run bash "$TEST_TMPDIR/brlpdwrapperdcp130c" job1 user1 title1 1 \
        "ColorModel=Gray BRMonoColor=BrColor" input.pdf
    # BrColor should be replaced with BrMono
    [[ "$output" != *"BRMonoColor=BrColor"* ]]
    [[ "$output" == *"BRMonoColor=BrMono"* ]]
}

@test "grayscale patch adds BRMonoColor even when not in original options" {
    create_mock_filter
    apply_grayscale_patch "$TEST_TMPDIR/brlpdwrapperdcp130c"

    run bash "$TEST_TMPDIR/brlpdwrapperdcp130c" job1 user1 title1 1 \
        "ColorModel=Gray media=a4" input.pdf
    [[ "$output" == *"BRMonoColor=BrMono"* ]]
}

@test "grayscale patch preserves file argument ($6)" {
    create_mock_filter
    apply_grayscale_patch "$TEST_TMPDIR/brlpdwrapperdcp130c"

    run bash "$TEST_TMPDIR/brlpdwrapperdcp130c" job1 user1 title1 1 \
        "ColorModel=Gray" "/tmp/myfile.ps"
    [[ "$output" == *"FILE=/tmp/myfile.ps"* ]]
}

@test "patched script has valid bash syntax" {
    create_mock_filter
    apply_grayscale_patch "$TEST_TMPDIR/brlpdwrapperdcp130c"
    run bash -n "$TEST_TMPDIR/brlpdwrapperdcp130c"
    [[ "$status" -eq 0 ]]
}

@test "patch is idempotent (skipped if BRMonoColor already present)" {
    create_mock_filter
    apply_grayscale_patch "$TEST_TMPDIR/brlpdwrapperdcp130c"

    # The grep -q 'BRMonoColor' check in install_printer.sh prevents re-patching
    if ! grep -q 'BRMonoColor' "$TEST_TMPDIR/brlpdwrapperdcp130c"; then
        apply_grayscale_patch "$TEST_TMPDIR/brlpdwrapperdcp130c"
    fi
    # Count patch headers — should be exactly one
    count=$(grep -c -F -- '--- Grayscale patch' "$TEST_TMPDIR/brlpdwrapperdcp130c")
    [[ "$count" -eq 1 ]]
}
