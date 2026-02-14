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

# Try downloading a file from multiple URLs until one succeeds.
# Usage: try_download output_file url1 url2 url3 ...
# Returns 0 on success, 1 if all URLs fail.
try_download() {
    local output_file="$1"
    shift
    local urls=("$@")
    
    for url in "${urls[@]}"; do
        log_debug "Trying download: $url"
        if wget -q --timeout=30 --tries=2 -O "$output_file" "$url" 2>/dev/null; then
            # Verify we got an actual file (not an HTML error page)
            if [[ -s "$output_file" ]] && file "$output_file" | grep -qi "debian\|archive\|data"; then
                log_info "Downloaded successfully from: $url"
                return 0
            fi
            log_debug "Download from $url succeeded but file appears invalid, trying next..."
            rm -f "$output_file"
        else
            log_debug "Download failed from: $url"
        fi
    done
    
    return 1
}

# Download printer drivers
download_drivers() {
    log_info "Downloading Brother DCP-130C printer drivers..."
    
    # Download LPR driver
    log_info "Downloading LPR driver (${DRIVER_LPR_FILE})..."
    log_debug "LPR driver URLs to try: ${DRIVER_LPR_URLS[*]}"
    if ! try_download dcp130clpr.deb "${DRIVER_LPR_URLS[@]}"; then
        log_error "Failed to download LPR driver from all sources."
        log_error "URLs tried:"
        for url in "${DRIVER_LPR_URLS[@]}"; do
            log_error "  - $url"
        done
        log_error "Please download ${DRIVER_LPR_FILE} manually and place it in ${TMP_DIR}/"
        exit 1
    fi
    log_debug "LPR driver downloaded: $(ls -lh dcp130clpr.deb)"
    
    # Download CUPS wrapper driver
    log_info "Downloading CUPS wrapper driver (${DRIVER_CUPS_FILE})..."
    log_debug "CUPS wrapper URLs to try: ${DRIVER_CUPS_URLS[*]}"
    if ! try_download dcp130ccupswrapper.deb "${DRIVER_CUPS_URLS[@]}"; then
        log_error "Failed to download CUPS wrapper driver from all sources."
        log_error "URLs tried:"
        for url in "${DRIVER_CUPS_URLS[@]}"; do
            log_error "  - $url"
        done
        log_error "Please download ${DRIVER_CUPS_FILE} manually and place it in ${TMP_DIR}/"
        exit 1
    fi
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
    
    # Remove the placeholder CONFLICT_PACKAGE from CUPS wrapper control
    sed -i '/^Conflicts: CONFLICT_PACKAGE$/d' cups_extract/DEBIAN/control
    
    # Fix maintainer scripts that reference /etc/init.d/lpd which doesn't
    # exist on modern systems and causes "Permission denied" errors.
    # Replace calls to /etc/init.d/lpd with a harmless no-op.
    for script_dir in lpr_extract/DEBIAN cups_extract/DEBIAN; do
        for script in preinst postinst prerm postrm; do
            if [[ -f "$script_dir/$script" ]]; then
                if grep -q '/etc/init.d/lpd' "$script_dir/$script"; then
                    log_debug "Patching $script_dir/$script: removing /etc/init.d/lpd references"
                    sed -i 's|/etc/init.d/lpd|/bin/true|g' "$script_dir/$script"
                fi
                # Ensure script is executable
                chmod 755 "$script_dir/$script"
            fi
        done
    done
    
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
    log_debug "LPR package: $(ls -lh dcp130clpr_arm.deb)"
    if ! sudo dpkg -i --force-all dcp130clpr_arm.deb; then
        log_warn "LPR driver installation reported errors, attempting to fix dependencies..."
    fi
    
    # Install CUPS wrapper driver
    log_info "Installing CUPS wrapper driver..."
    log_debug "CUPS wrapper package: $(ls -lh dcp130ccupswrapper_arm.deb)"
    if ! sudo dpkg -i --force-all dcp130ccupswrapper_arm.deb; then
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
    
    # Search for PPD file in common locations
    local ppd_file=""
    local ppd_search_paths=(
        "/usr/share/cups/model/Brother/brother_dcp130c_printer_en.ppd"
        "/usr/share/cups/model/brother_dcp130c_printer_en.ppd"
    )
    
    # Also search dynamically
    log_debug "Searching for DCP-130C PPD files..."
    local found_ppd
    found_ppd=$(find /usr/share/cups/model/ /usr/share/ppd/ /opt/brother/ -iname '*dcp130c*.ppd' 2>/dev/null | head -n 1)
    if [[ -n "$found_ppd" ]]; then
        ppd_search_paths=("$found_ppd" "${ppd_search_paths[@]}")
    fi
    
    for path in "${ppd_search_paths[@]}"; do
        if [[ -f "$path" ]]; then
            ppd_file="$path"
            log_debug "PPD file found: $(ls -lh "$ppd_file")"
            break
        fi
    done
    
    # Check if we also have a PPD via lpinfo -m (CUPS driver list)
    if [[ -z "$ppd_file" ]]; then
        log_debug "No PPD file found on disk, checking CUPS driver list..."
        local cups_driver
        cups_driver=$(lpinfo -m 2>/dev/null | grep -i "dcp.*130c\|DCP-130C" | awk '{print $1}' | head -n 1)
        if [[ -n "$cups_driver" ]]; then
            log_info "Found CUPS driver: $cups_driver"
            log_info "Adding printer to CUPS using driver..."
            log_debug "lpadmin -p $PRINTER_NAME -v $PRINTER_URI -m $cups_driver -E -o printer-is-shared=false"
            sudo lpadmin -p "$PRINTER_NAME" \
                -v "$PRINTER_URI" \
                -m "$cups_driver" \
                -E \
                -o printer-is-shared=false
            
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
PPEOF
        log_debug "Generated basic PPD at $ppd_file"
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
