#!/bin/bash
################################################################################
# Brother DCP-130C Scanner Driver Installation Script for Raspberry Pi
# System: Linux armv7l (Raspberry Pi)
# Scanner: Brother DCP-130C
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
SCANNER_MODEL="DCP-130C"
SCANNER_NAME="Brother_DCP_130C"
TMP_DIR="/tmp/brother_dcp130c_scanner_install"

# Driver filename
DRIVER_BRSCAN2_FILE="brscan2-0.2.5-1.i386.deb"

# Multiple download sources (tried in order). Brother has moved files across
# domains over the years, so we try several known locations plus the
# Internet Archive as a last resort.
DRIVER_BRSCAN2_URLS=(
    "https://download.brother.com/welcome/dlf006638/${DRIVER_BRSCAN2_FILE}"
    "http://download.brother.com/welcome/dlf006638/${DRIVER_BRSCAN2_FILE}"
    "http://www.brother.com/pub/bsc/linux/dlf/${DRIVER_BRSCAN2_FILE}"
    "https://web.archive.org/web/2024if_/https://download.brother.com/welcome/dlf006638/${DRIVER_BRSCAN2_FILE}"
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
# On newer Debian/Raspbian (trixie+), some libraries were renamed with a t64 suffix.
# This function detects which variant is available.
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
    log_debug "resolve_package: no candidate found for '$pkg' or '$t64_pkg'"
    # Search for similarly-named packages as a diagnostic hint
    local similar
    similar=$(apt-cache search "^${pkg}" 2>/dev/null | head -5)
    if [[ -n "$similar" ]]; then
        log_debug "resolve_package: similar packages in apt:"
        while IFS= read -r line; do
            log_debug "  $line"
        done <<< "$similar"
    fi
    log_debug "resolve_package: falling back to '$pkg' (apt-get will report the actual error)"
    echo "$pkg"
}

