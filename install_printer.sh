#!/bin/bash
################################################################################
# Brother DCP-130C Printer Driver Installation Script for Raspberry Pi
# System: Linux armv7l (Raspberry Pi)
# Printer: Brother DCP-130C
################################################################################

set -e  # Exit on error

# Enable debug mode via --debug flag or DEBUG=1 environment variable
DEBUG="${DEBUG:-0}"
for arg in "$@"; do
    if [[ "$arg" == "--debug" ]]; then
        DEBUG=1
    fi
done

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_debug() {
    if [[ "$DEBUG" == "1" ]]; then
        echo -e "${CYAN}[DEBUG]${NC} $1" >&2
    fi
}

# Variables
PRINTER_NAME="Brother_DCP_130C"
TMP_DIR="/tmp/brother_dcp130c_install"
PRINTER_SHARED=false

# Patch lpadmin calls in a script file by commenting them out.
# This prevents Brother's cupswrapper scripts from auto-creating printers.
# Usage: patch_lpadmin_calls <file> [sudo]
patch_lpadmin_calls() {
    local file="$1"
    local prefix="${2:-}"
    if grep -q 'lpadmin' "$file"; then
        # Comment out any non-comment line containing lpadmin (covers bare
        # "lpadmin", "/usr/sbin/lpadmin", backtick/subshell calls, and
        # variable-assigned invocations like result=`lpadmin ...`).
        # Lines that already start with # are left alone.
        $prefix sed -i '/^[[:space:]]*#/!{/lpadmin/s|^\([[:space:]]*\)\(.*\)|\1# [patched] \2|}' "$file"
        # Log any remaining unpatched lpadmin references for debugging
        local remaining
        remaining=$($prefix grep -n 'lpadmin' "$file" | grep -v '^[0-9]*:[[:space:]]*#' || true)
        if [[ -n "$remaining" ]]; then
            :
        else
            :
        fi
    fi
}

# Driver filenames
DRIVER_LPR_FILE="dcp130clpr-1.0.1-1.i386.deb"
DRIVER_CUPS_FILE="dcp130ccupswrapper-1.0.1-1.i386.deb"

# Multiple download sources (tried in order). Brother has moved files across
# domains over the years, so we try several known locations plus the
# Internet Archive as a last resort.
# The dlf number is Brother's internal download file ID.
DRIVER_LPR_URLS=(
    "https://download.brother.com/welcome/dlf005579/${DRIVER_LPR_FILE}"
    "http://download.brother.com/welcome/dlf005579/${DRIVER_LPR_FILE}"
    "http://www.brother.com/pub/bsc/linux/dlf/${DRIVER_LPR_FILE}"
    "https://web.archive.org/web/2024if_/https://download.brother.com/welcome/dlf005579/${DRIVER_LPR_FILE}"
)
DRIVER_CUPS_URLS=(
    "https://download.brother.com/welcome/dlf005581/${DRIVER_CUPS_FILE}"
    "http://download.brother.com/welcome/dlf005581/${DRIVER_CUPS_FILE}"
    "http://www.brother.com/pub/bsc/linux/dlf/${DRIVER_CUPS_FILE}"
    "https://web.archive.org/web/2024if_/https://download.brother.com/welcome/dlf005581/${DRIVER_CUPS_FILE}"
)

# Check if running as root
check_root() {
    if [[ $EUID -eq 0 ]]; then
        log_warn "Running as root. This is recommended for installation."
    else
        log_warn "Not running as root. You may need to enter your password for sudo commands."
    fi
}

# Check system architecture
check_architecture() {
    log_info "Checking system architecture..."
    ARCH=$(uname -m)
    log_info "Detected architecture: $ARCH"
    
    if [[ "$ARCH" != "armv7l" && "$ARCH" != "armv6l" && "$ARCH" != "aarch64" ]]; then
        log_warn "This script is designed for ARM architecture (Raspberry Pi). Detected: $ARCH"
        read -p "Continue anyway? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
}

# Ask user whether to enable printer sharing on the local network.
# When enabled, the printer will be shared via CUPS and discoverable
# on the LAN through Avahi/Bonjour (mDNS).
ask_printer_sharing() {
    echo
    log_info "Printer sharing allows other devices on your local network to discover and use this printer."
    read -p "Do you want to enable printer sharing on the local network? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        PRINTER_SHARED=true
        log_info "Printer sharing will be enabled."
    else
        PRINTER_SHARED=false
        log_info "Printer sharing will not be enabled. The printer will only be available locally."
    fi
}

# Check if a package (or its t64 variant) is already installed.
# Returns 0 if installed, 1 otherwise. Prints the installed package name.
is_package_installed() {
    local pkg="$1"
    if dpkg -s "$pkg" &>/dev/null; then
        echo "$pkg"
        return 0
    fi
    local t64_pkg="${pkg}t64"
    if dpkg -s "$t64_pkg" &>/dev/null; then
        echo "$t64_pkg"
        return 0
    fi
    return 1
}

# Resolve a package name, preferring the original but falling back to the t64 variant.
# On newer Debian/Raspbian (trixie+), some libraries were renamed with a t64 suffix
# (e.g. libcups2 -> libcups2t64). This function detects which variant is available.
# It first checks if the package is already installed, then falls back to apt-cache.
resolve_package() {
    local pkg="$1"
    local installed
    # Check if already installed (original or t64 variant)
    if installed=$(is_package_installed "$pkg"); then
        echo "$installed"
        return
    fi
    # Not installed - check which variant is available in apt
    local policy
    local candidate
    policy=$(apt-cache policy "$pkg" 2>/dev/null)
    candidate=$(echo "$policy" | grep "Candidate:" | awk '{print $2}')
    if [[ -n "$candidate" && "$candidate" != "(none)" ]]; then
        echo "$pkg"
        return
    fi
    # Try the t64 variant
    local t64_pkg="${pkg}t64"
    policy=$(apt-cache policy "$t64_pkg" 2>/dev/null)
    candidate=$(echo "$policy" | grep "Candidate:" | awk '{print $2}')
    if [[ -n "$candidate" && "$candidate" != "(none)" ]]; then
        echo "$t64_pkg"
        return
    fi
    # Fall back to the original name and let apt-get report the error
    echo "$pkg"
}

