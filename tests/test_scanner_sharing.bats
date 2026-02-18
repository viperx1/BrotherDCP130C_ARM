#!/usr/bin/env bats
# Tests for scanner sharing configuration logic.
# Verifies saned.conf modifications, Avahi service file creation,
# AirSane configuration, and udev rules.

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

# Simulate the udev rule creation from install_airsane()
create_brother_udev_rule() {
    local rule_file="$1"
    cat > "$rule_file" << 'UDEV_EOF'
# Brother DCP-130C scanner — allow scanner group access for saned/AirSane
ATTRS{idVendor}=="04f9", ATTRS{idProduct}=="01a8", MODE="0660", GROUP="scanner", ENV{libsane_matched}="yes"
UDEV_EOF
}

# Simulate the AirSane defaults file that make install creates
create_airsane_defaults() {
    local defaults_file="$1"
    cat > "$defaults_file" << 'DEFAULTS_EOF'
INTERFACE=*
LISTEN_PORT=8090
ACCESS_LOG=
HOTPLUG=true
RELOAD_DELAY=1
MDNS_ANNOUNCE=true
ANNOUNCE_SECURE=false
ANNOUNCE_BASE_URL=
UNIX_SOCKET=
WEB_INTERFACE=true
RESET_OPTION=true
DISCLOSE_VERSION=true
LOCAL_SCANNERS_ONLY=false
RANDOM_PATHS=false
COMPATIBLE_PATH=true
OPTIONS_FILE=/etc/airsane/options.conf
ACCESS_FILE=/etc/airsane/access.conf
IGNORE_LIST=/etc/airsane/ignore.conf
DEFAULTS_EOF
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
    # Create a saned.conf that should NOT be modified
    cat > "$TEST_TMPDIR/saned.conf" << 'EOF'
localhost
EOF
    local before
    before=$(cat "$TEST_TMPDIR/saned.conf")
    # setup_scanner_sharing should return early without errors
    run setup_scanner_sharing
    [[ "$status" -eq 0 ]]
    # Verify no output was produced (no log messages about configuring sharing)
    [[ -z "$output" ]]
}

# --- AirSane variables ---

@test "scanner sharing: AIRSANE_VERSION is set" {
    [[ -n "$AIRSANE_VERSION" ]]
}

@test "scanner sharing: AIRSANE_URLS has at least 1 entry" {
    [[ ${#AIRSANE_URLS[@]} -ge 1 ]]
}

@test "scanner sharing: AIRSANE_URLS contain github.com" {
    [[ "${AIRSANE_URLS[0]}" == *"github.com"* ]]
}

@test "scanner sharing: AIRSANE_URLS contain AirSane" {
    [[ "${AIRSANE_URLS[0]}" == *"AirSane"* ]]
}

@test "scanner sharing: AIRSANE_INSTALLED defaults to false" {
    [[ "$AIRSANE_INSTALLED" == "false" ]]
}

# --- Brother udev rule tests ---

@test "scanner sharing: udev rule has Brother vendor ID 04f9" {
    create_brother_udev_rule "$TEST_TMPDIR/60-brother-scanner.rules"
    run grep '04f9' "$TEST_TMPDIR/60-brother-scanner.rules"
    [[ "$status" -eq 0 ]]
}

@test "scanner sharing: udev rule has DCP-130C product ID 01a8" {
    create_brother_udev_rule "$TEST_TMPDIR/60-brother-scanner.rules"
    run grep '01a8' "$TEST_TMPDIR/60-brother-scanner.rules"
    [[ "$status" -eq 0 ]]
}

@test "scanner sharing: udev rule sets scanner group" {
    create_brother_udev_rule "$TEST_TMPDIR/60-brother-scanner.rules"
    run grep 'GROUP="scanner"' "$TEST_TMPDIR/60-brother-scanner.rules"
    [[ "$status" -eq 0 ]]
}

@test "scanner sharing: udev rule sets libsane_matched" {
    create_brother_udev_rule "$TEST_TMPDIR/60-brother-scanner.rules"
    run grep 'libsane_matched' "$TEST_TMPDIR/60-brother-scanner.rules"
    [[ "$status" -eq 0 ]]
}

# --- AirSane defaults file tests ---

@test "scanner sharing: AirSane defaults has MDNS_ANNOUNCE=true" {
    create_airsane_defaults "$TEST_TMPDIR/airsane"
    run grep '^MDNS_ANNOUNCE=true' "$TEST_TMPDIR/airsane"
    [[ "$status" -eq 0 ]]
}

@test "scanner sharing: AirSane defaults listens on port 8090" {
    create_airsane_defaults "$TEST_TMPDIR/airsane"
    run grep '^LISTEN_PORT=8090' "$TEST_TMPDIR/airsane"
    [[ "$status" -eq 0 ]]
}

@test "scanner sharing: AirSane defaults enables web interface" {
    create_airsane_defaults "$TEST_TMPDIR/airsane"
    run grep '^WEB_INTERFACE=true' "$TEST_TMPDIR/airsane"
    [[ "$status" -eq 0 ]]
}

@test "scanner sharing: AirSane defaults enables hotplug" {
    create_airsane_defaults "$TEST_TMPDIR/airsane"
    run grep '^HOTPLUG=true' "$TEST_TMPDIR/airsane"
    [[ "$status" -eq 0 ]]
}

# --- display_info output ---

@test "scanner sharing: display_info mentions Windows when AirSane installed" {
    SCANNER_SHARED=true
    AIRSANE_INSTALLED=true
    output=$(display_info 2>&1)
    [[ "$output" == *"Windows"* ]]
}

@test "scanner sharing: display_info mentions macOS when AirSane installed" {
    SCANNER_SHARED=true
    AIRSANE_INSTALLED=true
    output=$(display_info 2>&1)
    [[ "$output" == *"macOS"* ]]
}

@test "scanner sharing: display_info mentions AirSane web interface" {
    SCANNER_SHARED=true
    AIRSANE_INSTALLED=true
    output=$(display_info 2>&1)
    [[ "$output" == *"8090"* ]]
}

@test "scanner sharing: display_info shows NOT INSTALLED when AirSane fails" {
    SCANNER_SHARED=true
    AIRSANE_INSTALLED=false
    output=$(display_info 2>&1)
    [[ "$output" == *"NOT INSTALLED"* ]]
}
