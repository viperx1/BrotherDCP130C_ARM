#!/usr/bin/env bats
# Integration test: downloads Brother drivers, extracts, modifies, repackages,
# and verifies the resulting .deb packages are valid and correctly patched.
#
# This test exercises the real build pipeline (download → extract → modify →
# repackage) end-to-end without requiring root, hardware, or CUPS.
#
# Network access IS required (downloads ~1.1 MB from Brother's servers).
# Skip with: SKIP_INTEGRATION=1 bats tests/test_driver_build.bats

load test_helper

setup() {
    if [[ "${SKIP_INTEGRATION:-0}" == "1" ]]; then
        skip "Integration tests skipped (SKIP_INTEGRATION=1)"
    fi
    setup_test_tmpdir
    DEBUG=1
    source_functions
}

teardown() {
    teardown_test_tmpdir
}

# Download, extract, modify, and repackage inside $TEST_TMPDIR.
# This replicates the core of download_drivers + extract_and_modify_drivers
# + repackage_drivers without requiring root or CUPS.
build_drivers() {
    cd "$TEST_TMPDIR"

    # --- Download ---
    local lpr_ok=0 cups_ok=0
    for url in "${DRIVER_LPR_URLS[@]}"; do
        if wget -q --timeout=30 -O dcp130clpr.deb "$url" 2>/dev/null; then
            if file dcp130clpr.deb | grep -qi 'debian\|archive'; then
                lpr_ok=1; break
            fi
        fi
    done
    for url in "${DRIVER_CUPS_URLS[@]}"; do
        if wget -q --timeout=30 -O dcp130ccupswrapper.deb "$url" 2>/dev/null; then
            if file dcp130ccupswrapper.deb | grep -qi 'debian\|archive'; then
                cups_ok=1; break
            fi
        fi
    done
    [[ "$lpr_ok" -eq 1 ]] || { echo "Failed to download LPR driver"; return 1; }
    [[ "$cups_ok" -eq 1 ]] || { echo "Failed to download CUPS wrapper"; return 1; }

    # --- Extract ---
    mkdir -p lpr_extract cups_extract
    dpkg-deb -x dcp130clpr.deb lpr_extract/
    dpkg-deb -e dcp130clpr.deb lpr_extract/DEBIAN
    dpkg-deb -x dcp130ccupswrapper.deb cups_extract/
    dpkg-deb -e dcp130ccupswrapper.deb cups_extract/DEBIAN

    # --- Modify (same sed commands as the script) ---
    sed -i 's/Architecture: .*/Architecture: all/' lpr_extract/DEBIAN/control
    sed -i 's/Architecture: .*/Architecture: all/' cups_extract/DEBIAN/control
    sed -i '/^Conflicts: CONFLICT_PACKAGE$/d' cups_extract/DEBIAN/control

    for script_dir in lpr_extract/DEBIAN cups_extract/DEBIAN; do
        for script in preinst postinst prerm postrm; do
            if [[ -f "$script_dir/$script" ]]; then
                sed -i 's|/etc/init.d/lpd|/bin/true|g' "$script_dir/$script"
                if [[ "$script_dir" == "cups_extract/DEBIAN" ]]; then
                    patch_lpadmin_calls "$script_dir/$script"
                fi
                chmod 755 "$script_dir/$script"
            fi
        done
    done

    # Patch cupswrapper script
    local wrapper_script
    wrapper_script=$(find cups_extract/ -name 'cupswrapper*dcp130c*' -type f 2>/dev/null | head -n 1)
    if [[ -n "$wrapper_script" ]]; then
        sed -i 's|/etc/init.d/lpd|/bin/true|g' "$wrapper_script"
        patch_lpadmin_calls "$wrapper_script"
        chmod 755 "$wrapper_script"
    fi

    # --- Repackage ---
    dpkg-deb -b lpr_extract dcp130clpr_arm.deb
    dpkg-deb -b cups_extract dcp130ccupswrapper_arm.deb
}

# ============================================================
#  Tests
# ============================================================

@test "driver build: downloads and repackages without errors" {
    run build_drivers
    echo "$output"
    [[ "$status" -eq 0 ]]
}

@test "driver build: LPR .deb is a valid Debian package" {
    build_drivers 2>/dev/null
    run dpkg-deb --info "$TEST_TMPDIR/dcp130clpr_arm.deb"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Package: dcp130clpr"* ]]
}

@test "driver build: CUPS wrapper .deb is a valid Debian package" {
    build_drivers 2>/dev/null
    run dpkg-deb --info "$TEST_TMPDIR/dcp130ccupswrapper_arm.deb"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Package: dcp130ccupswrapper"* ]]
}

@test "driver build: LPR package has Architecture: all" {
    build_drivers 2>/dev/null
    run dpkg-deb --info "$TEST_TMPDIR/dcp130clpr_arm.deb"
    [[ "$output" == *"Architecture: all"* ]]
}

@test "driver build: CUPS wrapper has Architecture: all" {
    build_drivers 2>/dev/null
    run dpkg-deb --info "$TEST_TMPDIR/dcp130ccupswrapper_arm.deb"
    [[ "$output" == *"Architecture: all"* ]]
}

@test "driver build: CUPS wrapper has no CONFLICT_PACKAGE" {
    build_drivers 2>/dev/null
    run dpkg-deb --info "$TEST_TMPDIR/dcp130ccupswrapper_arm.deb"
    [[ "$output" != *"CONFLICT_PACKAGE"* ]]
}

@test "driver build: LPR package contains brdcp130cfilter binary" {
    build_drivers 2>/dev/null
    run dpkg-deb --contents "$TEST_TMPDIR/dcp130clpr_arm.deb"
    [[ "$output" == *"brdcp130cfilter"* ]]
}