# Fix broken dpkg state from previous failed installs.
# A broken package (e.g. dcp130clpr:i386 "needs to be reinstalled") blocks
# ALL apt-get operations, so this must run before install_dependencies().
# We also detect "unpacked" state (package extracted but not configured),
# which can leave broken dependency chains.
fix_broken_packages() {
    local packages_fixed=0
    for pkg in dcp130clpr dcp130ccupswrapper "dcp130clpr:i386" "dcp130ccupswrapper:i386"; do
        if dpkg -s "$pkg" &>/dev/null; then
            local status
            status=$(dpkg -s "$pkg" 2>/dev/null | grep "^Status:" || true)
            if echo "$status" | grep -qi "reinst-required\|half-installed\|half-configured" || \
               echo "$status" | grep -qw "unpacked"; then
                log_warn "Fixing broken package state: $pkg ($status)"

                # pkg_base is the package name without architecture qualifier
                # (e.g. "dcp130clpr" from "dcp130clpr:i386"). Both forms are
                # needed: dpkg commands use the full name, while dpkg info files
                # on disk may use either form depending on the system.
                local pkg_base="${pkg%%:*}"

                # First, neutralize any broken maintainer scripts that may
                # prevent dpkg from completing the removal (e.g. scripts that
                # call /etc/init.d/lpd which doesn't exist on modern systems).
                for script in preinst postinst prerm postrm; do
                    for sp in "/var/lib/dpkg/info/${pkg_base}.${script}" \
                              "/var/lib/dpkg/info/${pkg}.${script}"; do
                        if [[ -f "$sp" ]]; then
                            sudo cp "$sp" "${sp}.bak" 2>/dev/null || true
                            echo '#!/bin/sh' | sudo tee "$sp" > /dev/null
                            echo 'exit 0' | sudo tee -a "$sp" > /dev/null
                            sudo chmod 755 "$sp"
                        fi
                    done
                done

                # Now try aggressive removal with all forces enabled
                sudo dpkg --purge --force-all "$pkg" 2>/dev/null || true

                # Verify removal succeeded
                if dpkg -s "$pkg" &>/dev/null; then
                    local new_status
                    new_status=$(dpkg -s "$pkg" 2>/dev/null | grep "^Status:" || true)

                    # Last resort: directly clean the dpkg database
                    log_warn "Standard removal failed for $pkg, cleaning dpkg database directly..."
                    sudo rm -f "/var/lib/dpkg/info/${pkg_base}".* 2>/dev/null || true
                    sudo rm -f "/var/lib/dpkg/info/${pkg}".* 2>/dev/null || true
                    # Remove the package entry from dpkg status file using
                    # exact match on the package name (without arch qualifier)
                    if [[ -f /var/lib/dpkg/status ]]; then
                        sudo cp /var/lib/dpkg/status /var/lib/dpkg/status.bak
                        sudo awk -v pkg="$pkg_base" '
                            BEGIN { skip=0 }
                            /^Package:/ { skip=($2 == pkg) }
                            /^$/ { if (skip) { skip=0; next } }
                            !skip { print }
                        ' /var/lib/dpkg/status.bak | sudo tee /var/lib/dpkg/status > /dev/null
                    fi
                else
                    :
                fi

                packages_fixed=1
            fi
        fi
    done

    if [[ $packages_fixed -eq 1 ]]; then
        # Run apt-get install -f to resolve any remaining dependency issues
        # left over after purging broken packages
        sudo apt-get install -f -y 2>/dev/null || true

        # Verify apt-get works now
        local check_output
        check_output=$(sudo apt-get check 2>&1 || true)
        if echo "$check_output" | grep -qi "reinst-required\|needs to be reinstalled"; then
            log_error "apt-get is still blocked by broken packages after cleanup."
            log_error "apt-get check output:"
            log_error "$check_output"
            log_error "Try manually running: sudo dpkg --configure -a"
            exit 1
        fi
        log_info "Cleaned up broken package state. apt-get is working."
    fi
}

# Install required dependencies
install_dependencies() {
    log_info "Installing required dependencies..."
    
    sudo apt-get update
    
    # Detect CUPS status
    if command -v systemctl &>/dev/null && systemctl is-active cups &>/dev/null; then
        log_info "CUPS is already running on this system."
    fi
    
    # Resolve library package names that may differ across Debian/Raspbian versions
    # On trixie+, libcups2 -> libcups2t64, libcupsimage2 -> libcupsimage2t64
    log_info "Detecting correct package names for this system..."
    LIBCUPS=$(resolve_package "libcups2")
    LIBCUPSIMAGE=$(resolve_package "libcupsimage2")
    log_info "Resolved: libcups2 -> $LIBCUPS, libcupsimage2 -> $LIBCUPSIMAGE"
    
    # Build list of packages to install
    local packages=(
        cups
        cups-client
        cups-bsd
        "$LIBCUPS"
        "$LIBCUPSIMAGE"
        printer-driver-all
        ghostscript
        psutils
        a2ps
    )


    # Install CUPS and required tools
    sudo apt-get install -y "${packages[@]}"
    
    log_info "Dependencies installed successfully."
}

# Enable and start CUPS service
setup_cups_service() {
    log_info "Setting up CUPS service..."
    
    sudo systemctl enable cups
    sudo systemctl start cups
    
    # Add user to lpadmin group if not already
    if ! groups "$USER" | grep -q lpadmin; then
        sudo usermod -a -G lpadmin "$USER"
        log_info "Added $USER to lpadmin group. You may need to log out and back in for this to take effect."
    else
        :
    fi

    if [[ "$PRINTER_SHARED" == true ]]; then
        log_info "Configuring CUPS for network printer sharing..."

        # Allow CUPS to listen on all network interfaces (not just localhost)
        local cupsd_conf="/etc/cups/cupsd.conf"
        if [[ -f "$cupsd_conf" ]]; then
            # Back up the original configuration
            sudo cp "$cupsd_conf" "${cupsd_conf}.bak"

            # Replace "Listen localhost:631" with "Port 631" so CUPS listens on all interfaces
            if grep -q '^Listen localhost:631' "$cupsd_conf"; then
                sudo sed -i 's/^Listen localhost:631/Port 631/' "$cupsd_conf"
            elif ! grep -q '^Port 631' "$cupsd_conf"; then
                echo 'Port 631' | sudo tee -a "$cupsd_conf" > /dev/null
            fi

            # Accept requests using any hostname. Android's print service
            # connects via the mDNS-discovered hostname which may not match
            # CUPS' ServerName, causing a "printing service is not enabled"
            # error on the client even though the job prints.
            if ! grep -q '^ServerAlias' "$cupsd_conf"; then
                sudo sed -i '/^Port 631/a ServerAlias *' "$cupsd_conf" 2>/dev/null \
                    || echo 'ServerAlias *' | sudo tee -a "$cupsd_conf" > /dev/null
            fi

            # Enable sharing in cupsd.conf
            if grep -q '^Browsing' "$cupsd_conf"; then
                sudo sed -i 's/^Browsing .*/Browsing On/' "$cupsd_conf"
            else
                echo 'Browsing On' | sudo tee -a "$cupsd_conf" > /dev/null
            fi

            # Advertise shared printers via DNS-SD (mDNS) so they are
            # discoverable by Android, iOS, macOS and other devices that
            # use mDNS-based printer discovery.
            if grep -q '^BrowseLocalProtocols' "$cupsd_conf"; then
                sudo sed -i 's/^BrowseLocalProtocols .*/BrowseLocalProtocols dnssd/' "$cupsd_conf"
            else
                echo 'BrowseLocalProtocols dnssd' | sudo tee -a "$cupsd_conf" > /dev/null
            fi

            # Allow remote access to the printer in the <Location /> block
            # Add "Allow @LOCAL" if not already present so LAN clients can print
            if ! grep -q 'Allow @LOCAL' "$cupsd_conf"; then
                sudo sed -i '/<Location \/>/,/<\/Location>/ {
                    /Order allow,deny/a\  Allow @LOCAL
                }' "$cupsd_conf"
            fi

            # Allow remote access to /printers as well
            if grep -q '<Location /printers>' "$cupsd_conf"; then
                if ! sudo sed -n '/<Location \/printers>/,/<\/Location>/p' "$cupsd_conf" | grep -q 'Allow @LOCAL'; then
                    sudo sed -i '/<Location \/printers>/,/<\/Location>/ {
                        /Order allow,deny/a\  Allow @LOCAL
                    }' "$cupsd_conf"
                fi
            fi

        fi

        # Install and enable Avahi for mDNS/Bonjour printer discovery on LAN
        if ! dpkg -s avahi-daemon &>/dev/null; then
            log_info "Installing Avahi daemon for network printer discovery..."
            sudo apt-get install -y avahi-daemon 2>&1 | tail -3
        else
            :
        fi
        sudo systemctl enable avahi-daemon || log_warn "Failed to enable avahi-daemon"
        sudo systemctl start avahi-daemon || log_warn "Failed to start avahi-daemon"

        # Restart CUPS to apply configuration changes
        log_info "Restarting CUPS to apply sharing configuration..."
        sudo systemctl restart cups
    fi
    
    log_info "CUPS service is running."
}

