#!/usr/bin/env bats
# Tests for scanner driver extraction and modification logic.
# Verifies Architecture changes in control file.

load test_helper

setup() {
    setup_test_tmpdir
    DEBUG=1
    source_scanner_functions
}

teardown() {
    teardown_test_tmpdir
}

# --- Architecture modification ---

@test "scanner: sed changes Architecture: i386 to Architecture: all" {
    echo "Architecture: i386" > "$TEST_TMPDIR/control"
    sed -i 's/Architecture: .*/Architecture: all/' "$TEST_TMPDIR/control"
    run grep 'Architecture: all' "$TEST_TMPDIR/control"
    [[ "$status" -eq 0 ]]
}

@test "scanner: sed preserves other control fields" {
    cat > "$TEST_TMPDIR/control" << 'EOF'
Package: brscan2
Version: 0.2.5-1
Architecture: i386
Description: Brother Scanner Driver
Provides: brscan
EOF
    sed -i 's/Architecture: .*/Architecture: all/' "$TEST_TMPDIR/control"
    run grep 'Package: brscan2' "$TEST_TMPDIR/control"
    [[ "$status" -eq 0 ]]
    run grep 'Version: 0.2.5-1' "$TEST_TMPDIR/control"
    [[ "$status" -eq 0 ]]
    run grep 'Provides: brscan' "$TEST_TMPDIR/control"
    [[ "$status" -eq 0 ]]
    run grep 'Description: Brother Scanner Driver' "$TEST_TMPDIR/control"
    [[ "$status" -eq 0 ]]
}

# --- SANE dll.conf configuration ---

@test "scanner: brother2 is added to dll.conf when missing" {
    cat > "$TEST_TMPDIR/dll.conf" << 'EOF'
net
snmp
EOF
    if ! grep -q '^brother2$' "$TEST_TMPDIR/dll.conf"; then
        echo "brother2" >> "$TEST_TMPDIR/dll.conf"
    fi
    run grep '^brother2$' "$TEST_TMPDIR/dll.conf"
    [[ "$status" -eq 0 ]]
}

@test "scanner: brother2 addition is idempotent" {
    cat > "$TEST_TMPDIR/dll.conf" << 'EOF'
net
brother2
snmp
EOF
    if ! grep -q '^brother2$' "$TEST_TMPDIR/dll.conf"; then
        echo "brother2" >> "$TEST_TMPDIR/dll.conf"
    fi
    count=$(grep -c '^brother2$' "$TEST_TMPDIR/dll.conf")
    [[ "$count" -eq 1 ]]
}

@test "scanner: brother2 preserves existing entries in dll.conf" {
    cat > "$TEST_TMPDIR/dll.conf" << 'EOF'
net
snmp
EOF
    echo "brother2" >> "$TEST_TMPDIR/dll.conf"
    run grep '^net$' "$TEST_TMPDIR/dll.conf"
    [[ "$status" -eq 0 ]]
    run grep '^snmp$' "$TEST_TMPDIR/dll.conf"
    [[ "$status" -eq 0 ]]
}
