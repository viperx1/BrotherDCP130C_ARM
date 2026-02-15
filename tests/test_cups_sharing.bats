#!/usr/bin/env bats
# Tests for CUPS sharing configuration logic.
# Verifies cupsd.conf modifications for network sharing.

load test_helper

setup() {
    setup_test_tmpdir
    DEBUG=1
    source_functions
}

teardown() {
    teardown_test_tmpdir
}

# Helper: create a minimal default cupsd.conf
create_default_cupsd_conf() {
    cat > "$TEST_TMPDIR/cupsd.conf" << 'EOF'
# Default CUPS config
Listen localhost:631
Listen /run/cups/cups.sock
Browsing No
DefaultAuthType Basic

<Location />
  Order allow,deny
</Location>

<Location /admin>
  Order allow,deny
</Location>
EOF
}

# Simulate the sharing configuration sed commands from setup_cups_service()
apply_sharing_config() {
    local conf="$1"
    # These are the exact sed commands from the script's setup_cups_service()
    sed -i 's/^Listen localhost:631$/Port 631/' "$conf"
    sed -i 's/^Browsing No$/Browsing On/' "$conf"

    if ! grep -q '^BrowseLocalProtocols' "$conf"; then
        sed -i '/^Browsing On$/a BrowseLocalProtocols dnssd' "$conf"
    fi
    if ! grep -q '^ServerAlias' "$conf"; then
        sed -i '/^Port 631$/a ServerAlias *' "$conf"
    fi

    sed -i '/<Location \/>/{n;s/Order allow,deny/Order allow,deny\n  Allow @LOCAL/}' "$conf"
    sed -i '/<Location \/admin>/{n;s/Order allow,deny/Order allow,deny\n  Allow @LOCAL/}' "$conf"
}

@test "sharing config changes Listen localhost:631 to Port 631" {
    create_default_cupsd_conf
    apply_sharing_config "$TEST_TMPDIR/cupsd.conf"
    run grep '^Port 631' "$TEST_TMPDIR/cupsd.conf"
    [[ "$status" -eq 0 ]]
    run grep 'Listen localhost:631' "$TEST_TMPDIR/cupsd.conf"
    [[ "$status" -ne 0 ]]
}

@test "sharing config enables Browsing" {
    create_default_cupsd_conf
    apply_sharing_config "$TEST_TMPDIR/cupsd.conf"
    run grep '^Browsing On' "$TEST_TMPDIR/cupsd.conf"
    [[ "$status" -eq 0 ]]
}

@test "sharing config adds BrowseLocalProtocols dnssd" {
    create_default_cupsd_conf
    apply_sharing_config "$TEST_TMPDIR/cupsd.conf"
    run grep '^BrowseLocalProtocols dnssd' "$TEST_TMPDIR/cupsd.conf"
    [[ "$status" -eq 0 ]]
}

@test "sharing config adds ServerAlias *" {
    create_default_cupsd_conf
    apply_sharing_config "$TEST_TMPDIR/cupsd.conf"
    run grep '^ServerAlias \*' "$TEST_TMPDIR/cupsd.conf"
    [[ "$status" -eq 0 ]]
}

@test "sharing config adds Allow @LOCAL to root location" {
    create_default_cupsd_conf
    apply_sharing_config "$TEST_TMPDIR/cupsd.conf"
    run grep 'Allow @LOCAL' "$TEST_TMPDIR/cupsd.conf"
    [[ "$status" -eq 0 ]]
}

@test "sharing config preserves Listen /run/cups/cups.sock" {
    create_default_cupsd_conf
    apply_sharing_config "$TEST_TMPDIR/cupsd.conf"
    run grep 'Listen /run/cups/cups.sock' "$TEST_TMPDIR/cupsd.conf"
    [[ "$status" -eq 0 ]]
}

@test "sharing config is idempotent for BrowseLocalProtocols" {
    create_default_cupsd_conf
    apply_sharing_config "$TEST_TMPDIR/cupsd.conf"
    apply_sharing_config "$TEST_TMPDIR/cupsd.conf"
    count=$(grep -c 'BrowseLocalProtocols' "$TEST_TMPDIR/cupsd.conf")
    [[ "$count" -eq 1 ]]
}

@test "sharing config is idempotent for ServerAlias" {
    create_default_cupsd_conf
    apply_sharing_config "$TEST_TMPDIR/cupsd.conf"
    apply_sharing_config "$TEST_TMPDIR/cupsd.conf"
    count=$(grep -c 'ServerAlias' "$TEST_TMPDIR/cupsd.conf")
    [[ "$count" -eq 1 ]]
}
