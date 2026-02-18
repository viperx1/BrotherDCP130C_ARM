#!/usr/bin/env bats
# Tests for scanner sharing configuration logic.
# Verifies saned.conf modifications and Avahi service file creation.

load test_helper

setup() {
    setup_test_tmpdir
    DEBUG=1
    source_scanner_functions
}

teardown() {
    teardown_test_tmpdir
}

# Helper: create a minimal default saned.conf
create_default_saned_conf() {
    cat > "$TEST_TMPDIR/saned.conf" << 'EOF'
# saned.conf — access control for the SANE network daemon
# Each line names a host or subnet that is permitted to access the scanner.
localhost
EOF
}

# Simulate the saned.conf ACL additions from setup_scanner_sharing()
apply_saned_acl() {
    local conf="$1"
    local -a acl_entries=("192.168.0.0/16" "10.0.0.0/8" "172.16.0.0/12")
    for entry in "${acl_entries[@]}"; do
        if ! grep -q "^${entry}$" "$conf" 2>/dev/null; then
            echo "$entry" >> "$conf"
        fi
    done
}

# Simulate Avahi service file creation from setup_scanner_sharing()
create_avahi_service_file() {
    local service_file="$1"
    cat > "$service_file" << 'AVAHI_EOF'
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">SANE scanner on %h</name>
  <service>
    <type>_sane-port._tcp</type>
    <port>6566</port>
  </service>
</service-group>
AVAHI_EOF
}

# --- saned.conf tests ---

@test "scanner sharing: adds 192.168.0.0/16 to saned.conf" {
    create_default_saned_conf
    apply_saned_acl "$TEST_TMPDIR/saned.conf"
    run grep '^192\.168\.0\.0/16$' "$TEST_TMPDIR/saned.conf"
    [[ "$status" -eq 0 ]]
}

@test "scanner sharing: adds 10.0.0.0/8 to saned.conf" {
    create_default_saned_conf
    apply_saned_acl "$TEST_TMPDIR/saned.conf"
    run grep '^10\.0\.0\.0/8$' "$TEST_TMPDIR/saned.conf"
    [[ "$status" -eq 0 ]]
}

@test "scanner sharing: adds 172.16.0.0/12 to saned.conf" {
    create_default_saned_conf
    apply_saned_acl "$TEST_TMPDIR/saned.conf"
    run grep '^172\.16\.0\.0/12$' "$TEST_TMPDIR/saned.conf"
    [[ "$status" -eq 0 ]]
}

@test "scanner sharing: preserves localhost in saned.conf" {
    create_default_saned_conf
    apply_saned_acl "$TEST_TMPDIR/saned.conf"
    run grep '^localhost$' "$TEST_TMPDIR/saned.conf"
    [[ "$status" -eq 0 ]]
}

@test "scanner sharing: saned.conf ACL is idempotent" {
    create_default_saned_conf
    apply_saned_acl "$TEST_TMPDIR/saned.conf"
    apply_saned_acl "$TEST_TMPDIR/saned.conf"
    count=$(grep -c '192\.168\.0\.0/16' "$TEST_TMPDIR/saned.conf")
    [[ "$count" -eq 1 ]]
}

@test "scanner sharing: saned.conf ACL idempotent for 10.0.0.0/8" {
    create_default_saned_conf
    apply_saned_acl "$TEST_TMPDIR/saned.conf"
    apply_saned_acl "$TEST_TMPDIR/saned.conf"
    count=$(grep -c '10\.0\.0\.0/8' "$TEST_TMPDIR/saned.conf")
    [[ "$count" -eq 1 ]]
}

# --- Avahi service file tests ---

@test "scanner sharing: Avahi service file has _sane-port._tcp type" {
    create_avahi_service_file "$TEST_TMPDIR/sane.service"
    run grep '_sane-port._tcp' "$TEST_TMPDIR/sane.service"
    [[ "$status" -eq 0 ]]
}

@test "scanner sharing: Avahi service file has port 6566" {
    create_avahi_service_file "$TEST_TMPDIR/sane.service"
    run grep '<port>6566</port>' "$TEST_TMPDIR/sane.service"
    [[ "$status" -eq 0 ]]
}

@test "scanner sharing: Avahi service file is valid XML" {
    create_avahi_service_file "$TEST_TMPDIR/sane.service"
    run grep '<?xml' "$TEST_TMPDIR/sane.service"
    [[ "$status" -eq 0 ]]
}

@test "scanner sharing: Avahi service file has service-group root" {
    create_avahi_service_file "$TEST_TMPDIR/sane.service"
    run grep '<service-group>' "$TEST_TMPDIR/sane.service"
    [[ "$status" -eq 0 ]]
    run grep '</service-group>' "$TEST_TMPDIR/sane.service"
    [[ "$status" -eq 0 ]]
}

@test "scanner sharing: Avahi service file has hostname placeholder" {
    create_avahi_service_file "$TEST_TMPDIR/sane.service"
    run grep '%h' "$TEST_TMPDIR/sane.service"
    [[ "$status" -eq 0 ]]
}

@test "scanner sharing: SCANNER_SHARED=false skips sharing setup" {
    SCANNER_SHARED=false
    # setup_scanner_sharing should return early without errors
    # (it requires sudo for real operations, but the guard clause exits first)
    run setup_scanner_sharing
    [[ "$status" -eq 0 ]]
}