@test "driver build: CUPS wrapper contains cupswrapper script" {
    build_drivers 2>/dev/null
    run dpkg-deb --contents "$TEST_TMPDIR/dcp130ccupswrapper_arm.deb"
    [[ "$output" == *"cupswrapperdcp130c"* ]]
}

@test "driver build: cupswrapper script embeds PPD template" {
    build_drivers 2>/dev/null
    # The PPD is generated at install time by the cupswrapper script;
    # verify the script contains the PPD heredoc template.
    local wrapper
    wrapper=$(find "$TEST_TMPDIR/cups_extract" -name 'cupswrapper*dcp130c*' -type f | head -1)
    [[ -n "$wrapper" ]]
    run grep 'PPD-Adobe' "$wrapper"
    [[ "$status" -eq 0 ]]
}

@test "driver build: cupswrapper script embeds CUPS filter template" {
    build_drivers 2>/dev/null
    # The brlpdwrapperdcp130c filter is generated at install time by
    # the cupswrapper script; verify the template is embedded.
    local wrapper
    wrapper=$(find "$TEST_TMPDIR/cups_extract" -name 'cupswrapper*dcp130c*' -type f | head -1)
    [[ -n "$wrapper" ]]
    run grep 'brlpdwrapper' "$wrapper"
    [[ "$status" -eq 0 ]]
}

@test "driver build: cupswrapper script embeds cupsFilter line" {
    build_drivers 2>/dev/null
    local wrapper
    wrapper=$(find "$TEST_TMPDIR/cups_extract" -name 'cupswrapper*dcp130c*' -type f | head -1)
    [[ -n "$wrapper" ]]
    run grep 'cupsFilter' "$wrapper"
    [[ "$status" -eq 0 ]]
}

@test "driver build: postinst scripts have no /etc/init.d/lpd references" {
    build_drivers 2>/dev/null
    # Extract the built packages' control scripts and check
    local check_dir="$TEST_TMPDIR/check_lpr"
    mkdir -p "$check_dir"
    dpkg-deb -e "$TEST_TMPDIR/dcp130clpr_arm.deb" "$check_dir"
    if [[ -f "$check_dir/postinst" ]]; then
        run grep -c '/etc/init.d/lpd' "$check_dir/postinst"
        [[ "$output" == "0" ]] || [[ "$status" -ne 0 ]]
    fi
}

@test "driver build: cupswrapper postinst has lpadmin calls patched" {
    build_drivers 2>/dev/null
    local check_dir="$TEST_TMPDIR/check_cups"
    mkdir -p "$check_dir"
    dpkg-deb -e "$TEST_TMPDIR/dcp130ccupswrapper_arm.deb" "$check_dir"
    if [[ -f "$check_dir/postinst" ]] && grep -q 'lpadmin' "$check_dir/postinst"; then
        # All lpadmin lines should be commented out
        local unpatched
        unpatched=$(grep 'lpadmin' "$check_dir/postinst" | grep -v '^[[:space:]]*#' || true)
        [[ -z "$unpatched" ]]
    fi
}

@test "driver build: installed cupswrapper script has lpadmin calls patched" {
    build_drivers 2>/dev/null
    local wrapper
    wrapper=$(find "$TEST_TMPDIR/cups_extract" -name 'cupswrapper*dcp130c*' -type f | head -1)
    [[ -n "$wrapper" ]]
    if grep -q 'lpadmin' "$wrapper"; then
        local unpatched
        unpatched=$(grep 'lpadmin' "$wrapper" | grep -v '^[[:space:]]*#' || true)
        [[ -z "$unpatched" ]]
    fi
}

@test "driver build: installed cupswrapper script has no /etc/init.d/lpd" {
    build_drivers 2>/dev/null
    local wrapper
    wrapper=$(find "$TEST_TMPDIR/cups_extract" -name 'cupswrapper*dcp130c*' -type f | head -1)
    [[ -n "$wrapper" ]]
    run grep '/etc/init.d/lpd' "$wrapper"
    [[ "$status" -ne 0 ]]
}

@test "driver build: cupswrapper PPD template contains BRMonoColor option" {
    build_drivers 2>/dev/null
    local wrapper
    wrapper=$(find "$TEST_TMPDIR/cups_extract" -name 'cupswrapper*dcp130c*' -type f | head -1)
    [[ -n "$wrapper" ]]
    run grep 'BRMonoColor' "$wrapper"
    [[ "$status" -eq 0 ]]
}

@test "driver build: cupswrapper PPD template contains cupsFilter for brlpdwrapperdcp130c" {
    build_drivers 2>/dev/null
    local wrapper
    wrapper=$(find "$TEST_TMPDIR/cups_extract" -name 'cupswrapper*dcp130c*' -type f | head -1)
    [[ -n "$wrapper" ]]
    run grep 'cupsFilter.*brlpdwrapper' "$wrapper"
    [[ "$status" -eq 0 ]]
}

@test "driver build: cupswrapper script is executable" {
    build_drivers 2>/dev/null
    local wrapper
    wrapper=$(find "$TEST_TMPDIR/cups_extract" -name 'cupswrapper*dcp130c*' -type f | head -1)
    [[ -n "$wrapper" ]]
    [[ -x "$wrapper" ]]
}

@test "driver build: brcupsconfpt1 binary is present" {
    build_drivers 2>/dev/null
    local binary
    binary=$(find "$TEST_TMPDIR/cups_extract" -name 'brcupsconfpt1' -type f | head -1)
    [[ -n "$binary" ]]
    [[ -x "$binary" ]]
}
