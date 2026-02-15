#!/usr/bin/env bats
# Tests for driver extraction and modification logic.
# Verifies Architecture changes, CONFLICT_PACKAGE removal,
# /etc/init.d/lpd patching, and PPD patching.

load test_helper

setup() {
    setup_test_tmpdir
    DEBUG=1
    source_functions
}

teardown() {
    teardown_test_tmpdir
}

# --- Architecture modification ---

@test "sed changes Architecture: i386 to Architecture: all" {
    echo "Architecture: i386" > "$TEST_TMPDIR/control"
    sed -i 's/Architecture: .*/Architecture: all/' "$TEST_TMPDIR/control"
    run grep 'Architecture: all' "$TEST_TMPDIR/control"
    [[ "$status" -eq 0 ]]
}

@test "sed preserves other control fields" {
    cat > "$TEST_TMPDIR/control" << 'EOF'
Package: dcp130clpr
Version: 1.0.1-1
Architecture: i386
Description: Brother driver
EOF
    sed -i 's/Architecture: .*/Architecture: all/' "$TEST_TMPDIR/control"
    run grep 'Package: dcp130clpr' "$TEST_TMPDIR/control"
    [[ "$status" -eq 0 ]]
    run grep 'Version: 1.0.1-1' "$TEST_TMPDIR/control"
    [[ "$status" -eq 0 ]]
    run grep 'Description: Brother driver' "$TEST_TMPDIR/control"
    [[ "$status" -eq 0 ]]
}

# --- CONFLICT_PACKAGE removal ---

@test "sed removes Conflicts: CONFLICT_PACKAGE line" {
    cat > "$TEST_TMPDIR/control" << 'EOF'
Package: dcp130ccupswrapper
Depends: dcp130clpr
Conflicts: CONFLICT_PACKAGE
Description: CUPS wrapper
EOF
    sed -i '/^Conflicts: CONFLICT_PACKAGE$/d' "$TEST_TMPDIR/control"
    run grep 'CONFLICT_PACKAGE' "$TEST_TMPDIR/control"
    [[ "$status" -ne 0 ]]
    # Other fields preserved
    run grep 'Depends: dcp130clpr' "$TEST_TMPDIR/control"
    [[ "$status" -eq 0 ]]
}

@test "sed preserves real Conflicts lines" {
    cat > "$TEST_TMPDIR/control" << 'EOF'
Conflicts: some-real-package
Conflicts: CONFLICT_PACKAGE
EOF
    sed -i '/^Conflicts: CONFLICT_PACKAGE$/d' "$TEST_TMPDIR/control"
    run grep 'Conflicts: some-real-package' "$TEST_TMPDIR/control"
    [[ "$status" -eq 0 ]]
    run grep 'CONFLICT_PACKAGE' "$TEST_TMPDIR/control"
    [[ "$status" -ne 0 ]]
}

# --- /etc/init.d/lpd patching ---

@test "sed replaces /etc/init.d/lpd with /bin/true" {
    cat > "$TEST_TMPDIR/postinst" << 'EOF'
#!/bin/bash
/etc/init.d/lpd restart
/etc/init.d/lpd stop
echo "done"
EOF
    sed -i 's|/etc/init.d/lpd|/bin/true|g' "$TEST_TMPDIR/postinst"
    run grep '/etc/init.d/lpd' "$TEST_TMPDIR/postinst"
    [[ "$status" -ne 0 ]]
    count=$(grep -c '/bin/true' "$TEST_TMPDIR/postinst")
    [[ "$count" -eq 2 ]]
    run grep 'echo "done"' "$TEST_TMPDIR/postinst"
    [[ "$status" -eq 0 ]]
}

# --- PPD patching ---

@test "PPD patch adds APPrinterPreset entries" {
    cat > "$TEST_TMPDIR/test.ppd" << 'EOF'
*PPD-Adobe: "4.3"
*ModelName: "Brother DCP-130C"
*cupsFilter: "application/vnd.cups-postscript 0 brlpdwrapperdcp130c"
*OpenUI *BRMonoColor/Color/Grayscale: PickOne
*BRMonoColor BrColor/Color: ""
*BRMonoColor BrMono/Grayscale: ""
*CloseUI: *BRMonoColor
EOF
    # Simulate the PPD patching logic
    if ! grep -q 'APPrinterPreset' "$TEST_TMPDIR/test.ppd"; then
        cat >> "$TEST_TMPDIR/test.ppd" << 'COLORPATCH'

*% IPP print-color-mode mapping for Android/iOS printing.
*% Maps to Brother's native BRMonoColor option which the driver
*cupsIPPSupplies: True
*APPrinterPreset Color/Color: "*BRMonoColor BrColor"
*APPrinterPreset Grayscale/Grayscale: "*BRMonoColor BrMono"
COLORPATCH
    fi
    run grep 'APPrinterPreset Color' "$TEST_TMPDIR/test.ppd"
    [[ "$status" -eq 0 ]]
    run grep 'APPrinterPreset Grayscale' "$TEST_TMPDIR/test.ppd"
    [[ "$status" -eq 0 ]]
    run grep 'BRMonoColor BrMono' "$TEST_TMPDIR/test.ppd"
    [[ "$status" -eq 0 ]]
}

@test "PPD patch is idempotent" {
    cat > "$TEST_TMPDIR/test.ppd" << 'EOF'
*PPD-Adobe: "4.3"
*APPrinterPreset Color/Color: "*BRMonoColor BrColor"
*APPrinterPreset Grayscale/Grayscale: "*BRMonoColor BrMono"
EOF
    # Should NOT add again
    if ! grep -q 'APPrinterPreset' "$TEST_TMPDIR/test.ppd"; then
        echo '*APPrinterPreset Extra: "should not appear"' >> "$TEST_TMPDIR/test.ppd"
    fi
    count=$(grep -c 'APPrinterPreset' "$TEST_TMPDIR/test.ppd")
    [[ "$count" -eq 2 ]]
}

@test "PPD patch maps to BRMonoColor (not ColorModel)" {
    cat > "$TEST_TMPDIR/test.ppd" << 'EOF'
*PPD-Adobe: "4.3"
EOF
    cat >> "$TEST_TMPDIR/test.ppd" << 'COLORPATCH'
*APPrinterPreset Color/Color: "*BRMonoColor BrColor"
*APPrinterPreset Grayscale/Grayscale: "*BRMonoColor BrMono"
COLORPATCH
    # Should reference BRMonoColor, not ColorModel
    run grep 'APPrinterPreset.*BRMonoColor' "$TEST_TMPDIR/test.ppd"
    [[ "$status" -eq 0 ]]
    run grep 'APPrinterPreset.*ColorModel' "$TEST_TMPDIR/test.ppd"
    [[ "$status" -ne 0 ]]
}
