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
PRINTER_MODEL="DCP-130C"
PRINTER_NAME="Brother_DCP_130C"
TMP_DIR="/tmp/brother_dcp130c_install"
DRIVER_LPR_URL="https://download.brother.com/welcome/dlf006646/dcp130clpr-1.1.2-1.i386.deb"
DRIVER_CUPS_URL="https://download.brother.com/welcome/dlf006648/dcp130ccupswrapper-1.1.2-1.i386.deb"

# Check if running as root
check_root() {
    log_debug "EUID=$EUID, USER=$USER"
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
    log_debug "Kernel: $(uname -r)"
    log_debug "OS: $(grep -E '^(PRETTY_NAME|VERSION_ID)=' /etc/os-release 2>/dev/null | tr '\n' ' ')"
    
    if [[ "$ARCH" != "armv7l" && "$ARCH" != "armv6l" && "$ARCH" != "aarch64" ]]; then
        log_warn "This script is designed for ARM architecture (Raspberry Pi). Detected: $ARCH"
        read -p "Continue anyway? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
}

# Check if a package (or its t64 variant) is already installed.
# Returns 0 if installed, 1 otherwise. Prints the installed package name.
is_package_installed() {
    local pkg="$1"
    if dpkg -s "$pkg" &>/dev/null; then
        log_debug "is_package_installed: '$pkg' is installed"
        echo "$pkg"
        return 0
    fi
    local t64_pkg="${pkg}t64"
    if dpkg -s "$t64_pkg" &>/dev/null; then
        log_debug "is_package_installed: '$t64_pkg' is installed (t64 variant of '$pkg')"
        echo "$t64_pkg"
        return 0
    fi
    log_debug "is_package_installed: '$pkg' is NOT installed"
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
        log_debug "resolve_package: '$pkg' already installed as '$installed'"
        echo "$installed"
        return
    fi
    # Not installed - check which variant is available in apt
    local policy
    local candidate
    log_debug "resolve_package: checking apt for '$pkg'"
    policy=$(apt-cache policy "$pkg" 2>/dev/null)
    candidate=$(echo "$policy" | grep "Candidate:" | awk '{print $2}')
    log_debug "resolve_package: '$pkg' candidate='$candidate'"
    if [[ -n "$candidate" && "$candidate" != "(none)" ]]; then
        log_debug "resolve_package: resolved '$pkg' -> '$pkg'"
        echo "$pkg"
        return
    fi
    # Try the t64 variant
    local t64_pkg="${pkg}t64"
    log_debug "resolve_package: trying t64 variant '$t64_pkg'"
    policy=$(apt-cache policy "$t64_pkg" 2>/dev/null)
    candidate=$(echo "$policy" | grep "Candidate:" | awk '{print $2}')
    log_debug "resolve_package: '$t64_pkg' candidate='$candidate'"
    if [[ -n "$candidate" && "$candidate" != "(none)" ]]; then
        log_debug "resolve_package: resolved '$pkg' -> '$t64_pkg'"
        echo "$t64_pkg"
        return
    fi
    # Fall back to the original name and let apt-get report the error
    log_debug "resolve_package: no candidate found, falling back to '$pkg'"
    echo "$pkg"
}

# Install required dependencies
install_dependencies() {
    log_info "Installing required dependencies..."
    
    log_debug "Running apt-get update..."
    sudo apt-get update
    
    # Detect CUPS status
    if command -v systemctl &>/dev/null && systemctl is-active cups &>/dev/null; then
        log_info "CUPS is already running on this system."
        log_debug "CUPS version: $(cups-config --version 2>/dev/null || dpkg -s cups 2>/dev/null | awk '/^Version:/ {print $2}' || echo 'unknown')"
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
        psutils
        a2ps
    )

    log_debug "Final package list: ${packages[*]}"

    # Install CUPS and required tools
    sudo apt-get install -y "${packages[@]}"
    
    # Try to install 32-bit libraries (may not be available on all ARM systems)
    sudo apt-get install -y \
        lib32gcc-s1 \
        lib32stdc++6 \
        libc6-i386 2>/dev/null || log_warn "32-bit libraries not available (not required on ARM)"
    
    log_info "Dependencies installed successfully."
}

