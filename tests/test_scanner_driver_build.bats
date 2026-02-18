#!/usr/bin/env bats
# Integration test: downloads Brother scanner driver, extracts, modifies,
# repackages, and verifies the resulting .deb package is valid and correct.
#
# This test exercises the real build pipeline (download → extract → modify →
# repackage) end-to-end without requiring root, hardware, or SANE.
#
# Network access IS required (downloads ~70 KB from Brother's servers).
# Skip with: SKIP_INTEGRATION=1 bats tests/test_scanner_driver_build.bats

load test_helper

setup() {
    if [[ "${SKIP_INTEGRATION:-0}" == "1" ]]; then
        skip "Integration tests skipped (SKIP_INTEGRATION=1)"
    fi
    setup_test_tmpdir
    DEBUG=1
    source_scanner_functions
}

teardown() {
    teardown_test_tmpdir
}

# Download, extract, modify, and repackage inside $TEST_TMPDIR.
# This replicates the core of download_drivers + extract_and_modify_drivers
# + repackage_drivers without requiring root or SANE.
build_scanner_driver() {
    cd "$TEST_TMPDIR"

    # --- Download ---
    local brscan_ok=0
    for url in "${DRIVER_BRSCAN2_URLS[@]}"; do
        if wget -q --timeout=30 -O brscan2.deb "$url" 2>/dev/null; then
            if file brscan2.deb | grep -qi 'debian\|archive'; then
                brscan_ok=1; break
            fi
        fi
    done
    [[ "$brscan_ok" -eq 1 ]] || { echo "Failed to download brscan2 driver"; return 1; }

    # --- Extract ---
    mkdir -p brscan2_extract
    dpkg-deb -x brscan2.deb brscan2_extract/
    dpkg-deb -e brscan2.deb brscan2_extract/DEBIAN

    # --- Modify (same sed commands as the script) ---
    sed -i 's/Architecture: .*/Architecture: all/' brscan2_extract/DEBIAN/control

    for script in preinst postinst prerm postrm; do
        if [[ -f "brscan2_extract/DEBIAN/$script" ]]; then
            chmod 755 "brscan2_extract/DEBIAN/$script"
        fi
    done

    # --- Repackage ---
    dpkg-deb -b brscan2_extract brscan2_arm.deb
}

# ============================================================
#  Tests
# ============================================================

@test "scanner driver build: downloads and repackages without errors" {
    run build_scanner_driver
    echo "$output"
    [[ "$status" -eq 0 ]]
}

@test "scanner driver build: brscan2 .deb is a valid Debian package" {
    build_scanner_driver 2>/dev/null
    run dpkg-deb --info "$TEST_TMPDIR/brscan2_arm.deb"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Package: brscan2"* ]]
}

@test "scanner driver build: brscan2 package has Architecture: all" {
    build_scanner_driver 2>/dev/null
    run dpkg-deb --info "$TEST_TMPDIR/brscan2_arm.deb"
    [[ "$output" == *"Architecture: all"* ]]
}

@test "scanner driver build: package contains brsaneconfig2 binary" {
    build_scanner_driver 2>/dev/null
    run dpkg-deb --contents "$TEST_TMPDIR/brscan2_arm.deb"
    [[ "$output" == *"brsaneconfig2"* ]]
}

@test "scanner driver build: package contains SANE backend library" {
    build_scanner_driver 2>/dev/null
    run dpkg-deb --contents "$TEST_TMPDIR/brscan2_arm.deb"
    [[ "$output" == *"libsane-brother2"* ]]
}

@test "scanner driver build: package contains Brsane2.ini" {
    build_scanner_driver 2>/dev/null
    run dpkg-deb --contents "$TEST_TMPDIR/brscan2_arm.deb"
    [[ "$output" == *"Brsane2.ini"* ]]
}

@test "scanner driver build: package contains setupSaneScan2" {
    build_scanner_driver 2>/dev/null
    run dpkg-deb --contents "$TEST_TMPDIR/brscan2_arm.deb"
    [[ "$output" == *"setupSaneScan2"* ]]
}

@test "scanner driver build: Brsane2.ini lists DCP-130C" {
    build_scanner_driver 2>/dev/null
    run grep 'DCP-130C' "$TEST_TMPDIR/brscan2_extract/usr/local/Brother/sane/Brsane2.ini"
    [[ "$status" -eq 0 ]]
}

@test "scanner driver build: package provides brscan" {
    build_scanner_driver 2>/dev/null
    run dpkg-deb --info "$TEST_TMPDIR/brscan2_arm.deb"
    [[ "$output" == *"Provides: brscan"* ]]
}

@test "scanner driver build: postinst calls setupSaneScan2" {
    build_scanner_driver 2>/dev/null
    local check_dir="$TEST_TMPDIR/check_brscan2"
    mkdir -p "$check_dir"
    dpkg-deb -e "$TEST_TMPDIR/brscan2_arm.deb" "$check_dir"
    if [[ -f "$check_dir/postinst" ]]; then
        run grep 'setupSaneScan2' "$check_dir/postinst"
        [[ "$status" -eq 0 ]]
    fi
}

@test "scanner driver build: brsaneconfig2 is an i386 ELF binary" {
    build_scanner_driver 2>/dev/null
    local binary
    binary=$(find "$TEST_TMPDIR/brscan2_extract" -name 'brsaneconfig2' -type f | head -1)
    [[ -n "$binary" ]]
    run file "$binary"
    [[ "$output" == *"ELF"* ]]
    [[ "$output" == *"80386"* ]]
}

@test "scanner driver build: SANE library is an i386 shared object" {
    build_scanner_driver 2>/dev/null
    local lib
    lib=$(find "$TEST_TMPDIR/brscan2_extract" -name 'libsane-brother2*' -type f | head -1)
    [[ -n "$lib" ]]
    run file "$lib"
    [[ "$output" == *"ELF"* ]]
    [[ "$output" == *"shared object"* ]]
}