# Create temporary directory
create_temp_dir() {
    log_info "Creating temporary directory..."
    mkdir -p "$TMP_DIR"
    cd "$TMP_DIR"
    log_info "Working directory: $TMP_DIR"
}

# Try downloading a file from multiple URLs until one succeeds.
# Usage: try_download output_file url1 url2 url3 ...
# Returns 0 on success, 1 if all URLs fail.
try_download() {
    local output_file="$1"
    shift
    local urls=("$@")
    
    for url in "${urls[@]}"; do
        if wget -q --timeout=30 --tries=2 -O "$output_file" "$url" 2>/dev/null; then
            # Verify we got an actual file (not an HTML error page)
            if [[ -s "$output_file" ]] && file "$output_file" | grep -qi "debian\|archive\|data"; then
                log_info "Downloaded successfully from: $url"
                return 0
            fi
            rm -f "$output_file"
        else
            :
        fi
    done
    
    return 1
}

# Download printer drivers
download_drivers() {
    log_info "Downloading Brother DCP-130C printer drivers..."
    
    # Download LPR driver
    log_info "Downloading LPR driver (${DRIVER_LPR_FILE})..."
    if ! try_download dcp130clpr.deb "${DRIVER_LPR_URLS[@]}"; then
        log_error "Failed to download LPR driver from all sources."
        log_error "URLs tried:"
        for url in "${DRIVER_LPR_URLS[@]}"; do
            log_error "  - $url"
        done
        log_error "Please download ${DRIVER_LPR_FILE} manually and place it in ${TMP_DIR}/"
        exit 1
    fi
    
    # Download CUPS wrapper driver
    log_info "Downloading CUPS wrapper driver (${DRIVER_CUPS_FILE})..."
    if ! try_download dcp130ccupswrapper.deb "${DRIVER_CUPS_URLS[@]}"; then
        log_error "Failed to download CUPS wrapper driver from all sources."
        log_error "URLs tried:"
        for url in "${DRIVER_CUPS_URLS[@]}"; do
            log_error "  - $url"
        done
        log_error "Please download ${DRIVER_CUPS_FILE} manually and place it in ${TMP_DIR}/"
        exit 1
    fi
    
    log_info "Drivers downloaded successfully."
}

# Extract and modify drivers for ARM architecture
extract_and_modify_drivers() {
    log_info "Extracting and preparing drivers for ARM architecture..."
    
    # Create working directories
    mkdir -p lpr_extract cups_extract
    
    # Extract LPR driver
    log_info "Extracting LPR driver..."
    dpkg-deb -x dcp130clpr.deb lpr_extract/
    dpkg-deb -e dcp130clpr.deb lpr_extract/DEBIAN
    
    # Extract CUPS wrapper driver
    log_info "Extracting CUPS wrapper driver..."
    dpkg-deb -x dcp130ccupswrapper.deb cups_extract/
    dpkg-deb -e dcp130ccupswrapper.deb cups_extract/DEBIAN
    
    # Modify control files to remove architecture restrictions
    sed -i 's/Architecture: .*/Architecture: all/' lpr_extract/DEBIAN/control
    sed -i 's/Architecture: .*/Architecture: all/' cups_extract/DEBIAN/control
    
    # Remove the placeholder CONFLICT_PACKAGE from CUPS wrapper control
    sed -i '/^Conflicts: CONFLICT_PACKAGE$/d' cups_extract/DEBIAN/control
    
    # Fix maintainer scripts that reference /etc/init.d/lpd which doesn't
    # exist on modern systems and causes "Permission denied" errors.
    # Replace calls to /etc/init.d/lpd with a harmless no-op.
    # Also comment out lpadmin calls in the cupswrapper postinst/prerm to
    # prevent the package from auto-creating/removing a "DCP130C" printer
    # during dpkg install — we handle printer setup in configure_printer().
    for script_dir in lpr_extract/DEBIAN cups_extract/DEBIAN; do
        for script in preinst postinst prerm postrm; do
            if [[ -f "$script_dir/$script" ]]; then
                if grep -q '/etc/init.d/lpd' "$script_dir/$script"; then
                    sed -i 's|/etc/init.d/lpd|/bin/true|g' "$script_dir/$script"
                fi
                if [[ "$script_dir" == "cups_extract/DEBIAN" ]]; then
                    patch_lpadmin_calls "$script_dir/$script"
                fi
                # Ensure script is executable
                chmod 755 "$script_dir/$script"
            fi
        done
    done

    # Also patch the cupswrapper script that gets installed to
    # /usr/local/Brother/Printer/dcp130c/cupswrapper/cupswrapperdcp130c
    # This script is called from the CUPS wrapper postinst and itself
    # references /etc/init.d/lpd. Without patching it, the filter
    # pipeline setup may fail silently.
    # Additionally, the cupswrapper script calls lpadmin to auto-create a
    # printer named "DCP130C". We patch those calls out so only our own
    # configure_printer() creates the printer with the correct name and URI,
    # preventing duplicate printers from appearing in CUPS.
    local wrapper_script
    wrapper_script=$(find cups_extract/ -name 'cupswrapper*dcp130c*' -type f 2>/dev/null | head -n 1)
    if [[ -n "$wrapper_script" ]]; then
        if grep -qF '/etc/init.d/lpd' "$wrapper_script"; then
            sed -i 's|/etc/init.d/lpd|/bin/true|g' "$wrapper_script"
        fi
        if grep -q 'lpadmin' "$wrapper_script"; then
            patch_lpadmin_calls "$wrapper_script"
        fi
        chmod 755 "$wrapper_script"
    else
        :
    fi
    
    
    log_info "Drivers prepared for ARM installation."
}