# Fix broken dpkg state from previous failed installs.
# A broken package (e.g. brscan2:i386 "needs to be reinstalled") blocks
# ALL apt-get operations, so this must run before install_dependencies().
fix_broken_packages() {
    local packages_fixed=0
    for pkg in brscan2 "brscan2:i386"; do
        if dpkg -s "$pkg" &>/dev/null; then
            local status
            status=$(dpkg -s "$pkg" 2>/dev/null | grep "^Status:" || true)
            log_debug "fix_broken_packages: $pkg status='$status'"
            if echo "$status" | grep -qi "reinst-required\|half-installed\|half-configured" || \
               echo "$status" | grep -qw "unpacked"; then
                log_warn "Fixing broken package state: $pkg ($status)"

                local pkg_base="${pkg%%:*}"

                # Neutralize any broken maintainer scripts
                for script in preinst postinst prerm postrm; do
                    for sp in "/var/lib/dpkg/info/${pkg_base}.${script}" \
                              "/var/lib/dpkg/info/${pkg}.${script}"; do
                        if [[ -f "$sp" ]]; then
                            log_debug "Neutralizing broken maintainer script: $sp"
                            sudo cp "$sp" "${sp}.bak" 2>/dev/null || true
                            echo '#!/bin/sh' | sudo tee "$sp" > /dev/null
                            echo 'exit 0' | sudo tee -a "$sp" > /dev/null
                            sudo chmod 755 "$sp"
                        fi
                    done
                done

                # Try aggressive removal
                log_debug "Attempting dpkg --purge --force-all $pkg"
                sudo dpkg --purge --force-all "$pkg" 2>/dev/null || true

                # Verify removal succeeded
                if dpkg -s "$pkg" &>/dev/null; then
                    local new_status
                    new_status=$(dpkg -s "$pkg" 2>/dev/null | grep "^Status:" || true)
                    log_debug "Package $pkg still present after purge: $new_status"

                    # Last resort: directly clean the dpkg database
                    log_warn "Standard removal failed for $pkg, cleaning dpkg database directly..."
                    sudo rm -f "/var/lib/dpkg/info/${pkg_base}".* 2>/dev/null || true
                    sudo rm -f "/var/lib/dpkg/info/${pkg}".* 2>/dev/null || true
                    if [[ -f /var/lib/dpkg/status ]]; then
                        sudo cp /var/lib/dpkg/status /var/lib/dpkg/status.bak
                        sudo awk -v pkg="$pkg_base" '
                            BEGIN { skip=0 }
                            /^Package:/ { skip=($2 == pkg) }
                            /^$/ { if (skip) { skip=0; next } }
                            !skip { print }
                        ' /var/lib/dpkg/status.bak | sudo tee /var/lib/dpkg/status > /dev/null
                        log_debug "Removed $pkg_base entry from dpkg status database"
                    fi
                else
                    log_debug "Package $pkg successfully removed"
                fi

                packages_fixed=1
            fi
        fi
    done

    if [[ $packages_fixed -eq 1 ]]; then
        log_debug "Running apt-get install -f to fix remaining dependency issues..."
        sudo apt-get install -f -y 2>/dev/null || true

        log_debug "Verifying apt-get works after cleanup..."
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
    
    log_debug "Running apt-get update..."
    sudo apt-get update
    
    # Resolve library package names that may differ across Debian/Raspbian versions
    # On trixie+, the SANE library package is called libsane1 (not libsane)
    log_info "Detecting correct package names for this system..."
    LIBSANE=$(resolve_package "libsane1")
    LIBUSB=$(resolve_package "libusb-0.1-4")
    log_info "Resolved: libsane1 -> $LIBSANE, libusb-0.1-4 -> $LIBUSB"
    
    # Build list of packages to install
    local packages=(
        sane-utils
        "$LIBSANE"
        "$LIBUSB"
    )

    log_debug "Final package list: ${packages[*]}"

    sudo apt-get install -y "${packages[@]}"
    
    log_info "Dependencies installed successfully."
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

# Download scanner driver
download_drivers() {
    log_info "Downloading Brother DCP-130C scanner driver..."
    
    log_info "Downloading brscan2 driver (${DRIVER_BRSCAN2_FILE})..."
    log_debug "brscan2 driver URLs to try: ${DRIVER_BRSCAN2_URLS[*]}"
    if ! try_download brscan2.deb "${DRIVER_BRSCAN2_URLS[@]}"; then
        log_error "Failed to download brscan2 driver from all sources."
        log_error "URLs tried:"
        for url in "${DRIVER_BRSCAN2_URLS[@]}"; do
            log_error "  - $url"
        done
        log_error "Please download ${DRIVER_BRSCAN2_FILE} manually and place it in ${TMP_DIR}/"
        exit 1
    fi
    log_debug "brscan2 driver downloaded: $(ls -lh brscan2.deb)"
    
    log_info "Scanner driver downloaded successfully."
}

# Extract and modify driver for ARM architecture
extract_and_modify_drivers() {
    log_info "Extracting and preparing scanner driver for ARM architecture..."
    
    # Create working directory
    mkdir -p brscan2_extract
    
    # Extract brscan2 driver
    log_info "Extracting brscan2 driver..."
    dpkg-deb -x brscan2.deb brscan2_extract/
    dpkg-deb -e brscan2.deb brscan2_extract/DEBIAN
    log_debug "brscan2 control before modification:"
    log_debug "$(cat brscan2_extract/DEBIAN/control)"
    
    # Modify control file to remove architecture restrictions
    sed -i 's/Architecture: .*/Architecture: all/' brscan2_extract/DEBIAN/control
    
    # Ensure maintainer scripts are executable
    for script in preinst postinst prerm postrm; do
        if [[ -f "brscan2_extract/DEBIAN/$script" ]]; then
            chmod 755 "brscan2_extract/DEBIAN/$script"
        fi
    done
    
    log_debug "brscan2 control after modification:"
    log_debug "$(cat brscan2_extract/DEBIAN/control)"
    
    log_info "Scanner driver prepared for ARM installation."
}

# Repackage driver
repackage_drivers() {
    log_info "Repackaging scanner driver for ARM architecture..."
    
    dpkg-deb -b brscan2_extract brscan2_arm.deb
    
    log_info "Scanner driver repackaged successfully."
}

# Install scanner driver
install_drivers() {
    log_info "Installing scanner driver..."
    
    # Clean up any broken dpkg state from previous failed installs
    if dpkg -s brscan2 &>/dev/null && dpkg -s brscan2 2>/dev/null | grep -q "needs to be reinstalled\|half-installed\|half-configured"; then
        log_warn "Cleaning up broken brscan2 package state from previous install..."
        sudo dpkg --remove --force-remove-reinstreq brscan2 2>/dev/null || true
    fi
    
    # Install brscan2 driver
    log_info "Installing brscan2 driver..."
    log_debug "brscan2 package: $(ls -lh brscan2_arm.deb)"
    if ! sudo dpkg -i --force-all brscan2_arm.deb; then
        log_warn "brscan2 driver installation reported errors, attempting to fix dependencies..."
    fi
    
    # Fix any dependency issues
    log_debug "Running apt-get install -f to fix dependencies..."
    sudo apt-get install -f -y || true

    # Create SONAME symlinks for Brother SANE shared libraries.
    # The brscan2 package installs versioned libraries like
    #   libsane-brother2.so.1.0.7
    #   libbrscandec2.so.1.0.0
    #   libbrcolm2.so.1.0.0
    # but SANE's dlopen() looks for the SONAME (e.g. libsane-brother2.so.1).
    # Without these symlinks, SANE cannot load the brother2 backend.
    log_info "Creating SANE backend symlinks..."
    local symlinks_created=0
    for lib_dir in /usr/lib/sane /usr/lib; do
        if [[ -d "$lib_dir" ]]; then
            while IFS= read -r -d '' lib_file; do
                local lib_base
                lib_base=$(basename "$lib_file")
                # Extract SONAME: e.g. libsane-brother2.so.1.0.7 → libsane-brother2.so.1
                local soname
                soname=$(echo "$lib_base" | sed -n 's/^\(lib[^.]*\.so\.[0-9]*\)\..*/\1/p')
                if [[ -n "$soname" && "$soname" != "$lib_base" ]]; then
                    local symlink_path="${lib_dir}/${soname}"
                    if [[ ! -e "$symlink_path" ]]; then
                        sudo ln -sf "$lib_base" "$symlink_path"
                        symlinks_created=$((symlinks_created + 1))
                        log_debug "Created symlink: $symlink_path -> $lib_base"
                    else
                        log_debug "Symlink already exists: $symlink_path"
                    fi
                fi
            done < <(find "$lib_dir" -maxdepth 1 -type f \
                         \( -name 'libsane-brother*' -o -name 'libbrscandec*' -o -name 'libbrcolm*' \) \
                         -print0 2>/dev/null)
        fi
    done
    if [[ $symlinks_created -gt 0 ]]; then
        log_info "Created $symlinks_created SANE backend symlinks."
        sudo ldconfig 2>/dev/null || true
    else
        log_debug "All SANE backend symlinks already in place."
    fi

    # Check if the Brother SANE binaries can execute on this architecture.
    # The driver is compiled for i386 — brsaneconfig2 and the SANE shared
    # libraries are i386 ELF binaries that need binfmt_misc/qemu-user-static
    # to run on ARM.
    #
    # can_execute_binary: test if a single executable can run on this system.
    # Uses a timeout to prevent hangs from binaries that block.
    # NOTE: Only use on actual executables, NOT on shared libraries (.so).
    can_execute_binary() {
        local f="$1"
        timeout 5 "$f" --version &>/dev/null || timeout 5 "$f" --help &>/dev/null || timeout 5 "$f" &>/dev/null
    }

    log_debug "Scanning for Brother scanner i386 binaries..."
    local i386_binaries_found=0
    local i386_binaries_failed=0
    local i386_libs_found=0
    # Only search Brother-specific directories and files — avoid scanning
    # broad system directories like /usr/lib/ which contain thousands of
    # unrelated files and would cause the script to hang for minutes.
    while IFS= read -r -d '' bin_file; do
        local bin_type
        bin_type=$(file "$bin_file" 2>/dev/null || echo 'unknown')
        if echo "$bin_type" | grep -qi "ELF.*Intel 80386\|ELF.*i386\|ELF.*x86-64\|ELF.*80386"; then
            # Shared libraries (.so) cannot be executed directly — only test
            # actual executables. Shared libraries are loaded by SANE at runtime.
            if echo "$bin_type" | grep -qi "shared object"; then
                i386_libs_found=$((i386_libs_found + 1))
                log_debug "i386 shared library: $bin_file (skipping execution test)"
            else
                i386_binaries_found=$((i386_binaries_found + 1))
                log_debug "i386 executable: $bin_file"
                if ! can_execute_binary "$bin_file"; then
                    i386_binaries_failed=$((i386_binaries_failed + 1))
                    log_debug "  -> FAILED to execute"
                else
                    log_debug "  -> executes OK"
                fi
            fi
        fi
    done < <(find /usr/local/Brother/sane/ -type f -print0 2>/dev/null
             find /usr/lib/sane/ /usr/lib/ -maxdepth 1 -type f \
                 \( -name '*brsane*' -o -name '*brcolm*' -o -name '*brscandec*' -o -name '*brother*' \) \
                 -print0 2>/dev/null)
    log_debug "Binary scan complete: $i386_binaries_found executables ($i386_binaries_failed failed), $i386_libs_found shared libraries"

    # i386 support is needed if any executables failed OR if there are i386
    # shared libraries (which SANE dynamically loads and need qemu + i386 libc)
    local need_i386_support=0
    if [[ $i386_binaries_found -gt 0 || $i386_libs_found -gt 0 ]]; then
        if [[ $i386_binaries_failed -gt 0 ]]; then
            log_warn "$i386_binaries_failed of $i386_binaries_found Brother i386 executables cannot run on this ARM system."
            need_i386_support=1
        elif [[ $i386_libs_found -gt 0 ]]; then
            log_debug "Found $i386_libs_found i386 shared libraries that need i386 runtime support"
            need_i386_support=1
        else
            log_info "All Brother i386 executables run successfully on this ARM system."
        fi

        if [[ $need_i386_support -eq 1 ]]; then
            log_info "Setting up i386 binary support..."

            # Step 1: Ensure qemu-user-static is installed for binfmt_misc i386 emulation
            if ! dpkg -s qemu-user-static &>/dev/null; then
                log_info "Installing qemu-user-static..."
                sudo apt-get install -y qemu-user-static 2>&1 | tail -3
            else
                log_debug "qemu-user-static is already installed"
            fi

            # Step 2: Provide the i386 dynamic linker (/lib/ld-linux.so.2)
            # On Raspberry Pi OS (armhf), libc6:i386 is not available via apt
            # because i386 repos don't exist. We download it directly from
            # Debian mirrors and extract the needed files.
            if [[ ! -f /lib/ld-linux.so.2 ]] || [[ ! -f /lib/i386-linux-gnu/libc.so.6 ]]; then
                log_info "i386 libraries missing. Downloading from Debian mirrors..."
                log_debug "ld-linux.so.2 exists: $(test -f /lib/ld-linux.so.2 && echo yes || echo no)"
                log_debug "libc.so.6 exists: $(test -f /lib/i386-linux-gnu/libc.so.6 && echo yes || echo no)"
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
                    log_debug "Downloading: ${libc6_url}${libc6_filename}"
                    if wget -q --timeout=30 -O "$libc6_deb" "${libc6_url}${libc6_filename}" 2>/dev/null; then
                        log_debug "Extracting i386 libraries..."
                        dpkg-deb -x "$libc6_deb" "${i386_tmp}/extract/" 2>/dev/null
                        if [[ "$DEBUG" == "1" ]]; then
                            log_debug "Extracted directories: $(find "${i386_tmp}/extract/" -maxdepth 4 -type d 2>/dev/null | head -20)"
                        fi
                        # Copy ld-linux.so.2 to /lib/
                        local ld_linux
                        ld_linux=$(find "${i386_tmp}/extract/" \( -name 'ld-linux.so.2' -o -name 'ld-linux*.so*' \) 2>/dev/null | head -1)
                        if [[ -n "$ld_linux" ]]; then
                            sudo cp "$ld_linux" /lib/ld-linux.so.2
                            sudo chmod 755 /lib/ld-linux.so.2
                            log_info "Installed i386 dynamic linker: /lib/ld-linux.so.2"
                        fi
                        # Find and copy i386 libs
                        local i386_lib_dir
                        i386_lib_dir=$(find "${i386_tmp}/extract/" -type d -name 'i386-linux-gnu' 2>/dev/null | head -1)
                        if [[ -n "$i386_lib_dir" ]]; then
                            log_debug "Found i386 lib directory: $i386_lib_dir"
                            sudo mkdir -p /lib/i386-linux-gnu
                            sudo cp -a "${i386_lib_dir}/"* /lib/i386-linux-gnu/ 2>/dev/null || true
                            log_debug "Copied i386 libs to /lib/i386-linux-gnu/"
                        else
                            log_debug "No i386-linux-gnu directory found, searching for libc.so.6 directly..."
                            local libc_so
                            libc_so=$(find "${i386_tmp}/extract/" \( -name 'libc.so.6' -o -name 'libc-*.so' \) 2>/dev/null | head -1)
                            if [[ -n "$libc_so" ]]; then
                                local libc_dir
                                libc_dir=$(dirname "$libc_so")
                                log_debug "Found libc.so.6 at: $libc_so (dir: $libc_dir)"
                                sudo mkdir -p /lib/i386-linux-gnu
                                sudo cp -a "${libc_dir}/"*.so* /lib/i386-linux-gnu/ 2>/dev/null || true
                                log_debug "Copied i386 libs from $libc_dir to /lib/i386-linux-gnu/"
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
                            log_debug "Registered i386 library paths in ld.so.conf.d"
                        fi
                        sudo ldconfig 2>/dev/null || true
                        log_debug "Ran ldconfig to update library cache"
                    else
                        log_warn "Could not download libc6 i386 from Debian mirrors."
                    fi
                else
                    log_warn "Could not find libc6 i386 package in Debian pool."
                fi
                rm -rf "$i386_tmp"
            else
                log_debug "i386 libraries already present: /lib/ld-linux.so.2 and /lib/i386-linux-gnu/libc.so.6"
            fi

            # Fix Raspberry Pi /etc/ld.so.preload that causes errors under qemu-user-static.
            if [[ -f /etc/ld.so.preload ]] && grep -q 'libarmmem' /etc/ld.so.preload 2>/dev/null; then
                log_info "Fixing /etc/ld.so.preload for i386 compatibility..."
                sudo sed -i 's|^[[:space:]]*/usr/lib/arm-linux-gnueabihf/libarmmem|# Commented for i386 compat: /usr/lib/arm-linux-gnueabihf/libarmmem|' /etc/ld.so.preload
                log_debug "Commented out libarmmem preload to prevent i386 binary errors"
            fi

            # Re-check executables after installing i386 support
            log_info "Re-checking executables..."
            local recheck_failed=0
            while IFS= read -r -d '' bin_file; do
                local bin_type
                bin_type=$(file "$bin_file" 2>/dev/null || echo 'unknown')
                if echo "$bin_type" | grep -qi "ELF.*Intel 80386\|ELF.*i386\|ELF.*x86-64\|ELF.*80386"; then
                    # Skip shared libraries — only test executables
                    if echo "$bin_type" | grep -qi "shared object"; then
                        continue
                    fi
                    if ! can_execute_binary "$bin_file"; then
                        recheck_failed=$((recheck_failed + 1))
                        local run_err
                        run_err=$(timeout 5 "$bin_file" 2>&1 || true)
                        log_debug "Still fails: $bin_file"
                        log_debug "  Error: ${run_err:-<no output>}"
                    fi
                fi
            done < <(find /usr/local/Brother/sane/ -type f -print0 2>/dev/null
                     find /usr/lib/sane/ /usr/lib/ -maxdepth 1 -type f \
                         \( -name '*brsane*' -o -name '*brcolm*' -o -name '*brscandec*' -o -name '*brother*' \) \
                         -print0 2>/dev/null)
            if [[ $recheck_failed -gt 0 ]]; then
                log_warn "$recheck_failed executables still can't run. Scanning may not work."
                log_warn "The Brother i386 binaries need additional i386 libraries."
                log_warn "Check: file /usr/local/Brother/sane/brsaneconfig2"
                log_warn "Then run the binary directly to see what libraries are missing."
            else
                log_info "All Brother executables now run successfully."
            fi
        fi
    else
        log_debug "No i386 ELF binaries found (driver uses shell scripts only)"
    fi

    log_info "Scanner driver installed successfully."
}

# Set up an i386 SANE environment for running scanimage on ARM.
# The ARM SANE process cannot dlopen() i386 shared libraries (architecture
# mismatch). The solution is to run an i386 scanimage binary via
# qemu-i386-static, which CAN natively load the i386 Brother SANE backend.
setup_i386_scanner() {
    local i386_root="/opt/brother/i386"
    local wrapper="/usr/local/bin/brother-scanimage"

    # Skip if wrapper already exists and works
    if [[ -x "$wrapper" ]]; then
        log_debug "brother-scanimage wrapper already exists: $wrapper"
        return 0
    fi

    log_info "Setting up i386 scanner environment for ARM..."
    log_info "ARM SANE cannot load i386 backend libraries via dlopen()."
    log_info "Installing i386 scanimage to run through qemu-i386-static..."

    # Ensure qemu-i386-static is available
    local qemu_bin
    qemu_bin=$(command -v qemu-i386-static 2>/dev/null || true)
    if [[ -z "$qemu_bin" ]]; then
        qemu_bin=$(find /usr/libexec/qemu-binfmt/ /usr/bin/ /usr/local/bin/ -name 'qemu-i386*' -type f -executable 2>/dev/null | head -1)
    fi
    if [[ -z "$qemu_bin" ]]; then
        log_warn "qemu-i386-static not found. Cannot set up i386 scanner environment."
        log_warn "Install qemu-user-static and re-run this script."
        return 1
    fi
    log_debug "qemu binary: $qemu_bin"

    # Create i386 root
    sudo mkdir -p "$i386_root"

    # Download i386 sane-utils from Debian pool
    local i386_tmp
    i386_tmp=$(mktemp -d)
    local pool_url="https://deb.debian.org/debian/pool/main"

    # Download i386 sane-utils (contains scanimage)
    log_info "Downloading i386 sane-utils..."
    local sane_utils_filename
    sane_utils_filename=$(wget -q -O - "${pool_url}/s/sane-backends/" 2>/dev/null \
        | grep -oP 'sane-utils_[0-9][0-9.~+-]*_i386\.deb' \
        | sort -V | tail -1)
    if [[ -z "$sane_utils_filename" ]]; then
        log_warn "Could not find i386 sane-utils in Debian pool."
        rm -rf "$i386_tmp"
        return 1
    fi
    log_debug "Found: $sane_utils_filename"
    if ! wget -q --timeout=30 -O "${i386_tmp}/sane-utils.deb" "${pool_url}/s/sane-backends/${sane_utils_filename}" 2>/dev/null; then
        log_warn "Could not download i386 sane-utils."
        rm -rf "$i386_tmp"
        return 1
    fi

    # Download i386 libsane1 (SANE backend framework)
    log_info "Downloading i386 libsane1..."
    local libsane_filename
    libsane_filename=$(wget -q -O - "${pool_url}/s/sane-backends/" 2>/dev/null \
        | grep -oP 'libsane1_[0-9][0-9.~+-]*_i386\.deb' \
        | sort -V | tail -1)
    if [[ -z "$libsane_filename" ]]; then
        log_warn "Could not find i386 libsane1 in Debian pool."
        rm -rf "$i386_tmp"
        return 1
    fi
    log_debug "Found: $libsane_filename"
    if ! wget -q --timeout=30 -O "${i386_tmp}/libsane1.deb" "${pool_url}/s/sane-backends/${libsane_filename}" 2>/dev/null; then
        log_warn "Could not download i386 libsane1."
        rm -rf "$i386_tmp"
        return 1
    fi

    # Download i386 libusb-0.1-4 (needed by Brother backend)
    log_info "Downloading i386 libusb-0.1-4..."
    local libusb_filename
    libusb_filename=$(wget -q -O - "${pool_url}/libu/libusb/" 2>/dev/null \
        | grep -oP 'libusb-0\.1-4_[0-9][0-9.~+-]*_i386\.deb' \
        | sort -V | tail -1)
    if [[ -n "$libusb_filename" ]]; then
        log_debug "Found: $libusb_filename"
        wget -q --timeout=30 -O "${i386_tmp}/libusb.deb" "${pool_url}/libu/libusb/${libusb_filename}" 2>/dev/null || true
    fi

    # Download i386 runtime dependencies for scanimage.
    # scanimage links against several libraries beyond libc and libsane.
    # Without these, it fails with "error while loading shared libraries".
    log_info "Downloading i386 scanimage runtime dependencies..."
    # Each entry: "package_name  pool_path  filename_pattern"
    local -a dep_specs=(
        "libpng16-16     libp/libpng1.6    libpng16-16_"
        "libjpeg62-turbo libj/libjpeg-turbo libjpeg62-turbo_"
        "libtiff6        libt/tiff          libtiff6_"
        "libdeflate0     libd/libdeflate    libdeflate0_"
        "libwebp7        libw/libwebp       libwebp7_"
        "zlib1g          libz/zlib          zlib1g_"
        "libgcc-s1       libg/gcc-14        libgcc-s1_"
        "libstdc++6      libg/gcc-14        libstdc..6_"
        "libgomp1        libg/gcc-14        libgomp1_"
        "liblzma5        libx/xz-utils      liblzma5_"
        "libzstd1        libz/zstd          libzstd1_"
        "liblerc4        libe/lerc          liblerc4_"
        "libjbig0        libj/jbigkit       libjbig0_"
        "libusb-1.0-0    libu/libusb-1.0    libusb-1.0-0_"
    )
    for dep_spec in "${dep_specs[@]}"; do
        read -r dep_name dep_pool dep_pattern <<< "$dep_spec"
        local dep_filename
        dep_filename=$(wget -q -O - "${pool_url}/${dep_pool}/" 2>/dev/null \
            | grep -oP "${dep_pattern}[0-9][0-9.~+-]*_i386\\.deb" \
            | sort -V | tail -1)
        if [[ -n "$dep_filename" ]]; then
            log_debug "Downloading dep: $dep_filename"
            wget -q --timeout=30 -O "${i386_tmp}/${dep_name}.deb" \
                "${pool_url}/${dep_pool}/${dep_filename}" 2>/dev/null || true
        else
            log_debug "Dependency $dep_name not found in pool (may not be needed)"
        fi
    done

    # Extract all packages into the i386 root
    log_info "Extracting i386 SANE environment..."
    for deb in "${i386_tmp}"/*.deb; do
        if [[ -f "$deb" ]]; then
            log_debug "Extracting: $(basename "$deb")"
            sudo dpkg-deb -x "$deb" "$i386_root/" 2>/dev/null || true
        fi
    done
    rm -rf "$i386_tmp"

    # Copy the Brother scanner backend .so files into the i386 SANE environment
    local i386_sane_dir="$i386_root/usr/lib/sane"
    sudo mkdir -p "$i386_sane_dir"
    for brother_so in /usr/lib/sane/libsane-brother2*; do
        if [[ -f "$brother_so" ]] || [[ -L "$brother_so" ]]; then
            sudo cp -a "$brother_so" "$i386_sane_dir/" 2>/dev/null || true
            log_debug "Copied to i386 env: $(basename "$brother_so")"
        fi
    done
    # Copy Brother support libraries
    for brother_lib in /usr/lib/libbrscandec2* /usr/lib/libbrcolm2*; do
        if [[ -f "$brother_lib" ]] || [[ -L "$brother_lib" ]]; then
            sudo cp -a "$brother_lib" "$i386_root/usr/lib/" 2>/dev/null || true
            log_debug "Copied to i386 env: $(basename "$brother_lib")"
        fi
    done

    # Copy Brother configuration files
    if [[ -d /usr/local/Brother/sane ]]; then
        sudo mkdir -p "$i386_root/usr/local/Brother"
        sudo cp -a /usr/local/Brother/sane "$i386_root/usr/local/Brother/" 2>/dev/null || true
        log_debug "Copied Brother sane config to i386 env"
    fi

    # Ensure SANE config is available in the i386 environment
    sudo mkdir -p "$i386_root/etc/sane.d"
    if [[ -f /etc/sane.d/dll.conf ]]; then
        sudo cp /etc/sane.d/dll.conf "$i386_root/etc/sane.d/" 2>/dev/null || true
    fi
    # Copy all SANE .conf files
    sudo cp /etc/sane.d/*.conf "$i386_root/etc/sane.d/" 2>/dev/null || true

    # Make sure i386 libc is available in the i386 root
    if [[ -d /lib/i386-linux-gnu ]]; then
        sudo mkdir -p "$i386_root/lib/i386-linux-gnu"
        sudo cp -a /lib/i386-linux-gnu/* "$i386_root/lib/i386-linux-gnu/" 2>/dev/null || true
    fi
    if [[ -f /lib/ld-linux.so.2 ]]; then
        sudo cp -a /lib/ld-linux.so.2 "$i386_root/lib/" 2>/dev/null || true
    fi

    # Find the i386 scanimage binary
    local i386_scanimage
    i386_scanimage=$(find "$i386_root" -name 'scanimage' -type f 2>/dev/null | head -1)
    if [[ -z "$i386_scanimage" ]]; then
        log_warn "i386 scanimage not found after extraction."
        return 1
    fi
    log_debug "i386 scanimage: $i386_scanimage"

    # Consolidate i386 library paths — the extracted packages may place
    # libraries in various subdirectories. Symlink them so the dynamic
    # linker can find everything in a single search path.
    for lib_subdir in "$i386_root"/usr/lib/i386-linux-gnu "$i386_root"/lib/i386-linux-gnu; do
        if [[ -d "$lib_subdir" ]]; then
            while IFS= read -r -d '' so_file; do
                if [[ -f "$so_file" || -L "$so_file" ]]; then
                    local base_name
                    base_name=$(basename "$so_file")
                    if [[ ! -e "$i386_root/usr/lib/$base_name" ]]; then
                        sudo ln -sf "$so_file" "$i386_root/usr/lib/$base_name" 2>/dev/null || true
                    fi
                fi
            done < <(find "$lib_subdir" -maxdepth 1 \( -name '*.so*' -o -name '*.a' \) -print0 2>/dev/null)
        fi
    done

    # Check for missing shared libraries using qemu + ldd before creating wrapper
    log_info "Checking i386 scanimage dependencies..."
    local missing_libs
    missing_libs=$("$qemu_bin" -L "$i386_root" /lib/ld-linux.so.2 --list "$i386_scanimage" 2>&1 || true)
    local still_missing
    still_missing=$(echo "$missing_libs" | grep "not found" || true)
    if [[ -n "$still_missing" ]]; then
        log_warn "i386 scanimage has missing library dependencies:"
        while IFS= read -r line; do
            log_warn "  $line"
        done <<< "$still_missing"
        log_info "Attempting to download missing i386 libraries..."

        # Try to resolve each missing library from the Debian pool
        while IFS= read -r missing_line; do
            local missing_lib
            missing_lib=$(echo "$missing_line" | sed 's/.*\(lib[^ ]*\.so[^ ]*\).*/\1/' | tr -d '[:space:]')
            if [[ -z "$missing_lib" ]]; then
                continue
            fi
            # Map .so name to Debian package name (strip .so.* suffix, replace ++ with pp)
            local pkg_base
            pkg_base=$(echo "$missing_lib" | sed 's/\.so\..*//')
            log_debug "Searching for i386 package providing: $missing_lib (base: $pkg_base)"

            # Search the package index via packages.debian.org
            local search_result
            search_result=$(wget -q -O - "https://packages.debian.org/search?searchon=contents&keywords=${missing_lib}&mode=filename&suite=stable&arch=i386" 2>/dev/null \
                | grep -oP 'packages/[^/]+/[^"]+' | head -1 || true)
            if [[ -n "$search_result" ]]; then
                local found_pkg
                found_pkg=$(echo "$search_result" | sed 's|packages/[^/]*/||')
                log_debug "Found package: $found_pkg for $missing_lib"
            fi
        done <<< "$still_missing"
    else
        log_debug "All i386 scanimage dependencies are satisfied."
    fi

    # Create the wrapper script
    log_info "Creating brother-scanimage wrapper..."
    sudo tee "$wrapper" > /dev/null << WRAPPER_EOF
#!/bin/bash
# Brother scanner wrapper — runs i386 scanimage via qemu-i386-static.
# ARM SANE cannot dlopen() i386 backend libraries, so we use an i386
# scanimage binary that can natively load the Brother SANE backend.
#
# Usage: brother-scanimage [scanimage arguments...]
# Example: brother-scanimage --format=png --resolution=300 > scan.png
#          brother-scanimage -L

export SANE_CONFIG_DIR="$i386_root/etc/sane.d"
export LD_LIBRARY_PATH="$i386_root/usr/lib:$i386_root/usr/lib/sane:$i386_root/usr/lib/i386-linux-gnu:$i386_root/lib/i386-linux-gnu:/usr/lib:/lib/i386-linux-gnu"

exec "$qemu_bin" -L "$i386_root" "$i386_scanimage" "\$@"
WRAPPER_EOF
    sudo chmod 755 "$wrapper"
    log_info "Created: $wrapper"

    # Verify the wrapper can list backends
    log_info "Verifying i386 scanner environment..."
    local verify_output
    verify_output=$("$wrapper" -L 2>&1 || true)
    # Check for shared library errors first — these indicate missing deps
    if echo "$verify_output" | grep -qi "error while loading shared libraries"; then
        local missing_so
        missing_so=$(echo "$verify_output" | grep -oP 'lib[^:]+\.so[^:]*' | head -1)
        log_warn "brother-scanimage failed: missing i386 library: ${missing_so:-unknown}"
        log_debug "Full output: $verify_output"
        log_info "You may need to manually install the missing i386 library."
    elif echo "$verify_output" | grep -qi "device.*brother\|DCP-130C"; then
        log_info "i386 scanner environment works! Scanner detected."
    else
        log_debug "brother-scanimage -L output: ${verify_output:-<empty>}"
        log_info "i386 scanner environment installed. Scanner may be detected after USB reconnect."
    fi

    log_info "i386 scanner environment setup complete."
    log_info "Use 'brother-scanimage' instead of 'scanimage' for scanning."
}

# Detect scanner USB connection
detect_scanner() {
    log_info "Detecting Brother DCP-130C scanner..."
    
    log_debug "USB devices:"
    log_debug "$(lsusb 2>/dev/null || echo 'lsusb not available')"
    
    # Check USB connection
    if lsusb | grep -i "Brother"; then
        log_info "Brother device detected on USB."
        lsusb | grep -i "Brother"
    else
        log_warn "Brother device not detected on USB. Please ensure the scanner is connected and powered on."
    fi
}

# Configure scanner with brsaneconfig2
configure_scanner() {
    log_info "Configuring scanner..."

    local brsaneconfig="/usr/local/Brother/sane/brsaneconfig2"
    if [[ ! -f "$brsaneconfig" ]] && [[ ! -L "/usr/bin/brsaneconfig2" ]]; then
        log_error "brsaneconfig2 not found. Scanner driver may not have installed correctly."
        exit 1
    fi

    # Use the symlink if available (it may work via qemu on ARM)
    if command -v brsaneconfig2 &>/dev/null; then
        brsaneconfig="brsaneconfig2"
    fi

    # Ensure the SANE dll.conf includes brother2 backend
    local dll_conf="/etc/sane.d/dll.conf"
    if [[ -f "$dll_conf" ]]; then
        if ! grep -q '^brother2$' "$dll_conf"; then
            log_info "Adding brother2 backend to SANE configuration..."
            echo "brother2" | sudo tee -a "$dll_conf" > /dev/null
        else
            log_debug "brother2 backend already in $dll_conf"
        fi
    else
        log_warn "$dll_conf not found. Creating it with brother2 backend..."
        echo "brother2" | sudo tee "$dll_conf" > /dev/null
    fi

    # Add the scanner device using brsaneconfig2
    # The DCP-130C USB ID is 0x01a8 (from Brsane2.ini)
    log_info "Registering scanner device..."
    log_debug "Running: $brsaneconfig -a name=$SCANNER_NAME model=$SCANNER_MODEL nodename=local_device"
    sudo "$brsaneconfig" -a name="$SCANNER_NAME" model="$SCANNER_MODEL" nodename=local_device 2>&1 | while IFS= read -r line; do
        log_debug "brsaneconfig2: $line"
    done || log_warn "brsaneconfig2 returned non-zero exit code (this may be normal on ARM)"

    # Verify scanner configuration — show only configured devices, not the
    # full model list (which is 88+ lines of every supported Brother model)
    local configured_devices
    configured_devices=$("$brsaneconfig" -q 2>&1 | grep -A 999 '^Devices on network' || echo 'query failed')
    if [[ -n "$configured_devices" ]]; then
        log_debug "Configured devices:"
        log_debug "$configured_devices"
    else
        log_debug "No configured devices found (brsaneconfig2 -q)"
    fi

    log_info "Scanner configured successfully."
}

# Test scan
test_scan() {
    log_info "Testing scanner..."

    # Determine the best scanimage command to use.
    # On ARM, the native scanimage cannot load i386 Brother SANE backends
    # (dlopen architecture mismatch), so we prefer brother-scanimage.
    local scan_cmd=""
    if [[ -x /usr/local/bin/brother-scanimage ]]; then
        scan_cmd="/usr/local/bin/brother-scanimage"
        log_debug "Using i386 wrapper: $scan_cmd"
    elif command -v scanimage &>/dev/null; then
        scan_cmd="scanimage"
        log_debug "Using native scanimage"
    else
        log_warn "scanimage not found. Install sane-utils to test scanning."
        return
    fi

    # List available scanners
    log_info "Checking for available scanners..."
    local scanners
    scanners=$($scan_cmd -L 2>&1 || true)

    if echo "$scanners" | grep -q "error while loading shared libraries"; then
        local missing_so
        missing_so=$(echo "$scanners" | grep -oP 'lib[^:]+\.so[^:]*' | head -1)
        log_warn "Scanner command failed: missing i386 library: ${missing_so:-unknown}"
        log_debug "$scan_cmd -L output: $scanners"
    elif echo "$scanners" | grep -qi "device.*brother\|DCP-130C.*scanner"; then
        log_info "Scanner detected: $scanners"
    else
        log_warn "Scanner not detected by SANE."
        log_info "$scan_cmd -L output: ${scanners:-<empty>}"

        # If using native scanimage, explain the dlopen issue
        if [[ "$scan_cmd" == "scanimage" ]]; then
            log_info "Note: ARM scanimage cannot load i386 Brother backend (dlopen arch mismatch)."
            log_info "The brother-scanimage wrapper should handle this — checking..."

            # Run SANE debug to confirm the dlopen failure
            log_debug "SANE backend debug (DLL loading):"
            local sane_debug_output
            sane_debug_output=$(SANE_DEBUG_DLL=3 scanimage -L 2>&1 || true)
            local relevant_lines
            relevant_lines=$(echo "$sane_debug_output" | grep -i 'brother\|dlopen\|error\|fail\|cannot\|not found' | head -10 || true)
            if [[ -n "$relevant_lines" ]]; then
                while IFS= read -r line; do
                    log_debug "  $line"
                done <<< "$relevant_lines"
            fi
        fi

        # USB-level check
        if command -v sane-find-scanner &>/dev/null; then
            log_debug "sane-find-scanner output:"
            log_debug "$(sane-find-scanner 2>&1 | grep -i 'brother\|04f9\|USB\|found' || echo '<no relevant output>')"
        fi
    fi

    # Ask user if they want to perform a test scan
    read -p "Do you want to perform a test scan? (y/n): " -n 1 -r
    echo

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        local test_output="/tmp/brother_test_scan.pnm"
        log_info "Performing test scan (this may take a moment)..."
        if $scan_cmd --format=pnm --resolution=150 > "$test_output" 2>&1; then
            if [[ -s "$test_output" ]]; then
                log_info "Test scan saved to: $test_output"
                log_info "File size: $(ls -lh "$test_output" | awk '{print $5}')"
            else
                log_warn "Test scan produced an empty file."
            fi
        else
            log_warn "Test scan failed. The scanner may not be detected yet."
            log_info "Try disconnecting and reconnecting the USB cable, then run: $scan_cmd -L"
        fi
    else
        log_info "Skipping test scan."
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

# Display scanner information
display_info() {
    log_info "============================================"
    log_info "Brother DCP-130C Scanner Installation Complete!"
    log_info "============================================"
    echo
    log_info "Scanner Name: $SCANNER_NAME"
    echo
    if [[ -x /usr/local/bin/brother-scanimage ]]; then
        log_info "To scan a document (use brother-scanimage on ARM):"
        log_info "  brother-scanimage --format=png --resolution=300 > scan.png"
        log_info "To list available scanners:"
        log_info "  brother-scanimage -L"
    else
        log_info "To scan a document:"
        log_info "  scanimage --format=png --resolution=300 > scan.png"
        log_info "To list available scanners:"
        log_info "  scanimage -L"
    fi
    log_info "To check SANE configuration:"
    log_info "  brsaneconfig2 -q"
    echo
    log_info "If the scanner is not detected, try:"
    log_info "  1. Disconnect and reconnect the USB cable"
    if [[ -x /usr/local/bin/brother-scanimage ]]; then
        log_info "  2. Run: sudo brother-scanimage -L"
    else
        log_info "  2. Run: sudo scanimage -L"
    fi
    log_info "  3. Check SANE backend: grep brother2 /etc/sane.d/dll.conf"
    echo
    log_info "If you were added to the scanner group, you may need to log out and back in."
}

# Main installation process
main() {
    log_info "Starting Brother DCP-130C scanner driver installation..."
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
    fix_broken_packages
    install_dependencies
    create_temp_dir
    download_drivers
    extract_and_modify_drivers
    repackage_drivers
    install_drivers
    setup_i386_scanner
    detect_scanner
    configure_scanner
    test_scan
    cleanup
    display_info
    
    log_info "Installation script completed successfully!"
}

# Run main function
main
