#!/usr/bin/env bats
# Tests for patch_lpadmin_calls() function.
# Verifies that lpadmin invocations in scripts are correctly commented out.

load test_helper

setup() {
    setup_test_tmpdir
    DEBUG=1
    source_functions
}

teardown() {
    teardown_test_tmpdir
}

@test "patch_lpadmin_calls comments out bare lpadmin call" {
    cat > "$TEST_TMPDIR/script.sh" << 'EOF'
#!/bin/bash
lpadmin -p DCP130C -E
echo "done"
EOF
    patch_lpadmin_calls "$TEST_TMPDIR/script.sh" 2>/dev/null
    # The lpadmin line should be commented out
    run grep '# \[patched\]' "$TEST_TMPDIR/script.sh"
    [[ "$status" -eq 0 ]]
    # The echo line should be unchanged
    run grep '^echo "done"' "$TEST_TMPDIR/script.sh"
    [[ "$status" -eq 0 ]]
}

@test "patch_lpadmin_calls comments out /usr/sbin/lpadmin" {
    cat > "$TEST_TMPDIR/script.sh" << 'EOF'
#!/bin/bash
/usr/sbin/lpadmin -p DCP130C -v usb://Brother
EOF
    patch_lpadmin_calls "$TEST_TMPDIR/script.sh" 2>/dev/null
    run grep '# \[patched\]' "$TEST_TMPDIR/script.sh"
    [[ "$status" -eq 0 ]]
    run grep '# \[patched\].*lpadmin' "$TEST_TMPDIR/script.sh"
    [[ "$status" -eq 0 ]]
}

@test "patch_lpadmin_calls handles backtick lpadmin" {
    cat > "$TEST_TMPDIR/script.sh" << 'EOF'
#!/bin/bash
result=`lpadmin -p DCP130C`
EOF
    patch_lpadmin_calls "$TEST_TMPDIR/script.sh" 2>/dev/null
    run grep '# \[patched\]' "$TEST_TMPDIR/script.sh"
    [[ "$status" -eq 0 ]]
}

@test "patch_lpadmin_calls preserves already-commented lines" {
    cat > "$TEST_TMPDIR/script.sh" << 'EOF'
#!/bin/bash
# lpadmin -p OldPrinter -E
lpadmin -p DCP130C -E
EOF
    patch_lpadmin_calls "$TEST_TMPDIR/script.sh" 2>/dev/null
    # Count patched lines (only one should be patched)
    count=$(grep -c '# \[patched\]' "$TEST_TMPDIR/script.sh")
    [[ "$count" -eq 1 ]]
    # Original comment should be unchanged
    run grep '^# lpadmin -p OldPrinter' "$TEST_TMPDIR/script.sh"
    [[ "$status" -eq 0 ]]
}

@test "patch_lpadmin_calls skips file without lpadmin" {
    cat > "$TEST_TMPDIR/script.sh" << 'EOF'
#!/bin/bash
echo "no admin here"
EOF
    patch_lpadmin_calls "$TEST_TMPDIR/script.sh" 2>/dev/null
    # File should be unchanged
    run grep '# \[patched\]' "$TEST_TMPDIR/script.sh"
    [[ "$status" -ne 0 ]]
}

@test "patch_lpadmin_calls handles indented lpadmin" {
    cat > "$TEST_TMPDIR/script.sh" << 'EOF'
#!/bin/bash
if true; then
    lpadmin -p DCP130C -E
fi
EOF
    patch_lpadmin_calls "$TEST_TMPDIR/script.sh" 2>/dev/null
    run grep '# \[patched\]' "$TEST_TMPDIR/script.sh"
    [[ "$status" -eq 0 ]]
}

@test "patch_lpadmin_calls handles multiple lpadmin calls" {
    cat > "$TEST_TMPDIR/script.sh" << 'EOF'
#!/bin/bash
lpadmin -p Printer1 -E
echo "middle"
/usr/sbin/lpadmin -x Printer2
EOF
    patch_lpadmin_calls "$TEST_TMPDIR/script.sh" 2>/dev/null
    count=$(grep -c '# \[patched\]' "$TEST_TMPDIR/script.sh")
    [[ "$count" -eq 2 ]]
    # echo line should be preserved
    run grep '^echo "middle"' "$TEST_TMPDIR/script.sh"
    [[ "$status" -eq 0 ]]
}