# Repackage drivers
repackage_drivers() {
    log_info "Repackaging drivers for ARM architecture..."
    
    # Repackage LPR driver
    dpkg-deb -b lpr_extract dcp130clpr_arm.deb
    
    # Repackage CUPS wrapper driver
    dpkg-deb -b cups_extract dcp130ccupswrapper_arm.deb
    
    log_info "Drivers repackaged successfully."
}

# Remove any duplicate Brother DCP-130C printers from CUPS.
# The cupswrapper postinst and the cupswrapper script itself call lpadmin
# to create a printer (typically named "DCP130C") every time the package
# is installed. This conflicts with our canonical printer name
# ($PRINTER_NAME = "Brother_DCP_130C"). This function detects ALL
# DCP-130C printers and removes any that are not $PRINTER_NAME, so only
# one properly-configured printer remains.
remove_duplicate_printers() {

    # List all CUPS printer names
    local all_printers
    all_printers=$(lpstat -e 2>/dev/null || true)

    # Known auto-created names from Brother's cupswrapper scripts,
    # plus common variations from manual/repeated installs.
    local known_variants=("DCP130C" "dcp130c" "DCP-130C" "Brother-DCP-130C")
    local removed=0

    # Helper: fully remove a printer queue AND its leftover PPD/config
    # files so CUPS does not re-create it on restart.
    _remove_printer() {
        local p="$1"
        sudo lpadmin -x "$p" 2>/dev/null || true
        # Remove leftover PPD and config that would cause CUPS to
        # resurrect the queue on next restart.
        sudo rm -f "/etc/cups/ppd/${p}.ppd" 2>/dev/null || true
        sudo rm -f "/etc/cups/ppd/${p}.ppd.O" 2>/dev/null || true
    }

    # First check known name variants
    for variant in "${known_variants[@]}"; do
        if [[ "$variant" == "$PRINTER_NAME" ]]; then
            continue  # don't remove our own printer
        fi
        if lpstat -p "$variant" &>/dev/null; then
            log_info "Removing duplicate printer '$variant' (auto-created by cupswrapper; we use '$PRINTER_NAME' instead)"
            _remove_printer "$variant"
            removed=$((removed + 1))
        fi
    done

    # Also scan for any other DCP-130C / dcp130c printers we might have missed
    if [[ -n "$all_printers" ]]; then
        while IFS= read -r printer; do
            # Skip our canonical printer name
            [[ "$printer" == "$PRINTER_NAME" ]] && continue
            # Match any DCP-130C/dcp130c name variant (case-insensitive)
            if echo "$printer" | grep -qi "dcp[-_.]130c\|dcp130c"; then
                log_info "Removing duplicate printer '$printer' (matches DCP-130C pattern)"
                _remove_printer "$printer"
                removed=$((removed + 1))
            fi
        done <<< "$all_printers"
    fi

    # Also clean up orphan PPD files for known duplicate names even if
    # the queue is already gone (prevents CUPS from re-creating them).
    local ppd
    for ppd in /etc/cups/ppd/*; do
        [[ -f "$ppd" ]] || continue
        local ppd_base
        ppd_base=$(basename "$ppd" | sed 's/\.ppd\.O$//;s/\.ppd$//')
        # Skip our canonical printer
        [[ "$ppd_base" == "$PRINTER_NAME" ]] && continue
        # Remove any PPD matching DCP-130C variants (case-insensitive)
        if echo "$ppd_base" | grep -qi "dcp[-_.]130c\|dcp130c"; then
            sudo rm -f "$ppd"
        fi
    done

    if [[ $removed -gt 0 ]]; then
        log_info "Removed $removed duplicate DCP-130C printer(s)."
    else
        :
    fi
}

# Install drivers
install_drivers() {
    log_info "Installing printer drivers..."
    
    # Clean up any broken dpkg state from previous failed installs
    if dpkg -s dcp130clpr &>/dev/null && dpkg -s dcp130clpr 2>/dev/null | grep -q "needs to be reinstalled\|half-installed\|half-configured"; then
        log_warn "Cleaning up broken dcp130clpr package state from previous install..."
        sudo dpkg --remove --force-remove-reinstreq dcp130clpr 2>/dev/null || true
    fi
    if dpkg -s dcp130ccupswrapper &>/dev/null && dpkg -s dcp130ccupswrapper 2>/dev/null | grep -q "needs to be reinstalled\|half-installed\|half-configured"; then
        log_warn "Cleaning up broken dcp130ccupswrapper package state from previous install..."
        sudo dpkg --remove --force-remove-reinstreq dcp130ccupswrapper 2>/dev/null || true
    fi
    
    # Install LPR driver
    log_info "Installing LPR driver..."
    if ! sudo dpkg -i --force-all dcp130clpr_arm.deb; then
        log_warn "LPR driver installation reported errors, attempting to fix dependencies..."
    fi
    
    # Install CUPS wrapper driver
    log_info "Installing CUPS wrapper driver..."
    if ! sudo dpkg -i --force-all dcp130ccupswrapper_arm.deb; then
        log_warn "CUPS wrapper driver installation reported errors, attempting to fix dependencies..."
    fi

    # Debug: show what printers dpkg postinst created
    
    # Fix any dependency issues
    sudo apt-get install -f -y || true

    # Patch the installed cupswrapper script if it still has /etc/init.d/lpd references
    # or lpadmin calls that would create a duplicate printer.
    local installed_wrapper="/usr/local/Brother/Printer/dcp130c/cupswrapper/cupswrapperdcp130c"
    if [[ -f "$installed_wrapper" ]]; then
        if grep -qF '/etc/init.d/lpd' "$installed_wrapper"; then
            sudo sed -i 's|/etc/init.d/lpd|/bin/true|g' "$installed_wrapper"
        fi
        if grep -q 'lpadmin' "$installed_wrapper"; then
            patch_lpadmin_calls "$installed_wrapper" sudo
        else
            :
        fi
    fi

    # Re-run the cupswrapper script to ensure filter pipeline is set up correctly.
    # The postinst may have failed partially due to /etc/init.d/lpd errors.
    # The lpadmin calls are already patched out, so this will only set up
    # the filter/PPD pipeline without creating any printer queues.
    if [[ -f "$installed_wrapper" ]]; then
        log_info "Re-running cupswrapper setup to ensure filter pipeline is configured..."
        sudo "$installed_wrapper" 2>&1 | while IFS= read -r line; do
            :
        done || log_warn "cupswrapper script returned non-zero exit code"
    fi

    # Debug: show printer state after cupswrapper re-run

    # Remove any auto-created DCP-130C printers. The cupswrapper postinst
    # (before our patches took effect) or a previous installation may have
    # created printers with various names. We check for all known variants
    # and remove any that are not our canonical $PRINTER_NAME, which is set
    # up later by configure_printer() with the correct URI and settings.
    remove_duplicate_printers

    # Verify the filter binary/script exists
    local filter_path="/usr/lib/cups/filter/brlpdwrapperdcp130c"
    if [[ -f "$filter_path" ]] || [[ -L "$filter_path" ]]; then
        :
    else
        # Check alternative locations
        local alt_filter
        alt_filter=$(find /usr/lib/cups/filter/ /usr/libexec/cups/filter/ -iname '*dcp130c*' 2>/dev/null | head -n 1)
        if [[ -n "$alt_filter" ]]; then
            :
        else
            log_warn "Brother filter not found in CUPS filter directory!"
        fi
    fi

    # Check if the Brother LPR binaries can execute on this architecture.
    # The driver is compiled for i386 — the main filter scripts (filterdcp130c,
    # brlpdwrapperdcp130c) are shell wrappers, but they call actual i386 ELF
    # binaries (e.g. brdcp130cfilter, brprintconfdcp130c) that need
    # binfmt_misc/qemu-user-static to run on ARM.
    #
    # can_execute_binary: test if a single binary can run on this system
    can_execute_binary() {
        local f="$1"
        "$f" --version &>/dev/null || "$f" --help &>/dev/null || "$f" &>/dev/null
    }

    local i386_binaries_found=0
    local i386_binaries_failed=0
    while IFS= read -r -d '' bin_file; do
        local bin_type
        bin_type=$(file "$bin_file" 2>/dev/null || echo 'unknown')
        if echo "$bin_type" | grep -qi "ELF.*Intel 80386\|ELF.*i386\|ELF.*x86-64\|ELF.*80386"; then
            i386_binaries_found=$((i386_binaries_found + 1))
            if ! can_execute_binary "$bin_file"; then
                i386_binaries_failed=$((i386_binaries_failed + 1))
            else
                :
            fi
        fi
    done < <(find /usr/local/Brother/Printer/dcp130c/ -type f -print0 2>/dev/null)

    if [[ $i386_binaries_found -gt 0 ]]; then
        if [[ $i386_binaries_failed -gt 0 ]]; then
            log_warn "$i386_binaries_failed of $i386_binaries_found Brother i386 binaries cannot execute on this ARM system."
            log_info "Setting up i386 binary support..."

            # Step 1: Ensure qemu-user-static is installed for binfmt_misc i386 emulation
            if ! dpkg -s qemu-user-static &>/dev/null; then
                log_info "Installing qemu-user-static..."
                sudo apt-get install -y qemu-user-static 2>&1 | tail -3
            else
                :
            fi

            # Step 2: Provide the i386 dynamic linker (/lib/ld-linux.so.2)
            # On Raspberry Pi OS (armhf), libc6:i386 is not available via apt
            # because i386 repos don't exist. We download it directly from
            # Debian mirrors and extract the needed files.
            if [[ ! -f /lib/ld-linux.so.2 ]] || [[ ! -f /lib/i386-linux-gnu/libc.so.6 ]]; then
                log_info "i386 libraries missing. Downloading from Debian mirrors..."
                local i386_tmp
                i386_tmp=$(mktemp -d)
                local libc6_deb="${i386_tmp}/libc6_i386.deb"
                local libc6_url="https://deb.debian.org/debian/pool/main/g/glibc/"

                # Find the latest libc6 i386 deb from Debian pool
                local libc6_filename
                libc6_filename=$(wget -q -O - "$libc6_url" 2>/dev/null \
                    | grep -oP 'libc6_[0-9][0-9.~+-]*_i386\.deb' \
                    | sort -V | tail -1)

                if [[ -n "$libc6_filename" ]]; then
                    if wget -q --timeout=30 -O "$libc6_deb" "${libc6_url}${libc6_filename}" 2>/dev/null; then
                        dpkg-deb -x "$libc6_deb" "${i386_tmp}/extract/" 2>/dev/null
                        # Debug: show what was extracted
                        # Copy ld-linux.so.2 to /lib/ where the kernel's binfmt_misc expects it
                        local ld_linux
                        ld_linux=$(find "${i386_tmp}/extract/" \( -name 'ld-linux.so.2' -o -name 'ld-linux*.so*' \) 2>/dev/null | head -1)
                        if [[ -n "$ld_linux" ]]; then
                            sudo cp "$ld_linux" /lib/ld-linux.so.2
                            sudo chmod 755 /lib/ld-linux.so.2
                            log_info "Installed i386 dynamic linker: /lib/ld-linux.so.2"
                        fi
                        # Find and copy i386 libs — glibc 2.43+ may use usr/lib/i386-linux-gnu/ instead of lib/i386-linux-gnu/
                        local i386_lib_dir
                        i386_lib_dir=$(find "${i386_tmp}/extract/" -type d -name 'i386-linux-gnu' 2>/dev/null | head -1)
                        if [[ -n "$i386_lib_dir" ]]; then
                            sudo mkdir -p /lib/i386-linux-gnu
                            sudo cp -a "${i386_lib_dir}/"* /lib/i386-linux-gnu/ 2>/dev/null || true
                        else
                            local libc_so
                            libc_so=$(find "${i386_tmp}/extract/" \( -name 'libc.so.6' -o -name 'libc-*.so' \) 2>/dev/null | head -1)
                            if [[ -n "$libc_so" ]]; then
                                local libc_dir
                                libc_dir=$(dirname "$libc_so")
                                sudo mkdir -p /lib/i386-linux-gnu
                                sudo cp -a "${libc_dir}/"*.so* /lib/i386-linux-gnu/ 2>/dev/null || true
                            else
                                log_warn "Could not find libc.so.6 anywhere in extracted package"
                            fi
                        fi
                        # Verify libc.so.6 was installed
                        if [[ -f /lib/i386-linux-gnu/libc.so.6 ]]; then
                            log_info "Installed i386 libc: /lib/i386-linux-gnu/libc.so.6"
                        else
                            log_warn "libc.so.6 not found at /lib/i386-linux-gnu/libc.so.6 after extraction"
                        fi
                        # Register i386 library paths with the dynamic linker
                        if ! grep -qsF 'i386-linux-gnu' /etc/ld.so.conf.d/i386-linux-gnu.conf 2>/dev/null; then
                            printf "/lib/i386-linux-gnu\n/usr/lib/i386-linux-gnu\n" | sudo tee /etc/ld.so.conf.d/i386-linux-gnu.conf > /dev/null
                        fi
                        sudo ldconfig 2>/dev/null || true
                    else
                        log_warn "Could not download libc6 i386 from Debian mirrors."
                    fi
                else
                    log_warn "Could not find libc6 i386 package in Debian pool."
                fi
                rm -rf "$i386_tmp"
            else
                :
            fi

            # Fix Raspberry Pi /etc/ld.so.preload that causes errors under qemu-user-static.
            # The ARM-specific libarmmem library preload makes i386 binaries emit errors.
            # We comment out the libarmmem line so it doesn't interfere with i386 execution.
            if [[ -f /etc/ld.so.preload ]] && grep -q 'libarmmem' /etc/ld.so.preload 2>/dev/null; then
                log_info "Fixing /etc/ld.so.preload for i386 compatibility..."
                sudo sed -i 's|^[[:space:]]*/usr/lib/arm-linux-gnueabihf/libarmmem|# Commented for i386 compat: /usr/lib/arm-linux-gnueabihf/libarmmem|' /etc/ld.so.preload
            fi

            # Re-check binaries after installing i386 support
            log_info "Re-checking binaries..."
            local recheck_failed=0
            while IFS= read -r -d '' bin_file; do
                local bin_type
                bin_type=$(file "$bin_file" 2>/dev/null || echo 'unknown')
                if echo "$bin_type" | grep -qi "ELF.*Intel 80386\|ELF.*i386\|ELF.*x86-64\|ELF.*80386"; then
                    if ! can_execute_binary "$bin_file"; then
                        recheck_failed=$((recheck_failed + 1))
                        local run_err
                        run_err=$("$bin_file" 2>&1 || true)
                    fi
                fi
            done < <(find /usr/local/Brother/Printer/dcp130c/ -type f -print0 2>/dev/null)
            if [[ $recheck_failed -gt 0 ]]; then
                log_warn "$recheck_failed binaries still can't execute. Printing may not work."
                log_warn "The Brother i386 binaries need additional i386 libraries."
                log_warn "Check: file /usr/local/Brother/Printer/dcp130c/lpd/brdcp130cfilter"
                log_warn "Then run the binary directly to see what libraries are missing."
            else
                log_info "All Brother binaries now execute successfully."
            fi
        else
            log_info "All Brother i386 binaries execute successfully on this ARM system."
        fi
    else
        :
    fi

    # Restore original Brother filter if it was previously wrapped.
    # Previous versions wrapped brlpdwrapperdcp130c with a Ghostscript
    # grayscale converter, but this caused "No pages found!" errors
    # because Ghostscript's ps2write output is incompatible with the
    # Brother binary filter. The Brother driver has its own native
    # BRMonoColor option for grayscale — no wrapper is needed.
    local brother_filter="/usr/lib/cups/filter/brlpdwrapperdcp130c"
    if [[ -f "${brother_filter}.real" ]]; then
        sudo mv -f "${brother_filter}.real" "$brother_filter"
    fi

    # Patch the Brother filter script to translate CUPS color mode options
    # to the Brother-specific BRMonoColor option.
    #
    # When Android/iOS sends print-color-mode=monochrome, CUPS maps it to
    # ColorModel=Gray (standard PPD option). But the Brother driver reads
    # BRMonoColor (a Brother-specific PPD option) and ignores ColorModel.
    # This patch injects BRMonoColor=BrMono into the options when the CUPS
    # options contain ColorModel=Gray or print-color-mode=monochrome.
    if [[ -f "$brother_filter" ]]; then
        if ! grep -q 'BRMonoColor' "$brother_filter"; then
            # Insert color mode translation right after the shebang line
            sudo sed -i '1 a\
# --- Grayscale patch: translate CUPS ColorModel to Brother BRMonoColor ---\
# CUPS maps IPP print-color-mode=monochrome to ColorModel=Gray,\
# but the Brother driver reads BRMonoColor instead of ColorModel.\
case "$5" in\
  *ColorModel=Gray*|*print-color-mode=monochrome*)\
    set -- "$1" "$2" "$3" "$4" "$(echo "$5" | sed '\''s/BRMonoColor=BrColor/BRMonoColor=BrMono/g'\'') BRMonoColor=BrMono" "$6"\
    ;;\
esac\
# --- End grayscale patch ---' "$brother_filter"
        else
            :
        fi
    fi

    # Restart CUPS to pick up new filters
    sudo systemctl restart cups 2>/dev/null || true

    log_info "Drivers installed successfully."
}