# Enable and start CUPS service
setup_cups_service() {
    log_info "Setting up CUPS service..."
    
    sudo systemctl enable cups
    sudo systemctl start cups
    log_debug "CUPS service status: $(systemctl is-active cups 2>/dev/null || echo 'unknown')"
    
    # Add user to lpadmin group if not already
    if ! groups "$USER" | grep -q lpadmin; then
        sudo usermod -a -G lpadmin "$USER"
        log_info "Added $USER to lpadmin group. You may need to log out and back in for this to take effect."
    else
        log_debug "User $USER is already in lpadmin group"
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

# Download printer drivers
download_drivers() {
    log_info "Downloading Brother DCP-130C printer drivers..."
    
    # Download LPR driver
    log_info "Downloading LPR driver..."
    log_debug "LPR driver URL: $DRIVER_LPR_URL"
    wget --secure-protocol=auto --https-only -O dcp130clpr.deb "$DRIVER_LPR_URL" || {
        log_error "Failed to download LPR driver. Please check your internet connection."
        exit 1
    }
    log_debug "LPR driver downloaded: $(ls -lh dcp130clpr.deb)"
    
    # Download CUPS wrapper driver
    log_info "Downloading CUPS wrapper driver..."
    log_debug "CUPS wrapper URL: $DRIVER_CUPS_URL"
    wget --secure-protocol=auto --https-only -O dcp130ccupswrapper.deb "$DRIVER_CUPS_URL" || {
        log_error "Failed to download CUPS wrapper driver. Please check your internet connection."
        exit 1
    }
    log_debug "CUPS wrapper downloaded: $(ls -lh dcp130ccupswrapper.deb)"
    
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
    log_debug "LPR control before modification:"
    log_debug "$(cat lpr_extract/DEBIAN/control)"
    
    # Extract CUPS wrapper driver
    log_info "Extracting CUPS wrapper driver..."
    dpkg-deb -x dcp130ccupswrapper.deb cups_extract/
    dpkg-deb -e dcp130ccupswrapper.deb cups_extract/DEBIAN
    log_debug "CUPS wrapper control before modification:"
    log_debug "$(cat cups_extract/DEBIAN/control)"
    
    # Modify control files to remove architecture restrictions
    sed -i 's/Architecture: .*/Architecture: all/' lpr_extract/DEBIAN/control
    sed -i 's/Architecture: .*/Architecture: all/' cups_extract/DEBIAN/control
    log_debug "LPR control after modification:"
    log_debug "$(cat lpr_extract/DEBIAN/control)"
    log_debug "CUPS wrapper control after modification:"
    log_debug "$(cat cups_extract/DEBIAN/control)"
    
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

# Install drivers
install_drivers() {
    log_info "Installing printer drivers..."
    
    # Install LPR driver
    log_info "Installing LPR driver..."
    log_debug "LPR package: $(ls -lh dcp130clpr_arm.deb)"
    if ! sudo dpkg -i --force-architecture dcp130clpr_arm.deb; then
        log_warn "LPR driver installation reported errors, attempting to fix dependencies..."
    fi
    
    # Install CUPS wrapper driver
    log_info "Installing CUPS wrapper driver..."
    log_debug "CUPS wrapper package: $(ls -lh dcp130ccupswrapper_arm.deb)"
    if ! sudo dpkg -i --force-architecture dcp130ccupswrapper_arm.deb; then
        log_warn "CUPS wrapper driver installation reported errors, attempting to fix dependencies..."
    fi
    
    # Fix any dependency issues
    log_debug "Running apt-get install -f to fix dependencies..."
    sudo apt-get install -f -y || true
    
    log_info "Drivers installed successfully."
}

# Detect printer USB connection
detect_printer() {
    log_info "Detecting Brother DCP-130C printer..."
    
    log_debug "USB devices:"
    log_debug "$(lsusb 2>/dev/null || echo 'lsusb not available')"
    
    # Check USB connection
    if lsusb | grep -i "Brother"; then
        log_info "Brother printer detected on USB."
        lsusb | grep -i "Brother"
    else
        log_warn "Brother printer not detected on USB. Please ensure the printer is connected and powered on."
    fi
    
    log_debug "CUPS backends:"
    log_debug "$(lpinfo -v 2>/dev/null || echo 'lpinfo not available')"
    
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
    
    # Get the printer URI
    PRINTER_URI=$(lpinfo -v | grep -i "Brother.*DCP-130C" | awk '{print $2}' | head -n 1)
    log_debug "Auto-detected printer URI: '${PRINTER_URI:-<empty>}'"
    
    if [[ -z "$PRINTER_URI" ]]; then
        log_warn "Could not auto-detect printer URI. Using default USB URI."
        PRINTER_URI="usb://Brother/DCP-130C"
    fi
    
    log_info "Printer URI: $PRINTER_URI"
    
    # Remove existing printer if it exists
    lpstat -p "$PRINTER_NAME" &>/dev/null && {
        log_info "Removing existing printer configuration..."
        log_debug "Removing printer: $PRINTER_NAME"
        sudo lpadmin -x "$PRINTER_NAME"
    }
    
    # Check for PPD file
    local ppd_file="/usr/share/cups/model/Brother/brother_dcp130c_printer_en.ppd"
    log_debug "Looking for PPD file: $ppd_file"
    if [[ -f "$ppd_file" ]]; then
        log_debug "PPD file found: $(ls -lh "$ppd_file")"
    else
        log_warn "PPD file not found at $ppd_file"
        log_debug "Available Brother PPDs: $(find /usr/share/cups/model/ -iname '*brother*' 2>/dev/null || echo 'none')"
    fi
    
    # Add the printer
    log_info "Adding printer to CUPS..."
    log_debug "lpadmin -p $PRINTER_NAME -v $PRINTER_URI -P $ppd_file -E -o printer-is-shared=false"
    sudo lpadmin -p "$PRINTER_NAME" \
        -v "$PRINTER_URI" \
        -P "$ppd_file" \
        -E \
        -o printer-is-shared=false
    
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
        
        # Print the test page
        log_info "Sending test page to printer..."
        lpr -P "$PRINTER_NAME" /tmp/test_page.txt
        
        log_info "Test page sent to printer. Please check the printer output."
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
    if [[ "$DEBUG" == "1" ]]; then
        log_debug "Debug mode is active"
        log_debug "Script: $0"
        log_debug "Date: $(date)"
        log_debug "Shell: $BASH_VERSION"
        log_debug "System: $(uname -a)"
    fi
    echo
    
    check_root
    check_architecture
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
    display_info
    
    log_info "Installation script completed successfully!"
}

# Run main function
main