# Detect printer USB connection
detect_printer() {
    log_info "Detecting Brother DCP-130C printer..."
    
    
    # Check USB connection
    if lsusb | grep -i "Brother"; then
        log_info "Brother printer detected on USB."
        lsusb | grep -i "Brother"
    else
        log_warn "Brother printer not detected on USB. Please ensure the printer is connected and powered on."
    fi
    
    
    # Check printer device
    if lpinfo -v | grep -i "Brother"; then
        log_info "Printer device found:"
        lpinfo -v | grep -i "Brother"
    else
        log_warn "Printer device not found in CUPS. Continuing with installation..."
    fi
}

# Configure printer in CUPS
configure_printer() {
    log_info "Configuring printer in CUPS..."

    # Remove any duplicate DCP-130C printers that may have been created
    # by a previous install or by the cupswrapper postinst before our
    # lpadmin patches took effect.
    remove_duplicate_printers
    
    # Get the printer URI
    PRINTER_URI=$(lpinfo -v | grep -i "Brother.*DCP-130C" | awk '{print $2}' | head -n 1)
    
    if [[ -z "$PRINTER_URI" ]]; then
        log_warn "Could not auto-detect printer URI. Using default USB URI."
        PRINTER_URI="usb://Brother/DCP-130C"
    fi
    
    log_info "Printer URI: $PRINTER_URI"
    
    # Remove existing printer if it exists
    lpstat -p "$PRINTER_NAME" &>/dev/null && {
        log_info "Removing existing printer configuration..."
        sudo lpadmin -x "$PRINTER_NAME"
    }
    
    # Search for PPD file in common locations
    local ppd_file=""
    local ppd_search_paths=(
        "/usr/share/cups/model/Brother/brother_dcp130c_printer_en.ppd"
        "/usr/share/cups/model/brother_dcp130c_printer_en.ppd"
    )
    
    # Also search dynamically
    local found_ppd
    found_ppd=$(find /usr/share/cups/model/ /usr/share/ppd/ /opt/brother/ -iname '*dcp130c*.ppd' 2>/dev/null | head -n 1)
    if [[ -n "$found_ppd" ]]; then
        ppd_search_paths=("$found_ppd" "${ppd_search_paths[@]}")
    fi
    
    for path in "${ppd_search_paths[@]}"; do
        if [[ -f "$path" ]]; then
            ppd_file="$path"
            break
        fi
    done

    # Patch the discovered PPD to advertise print-color-mode support.
    # The original Brother PPD has a BRMonoColor option for grayscale
    # but doesn't include the IPP color-mode attributes that Android/iOS
    # need to map their "Black & White" option. We add APPrinterPreset
    # entries that map IPP print-color-mode to the Brother driver's
    # native BRMonoColor option.
    if [[ -n "$ppd_file" ]] && ! grep -q 'APPrinterPreset' "$ppd_file"; then
        local patched_ppd
        patched_ppd=$(mktemp /tmp/brother_dcp130c_patched.XXXXXX.ppd)
        cp "$ppd_file" "$patched_ppd"
        cat >> "$patched_ppd" << 'COLORPATCH'

*% IPP print-color-mode mapping for Android/iOS printing.
*% Maps to Brother's native BRMonoColor option which the driver
*% understands natively — no Ghostscript conversion needed.
*cupsIPPSupplies: True
*APPrinterPreset Color/Color: "*BRMonoColor BrColor"
*APPrinterPreset Grayscale/Grayscale: "*BRMonoColor BrMono"
COLORPATCH
        ppd_file="$patched_ppd"
    fi
    
    # Check if we also have a PPD via lpinfo -m (CUPS driver list)
    if [[ -z "$ppd_file" ]]; then
        local cups_driver
        cups_driver=$(lpinfo -m 2>/dev/null | grep -i "dcp.*130c\|DCP-130C" | awk '{print $1}' | head -n 1)
        if [[ -n "$cups_driver" ]]; then
            log_info "Found CUPS driver: $cups_driver"
            log_info "Adding printer to CUPS using driver..."
            local share_opt="printer-is-shared=$PRINTER_SHARED"
            sudo lpadmin -p "$PRINTER_NAME" \
                -v "$PRINTER_URI" \
                -m "$cups_driver" \
                -E \
                -o "$share_opt"

            # Set color mode options so Android/IPP clients can switch
            # between color and monochrome printing.
            sudo lpadmin -p "$PRINTER_NAME" \
                -o print-color-mode-default=color \
                -o print-color-mode-supported=color,monochrome \
                -o ColorModel=RGB

            # Debug: verify options were set
            
            sudo lpadmin -d "$PRINTER_NAME"
            sudo cupsenable "$PRINTER_NAME"
            sudo cupsaccept "$PRINTER_NAME"
            log_info "Printer configured successfully."
            return
        fi
    fi
    
    if [[ -z "$ppd_file" ]]; then
        log_warn "PPD file not found. Generating a basic PPD for Brother DCP-130C..."
        ppd_file=$(mktemp /tmp/brother_dcp130c.XXXXXX.ppd)
        cat > "$ppd_file" << 'PPEOF'
*PPD-Adobe: "4.3"
*FormatVersion: "4.3"
*FileVersion: "1.0"
*LanguageVersion: English
*LanguageEncoding: ISOLatin1
*PCFileName: "DCP130C.PPD"
*Manufacturer: "Brother"
*Product: "(Brother DCP-130C)"
*ModelName: "Brother DCP-130C"
*ShortNickName: "Brother DCP-130C"
*NickName: "Brother DCP-130C"
*PSVersion: "(3010.000) 550"
*LanguageLevel: "3"
*ColorDevice: True
*DefaultColorSpace: RGB
*FileSystem: False
*Throughput: "12"
*LandscapeOrientation: Plus90
*TTRasterizer: Type42
*cupsFilter: "application/vnd.cups-raster 0 brlpdwrapperdcp130c"
*cupsModelNumber: 0

*OpenUI *PageSize/Media Size: PickOne
*OrderDependency: 10 AnySetup *PageSize
*DefaultPageSize: Letter
*PageSize Letter/US Letter: "<</PageSize[612 792]>>setpagedevice"
*PageSize A4/A4: "<</PageSize[595 842]>>setpagedevice"
*PageSize Legal/US Legal: "<</PageSize[612 1008]>>setpagedevice"
*CloseUI: *PageSize

*OpenUI *PageRegion: PickOne
*OrderDependency: 10 AnySetup *PageRegion
*DefaultPageRegion: Letter
*PageRegion Letter/US Letter: "<</PageRegion[612 792]>>setpagedevice"
*PageRegion A4/A4: "<</PageRegion[595 842]>>setpagedevice"
*PageRegion Legal/US Legal: "<</PageRegion[612 1008]>>setpagedevice"
*CloseUI: *PageRegion

*DefaultImageableArea: Letter
*ImageableArea Letter/US Letter: "18 18 594 774"
*ImageableArea A4/A4: "18 18 577 824"
*ImageableArea Legal/US Legal: "18 18 594 990"

*DefaultPaperDimension: Letter
*PaperDimension Letter/US Letter: "612 792"
*PaperDimension A4/A4: "595 842"
*PaperDimension Legal/US Legal: "612 1008"

*OpenUI *Resolution/Resolution: PickOne
*OrderDependency: 20 AnySetup *Resolution
*DefaultResolution: 600dpi
*Resolution 300dpi/300 DPI: "<</HWResolution[300 300]>>setpagedevice"
*Resolution 600dpi/600 DPI: "<</HWResolution[600 600]>>setpagedevice"
*Resolution 1200dpi/1200 DPI: "<</HWResolution[1200 1200]>>setpagedevice"
*CloseUI: *Resolution

*OpenUI *ColorModel/Color Mode: PickOne
*OrderDependency: 10 AnySetup *ColorModel
*DefaultColorModel: RGB
*ColorModel RGB/Color: "<</cupsColorOrder 0/cupsColorSpace 1/cupsCompression 1/cupsBitsPerColor 8>>setpagedevice"
*ColorModel Gray/Grayscale: "<</cupsColorOrder 0/cupsColorSpace 0/cupsCompression 1/cupsBitsPerColor 8>>setpagedevice"
*CloseUI: *ColorModel

*cupsIPPSupplies: True
*cupsLanguages: "en"

*% Map IPP print-color-mode to ColorModel so Android/iOS color
*% choices (monochrome / color) are applied correctly.
*APPrinterPreset Color/Color: "*ColorModel RGB"
*APPrinterPreset Grayscale/Grayscale: "*ColorModel Gray"
PPEOF
    fi
    
    # Add the printer
    local share_opt="printer-is-shared=$PRINTER_SHARED"
    log_info "Adding printer to CUPS..."
    sudo lpadmin -p "$PRINTER_NAME" \
        -v "$PRINTER_URI" \
        -P "$ppd_file" \
        -E \
        -o "$share_opt"

    # Set color mode options so Android/IPP clients can switch
    # between color and monochrome printing.
    sudo lpadmin -p "$PRINTER_NAME" \
        -o print-color-mode-default=color \
        -o print-color-mode-supported=color,monochrome \
        -o ColorModel=RGB

    # Verify the installed PPD and Brother filter
    local installed_ppd="/etc/cups/ppd/${PRINTER_NAME}.ppd"
    if [[ -f "$installed_ppd" ]]; then
        # Ensure no stale cupsFilter2 entries from previous installs
        if grep -q 'cupsFilter2.*brother_grayscale_prefilter' "$installed_ppd"; then
            sudo sed -i '/cupsFilter2.*brother_grayscale_prefilter/d' "$installed_ppd"
        fi
    fi

    # Debug: verify PPD options are visible to CUPS
    
    # Set as default printer
    sudo lpadmin -d "$PRINTER_NAME"
    
    # Enable the printer
    sudo cupsenable "$PRINTER_NAME"
    sudo cupsaccept "$PRINTER_NAME"
    
    log_info "Printer configured successfully."
}

# Test print
test_print() {
    log_info "Testing printer..."
    
    # Check printer status
    lpstat -p "$PRINTER_NAME"
    
    # Ask user if they want to print a test page
    read -p "Do you want to print a test page? (y/n): " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        # Create a simple test page
        cat > /tmp/test_page.txt << EOF
Brother DCP-130C Test Page
==========================

This is a test print from your Brother DCP-130C printer.

If you can read this, your printer is working correctly!

Date: $(date)
Hostname: $(hostname)
User: $USER

Congratulations! Your printer installation was successful.
EOF
        
        # Record CUPS error log position before printing
        local log_lines_before=0
        if [[ -f /var/log/cups/error_log ]]; then
            log_lines_before=$(wc -l < /var/log/cups/error_log 2>/dev/null || echo 0)
        fi

        # Temporarily enable CUPS debug logging to capture filter pipeline details
        local cups_log_level_changed=0
        local current_log_level="warn"
        if [[ "$DEBUG" == "1" ]]; then
            current_log_level=$(grep -i "^LogLevel" /etc/cups/cupsd.conf 2>/dev/null | awk '{print $2}' || echo "warn")
            if [[ "$current_log_level" != "debug" && "$current_log_level" != "debug2" ]]; then
                sudo sed -i "s/^LogLevel .*/LogLevel debug/" /etc/cups/cupsd.conf 2>/dev/null || true
                sudo systemctl restart cups 2>/dev/null || true
                sleep 2
                cups_log_level_changed=1
                # Update log position after restart
                if [[ -f /var/log/cups/error_log ]]; then
                    log_lines_before=$(wc -l < /var/log/cups/error_log 2>/dev/null || echo 0)
                fi
            fi
        fi
        
        # Print the test page
        log_info "Sending test page to printer..."
        local job_output
        job_output=$(lpr -P "$PRINTER_NAME" /tmp/test_page.txt 2>&1) || true
        
        # Wait for the job to be processed
        sleep 5
        
        # Show job status and diagnostics
        log_info "Test page sent. Checking job status..."
        
        local printer_status
        printer_status=$(lpstat -p "$PRINTER_NAME" 2>/dev/null || echo 'unknown')
        log_info "Printer status: $printer_status"
        
        # Show all recent jobs for this printer
        
        # Check CUPS error log for new entries since we sent the job
        if [[ -f /var/log/cups/error_log ]]; then
            local new_log_entries
            new_log_entries=$(tail -n +"$((log_lines_before + 1))" /var/log/cups/error_log 2>/dev/null || true)
            if [[ -n "$new_log_entries" ]]; then
                # Filter to show only important lines (errors, warnings, job/filter activity)
                # Skip verbose IPP client chatter (Client N, HTTP, Content-Length, etc.)
                local important_entries
                important_entries=$(echo "$new_log_entries" \
                    | grep -iE "^\w \[.*\] \[Job [0-9]|^E \[|filter|backend|Started |PID [0-9]+ .* exited|ld-linux|Could not open|Sent [0-9]+ bytes" \
                    | grep -viE "envp\[|argv\[" || true)
                if [[ -n "$important_entries" ]]; then
                    :
                fi
                # Check for actual filter/backend errors (NOT normal client disconnects)
                if echo "$new_log_entries" | grep -qiE "\[Job [0-9]+\].*(not available|no such file|filter failed|exec format error|ld-linux|Could not open|cannot open shared object|libarmmem)" \
                    || echo "$new_log_entries" | grep -qP "\[Job [0-9]+\].*Sent 0 bytes"; then
                    log_warn "CUPS filter errors detected — the filter pipeline is not working correctly."
                    if echo "$new_log_entries" | grep -qiE "ld-linux|Could not open|cannot open shared object"; then
                        log_warn "Root cause: i386 shared libraries are missing or not found."
                        log_warn "The Brother driver binary cannot execute without them."
                        log_warn "Re-run this script to attempt automatic fix, or see README for manual steps."
                    elif echo "$new_log_entries" | grep -qiE "libarmmem"; then
                        log_warn "Root cause: ARM-specific preload library interfering with i386 emulation."
                        log_warn "Re-run this script — it will fix /etc/ld.so.preload automatically."
                    else
                        log_warn "This usually means the Brother i386 binary can't run on ARM."
                    fi
                fi
            else
                :
            fi
        fi

        # Wait for the print job to leave the queue before restarting CUPS
        # (restarting while the job is active would kill it)
        local wait_count=0
        while lpq -P "$PRINTER_NAME" 2>/dev/null | grep -q "active\|pending" && [[ $wait_count -lt 30 ]]; do
            sleep 2
            wait_count=$((wait_count + 1))
        done
        if [[ $wait_count -ge 30 ]]; then
            log_warn "Print job still in queue after 60 seconds. It may be stuck."
        fi

        # Restore CUPS log level if we changed it
        if [[ $cups_log_level_changed -eq 1 ]]; then
            sudo sed -i "s/^LogLevel .*/LogLevel $current_log_level/" /etc/cups/cupsd.conf 2>/dev/null || true
            sudo systemctl restart cups 2>/dev/null || true
        fi
        
        log_info "Test page sent to printer. Please check the printer output."
        log_info "If nothing printed, check CUPS logs: sudo tail -50 /var/log/cups/error_log"
    else
        log_info "Skipping test print."
    fi
}

# Cleanup
cleanup() {
    log_info "Cleaning up temporary files..."
    cd ~
    # Safety check: only remove if TMP_DIR is set and not empty
    if [[ -n "$TMP_DIR" && "$TMP_DIR" != "/" ]]; then
        rm -rf "$TMP_DIR"
        log_info "Cleanup complete."
    else
        log_warn "Skipping cleanup: TMP_DIR not properly set."
    fi
}

# Display printer information
display_info() {
    log_info "============================================"
    log_info "Brother DCP-130C Printer Installation Complete!"
    log_info "============================================"
    echo
    log_info "Printer Name: $PRINTER_NAME"
    log_info "Printer Status:"
    lpstat -p "$PRINTER_NAME" || true
    echo
    if [[ "$PRINTER_SHARED" == true ]]; then
        local ip_addr
        ip_addr=$(hostname -I 2>/dev/null | awk '{print $1}')
        log_info "Printer sharing: ENABLED"
        log_info "Other devices on the network can discover and use this printer."
        log_info "Android: The printer will appear automatically in the Default Print Service."
        log_info "         If you see stale/dead printers on Android, go to"
        log_info "         Settings > Apps > Default Print Service > Storage > Clear Cache"
        if [[ -n "$ip_addr" ]]; then
            log_info "CUPS web interface: http://${ip_addr}:631"
        fi
    else
        log_info "Printer sharing: DISABLED (local only)"
    fi
    echo
    log_info "To print a file, use: lpr -P $PRINTER_NAME <filename>"
    log_info "To check printer status: lpstat -p $PRINTER_NAME"
    log_info "To view print queue: lpq -P $PRINTER_NAME"
    log_info "To manage printer: http://localhost:631"
    echo
    log_info "If you were added to the lpadmin group, you may need to log out and back in."
}

# Main installation process
main() {
    log_info "Starting Brother DCP-130C printer driver installation..."
    echo
    
    check_root
    check_architecture
    ask_printer_sharing
    fix_broken_packages
    install_dependencies
    setup_cups_service
    create_temp_dir
    download_drivers
    extract_and_modify_drivers
    repackage_drivers
    install_drivers
    detect_printer
    configure_printer
    test_print
    cleanup

    # Final cleanup: remove any duplicate printers that may have been
    # re-created by CUPS restarts during installation.  This must be the
    # last step before displaying results.
    remove_duplicate_printers
    # Restart CUPS once more so it forgets the removed queues
    sudo systemctl restart cups 2>/dev/null || true
    # Brief pause to let CUPS settle, then verify
    sleep 2

    display_info
    
    log_info "Installation script completed successfully!"
}

# Run main function
main
