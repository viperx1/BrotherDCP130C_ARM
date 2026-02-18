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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCANNER_MODEL="DCP-130C"
SCANNER_NAME="Brother_DCP_130C"
TMP_DIR="/tmp/brother_dcp130c_scanner_install"

# Driver filename
DRIVER_BRSCAN2_FILE="brscan2-0.2.5-1.i386.deb"

# Source code for native ARM compilation
DRIVER_BRSCAN2_SRC_FILE="brscan2-src-0.2.5-1.tar.gz"
DRIVER_BRSCAN2_SRC_URLS=(
    "https://download.brother.com/welcome/dlf006820/${DRIVER_BRSCAN2_SRC_FILE}"
    "http://download.brother.com/welcome/dlf006820/${DRIVER_BRSCAN2_SRC_FILE}"
    "https://web.archive.org/web/2024if_/https://download.brother.com/welcome/dlf006820/${DRIVER_BRSCAN2_SRC_FILE}"
)

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
        gcc
        libsane-dev
        libusb-dev
        libncurses-dev
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

# Install scanner driver config and set up brsaneconfig2
install_drivers() {
    log_info "Installing scanner driver config files..."

    # Extract only config files and brsaneconfig2 from the deb.
    # We compile the SANE backend natively for ARM, so the i386 .so
    # files from the deb are not needed.
    local extract_dir="$TMP_DIR/brscan2_files"
    mkdir -p "$extract_dir"
    dpkg-deb -x brscan2.deb "$extract_dir"

    # Install config files and brsaneconfig2
    if [[ -d "$extract_dir/usr/local/Brother/sane" ]]; then
        sudo mkdir -p /usr/local/Brother/sane
        # Copy config files, calibration data, model info, brsaneconfig2
        sudo cp -a "$extract_dir/usr/local/Brother/sane/"* /usr/local/Brother/sane/
        log_info "Installed Brother scanner config files to /usr/local/Brother/sane/"
        log_debug "Contents: $(ls /usr/local/Brother/sane/ 2>/dev/null)"
    else
        log_error "Brother config files not found in deb package"
        return 1
    fi

    # Create brsaneconfig2 symlink in PATH
    if [[ -x /usr/local/Brother/sane/brsaneconfig2 ]]; then
        sudo ln -sf /usr/local/Brother/sane/brsaneconfig2 /usr/bin/brsaneconfig2
        log_debug "Created symlink: /usr/bin/brsaneconfig2"
    fi

    # Set up i386 support for brsaneconfig2 (the only i386 binary we need)
    if file -b /usr/local/Brother/sane/brsaneconfig2 2>/dev/null | grep -qi "Intel 80386\|i386"; then
        log_info "Setting up i386 support for brsaneconfig2..."

        if ! dpkg -s qemu-user-static &>/dev/null; then
            log_info "Installing qemu-user-static..."
            sudo apt-get install -y qemu-user-static 2>&1 | tail -3
        fi

        # Provide i386 dynamic linker if missing
        if [[ ! -f /lib/ld-linux.so.2 ]] || [[ ! -f /lib/i386-linux-gnu/libc.so.6 ]]; then
            log_info "Downloading i386 libc for brsaneconfig2..."
            local i386_tmp
            i386_tmp=$(mktemp -d)
            local libc6_url="https://deb.debian.org/debian/pool/main/g/glibc/"
            local libc6_filename
            libc6_filename=$(wget -q -O - "$libc6_url" 2>/dev/null \
                | grep -oP 'libc6_[0-9][0-9.~+-]*_i386\.deb' \
                | sort -V | tail -1)

            if [[ -n "$libc6_filename" ]]; then
                if wget -q --timeout=30 -O "$i386_tmp/libc6.deb" "${libc6_url}${libc6_filename}" 2>/dev/null; then
                    dpkg-deb -x "$i386_tmp/libc6.deb" "$i386_tmp/extract/" 2>/dev/null
                    local ld_linux
                    ld_linux=$(find "$i386_tmp/extract/" \( -name 'ld-linux.so.2' -o -name 'ld-linux*.so*' \) 2>/dev/null | head -1)
                    [[ -n "$ld_linux" ]] && sudo cp "$ld_linux" /lib/ld-linux.so.2 && sudo chmod 755 /lib/ld-linux.so.2
                    local i386_lib_dir
                    i386_lib_dir=$(find "$i386_tmp/extract/" -type d -name 'i386-linux-gnu' 2>/dev/null | head -1)
                    if [[ -n "$i386_lib_dir" ]]; then
                        sudo mkdir -p /lib/i386-linux-gnu
                        sudo cp -a "${i386_lib_dir}/"* /lib/i386-linux-gnu/ 2>/dev/null || true
                    fi
                    if ! grep -qsF 'i386-linux-gnu' /etc/ld.so.conf.d/i386-linux-gnu.conf 2>/dev/null; then
                        printf "/lib/i386-linux-gnu\n/usr/lib/i386-linux-gnu\n" | sudo tee /etc/ld.so.conf.d/i386-linux-gnu.conf > /dev/null
                    fi
                    sudo ldconfig 2>/dev/null || true
                    log_info "Installed i386 libraries for brsaneconfig2."
                fi
            fi
            rm -rf "$i386_tmp"
        fi

        # Fix Raspberry Pi /etc/ld.so.preload for i386 compatibility
        if [[ -f /etc/ld.so.preload ]] && grep -q 'libarmmem' /etc/ld.so.preload 2>/dev/null; then
            sudo sed -i 's|^[[:space:]]*/usr/lib/arm-linux-gnueabihf/libarmmem|# Commented for i386 compat: /usr/lib/arm-linux-gnueabihf/libarmmem|' /etc/ld.so.preload
            log_debug "Commented out libarmmem preload for i386 compatibility"
        fi

        # Verify brsaneconfig2 can execute
        if timeout 5 /usr/local/Brother/sane/brsaneconfig2 -q &>/dev/null; then
            log_info "brsaneconfig2 executes successfully."
        else
            log_warn "brsaneconfig2 cannot execute. Scanner configuration may fail."
        fi
    fi

    log_info "Scanner driver config installed successfully."
}

# Check library dependencies with ldd, logging any missing libraries.
# Usage: check_lib_deps lib1 lib2 ...
# Returns 0 if all deps OK, 1 if any missing.
check_lib_deps() {
    if ! command -v ldd &>/dev/null; then
        return 0
    fi
    local has_errors=0
    for lib in "$@"; do
        if [[ ! -f "$lib" ]]; then
            log_warn "  $lib NOT found"
            has_errors=1
            continue
        fi
        local ldd_out
        ldd_out=$(ldd "$lib" 2>&1 || true)
        local missing
        missing=$(echo "$ldd_out" | grep "not found" || true)
        if [[ -n "$missing" ]]; then
            log_warn "  $(basename "$lib"): MISSING deps: $missing"
            has_errors=1
        else
            log_debug "  $(basename "$lib"): all dependencies OK"
        fi
    done
    return "$has_errors"
}

# Compile the Brother SANE backend natively for ARM from source.
# This produces a native ARM libsane-brother2.so that can use the real
# USB stack directly.
compile_arm_backend() {
    local src_dir="$TMP_DIR/brscan2-src"
    local build_dir="$TMP_DIR/arm_build"

    # Always recompile to pick up stub fixes (compilation is fast)
    log_debug "Will compile/recompile native ARM SANE backend"

    # Check for compiler
    if ! command -v gcc &>/dev/null; then
        log_warn "gcc not found — cannot compile native ARM backend"
        return 1
    fi

    log_info "Compiling native ARM SANE backend from source..."

    # Download source
    log_info "Downloading brscan2 source code..."
    mkdir -p "$src_dir" "$build_dir"

    local src_tarball="$TMP_DIR/$DRIVER_BRSCAN2_SRC_FILE"
    if [[ ! -f "$src_tarball" ]]; then
        if ! try_download "$src_tarball" "${DRIVER_BRSCAN2_SRC_URLS[@]}"; then
            log_warn "Failed to download brscan2 source code"
            return 1
        fi
    fi

    # Extract source
    tar xzf "$src_tarball" -C "$src_dir" --strip-components=1 || {
        log_warn "Failed to extract brscan2 source"
        return 1
    }

    local brscan_src="$src_dir/brscan"
    if [[ ! -d "$brscan_src/backend_src" ]]; then
        log_warn "brscan2 source structure not as expected"
        return 1
    fi
    log_debug "Source extracted to: $brscan_src"

    # Strip dead BRSANESUFFIX==1 code paths from brother_scanner.c.
    # The source has #if BRSANESUFFIX==2 / #elif BRSANESUFFIX==1 blocks
    # with duplicate functions (PageScan, ProcessMain, etc). We compile
    # with -DBRSANESUFFIX=2 so the ==1 code never compiles, but removing
    # it eliminates confusion and ensures only one code path exists.
    local scanner_c="$brscan_src/backend_src/brother_scanner.c"
    if [[ -f "$scanner_c" ]]; then
        # Use the C preprocessor to resolve the #if/#elif blocks
        # This strips the BRSANESUFFIX==1 sections completely
        local line_count_before
        line_count_before=$(wc -l < "$scanner_c")
        awk '
        /^#elif.*BRSANESUFFIX == 1/ { skip=1; next }
        /^#else.*BRSANESUFFIX/      { skip=1; next }
        /^#endif.*BRSANESUFFIX/     { skip=0; next }
        /^#if.*BRSANESUFFIX == 2/   { next }
        !skip { print }
        ' "$scanner_c" > "${scanner_c}.stripped"
        if [[ -s "${scanner_c}.stripped" ]]; then
            mv "${scanner_c}.stripped" "$scanner_c"
            local line_count_after
            line_count_after=$(wc -l < "$scanner_c")
            log_debug "Stripped BRSANESUFFIX==1 dead code: $line_count_before → $line_count_after lines"
        else
            rm -f "${scanner_c}.stripped"
            log_debug "Strip failed, compiling with original source"
        fi
    fi

    # Fix time_t/long size mismatch in WriteLogFileString (brother_log.c).
    # On 32-bit ARM with 64-bit time_t (Raspbian Trixie), the expression
    # (ltime%1000) is 64-bit but sprintf's %ld reads only 32 bits. This
    # misaligns the subsequent %s argument, causing strlen() to SIGSEGV
    # on a garbage pointer. Cast to (long) to match the %ld format.
    # There is exactly one occurrence of (ltime%1000) in brother_log.c.
    local brother_log_c="$brscan_src/backend_src/brother_log.c"
    if [[ -f "$brother_log_c" ]]; then
        sed -i 's/(ltime%1000)/(long)(ltime%1000)/' "$brother_log_c"
        log_debug "Patched brother_log.c: cast (ltime%1000) to (long) for time_t safety"
    fi

    local brother2_c="$brscan_src/backend_src/brother2.c"

    # Stall detection + CPU yield inside ReadDeviceData (brother_devaccs.c).
    # The DCP-130C scanner sends all scan data then simply stops sending
    # without an explicit end-of-page marker. The backend loops forever
    # calling ReadDeviceData which returns 0 bytes with iReadStatus=2
    # ("reading"). After STALL_THRESHOLD consecutive zero-byte reads,
    # we force nResultSize=-1 which signals "end of data" to
    # ReadNonFixedData, causing bReadbufEnd=TRUE and ending the scan.
    #
    # CPU fix: The original code tight-loops on usb_bulk_read() when no
    # data is available, burning 100% CPU. We add usleep(2000) (2 ms)
    # after any zero-byte read to yield the CPU. At 150 DPI 24-bit
    # color the scanner produces ~22 lines/sec (~46 ms/line), so a 2 ms
    # sleep adds negligible overhead but drops CPU usage dramatically.
    #
    # Debug: When BROTHER_DEBUG=1 is set, counts total USB reads,
    # zero-byte reads, and total bytes, printing a summary at EOF.
    local devaccs_c="$brscan_src/backend_src/brother_devaccs.c"
    if [[ -f "$devaccs_c" ]]; then
        # Inject stall detection counters + debug variables before the
        # WriteLog at the start of ReadDeviceData.
        sed -i '/WriteLog.*ReadDeviceData Start nReadSize/i\
{\
\t#ifndef STALL_THRESHOLD\
\t#define STALL_THRESHOLD 200\
\t#endif\
\tstatic int _rdd_zero_streak = 0;\
\tstatic int _rdd_had_data = 0;\
\tstatic unsigned long _rdd_reads = 0;\
\tstatic unsigned long _rdd_zero_reads = 0;\
\tstatic unsigned long _rdd_total_bytes = 0;\
\tstatic int _rdd_debug = -1;\
\tif (_rdd_debug < 0) {\
\t\tconst char *_e = getenv("BROTHER_DEBUG");\
\t\t_rdd_debug = (_e && _e[0] == '"'"'1'"'"');\
\t}' "$devaccs_c"

        # After the ReadEnd WriteLog, add stall detection + CPU yield:
        # - Count every USB read for debug stats
        # - On data: reset streak, accumulate bytes
        # - On zero-byte: usleep(2000) to yield CPU, then check stall
        # - On stall (200 consecutive zeros after data): force EOF
        sed -i '/WriteLog.*ReadDeviceData ReadEnd nResultSize/a\
\t_rdd_reads++;\
\tif (nResultSize > 0) {\
\t\t_rdd_zero_streak = 0;\
\t\t_rdd_had_data = 1;\
\t\t_rdd_total_bytes += nResultSize;\
\t} else {\
\t\t_rdd_zero_reads++;\
\t\tusleep(2000);\
\t\tif (_rdd_had_data) {\
\t\t\t_rdd_zero_streak++;\
\t\t\tif (_rdd_zero_streak >= STALL_THRESHOLD) {\
\t\t\t\tif (_rdd_debug)\
\t\t\t\t\tfprintf(stderr, "[BROTHER2] ReadDeviceData EOF: %lu reads (%lu zero), %lu bytes total\\n",\
\t\t\t\t\t\t_rdd_reads, _rdd_zero_reads, _rdd_total_bytes);\
\t\t\t\tnResultSize = -1;\
\t\t\t\t_rdd_zero_streak = 0;\
\t\t\t}\
\t\t}\
\t}\
}' "$devaccs_c"

        log_debug "Injected ReadDeviceData stall detection + CPU yield into brother_devaccs.c"
    fi

    local scanner_c="$brscan_src/backend_src/brother_scanner.c"
    if [[ -f "$scanner_c" ]]; then
        # Fix end-of-scan handling: When ReadNonFixedData returns -1
        # (from our stall detection), the original code (M-LNX-159) sets
        # bReadbufEnd=TRUE then does "return SANE_STATUS_IO_ERROR" which
        # aborts the scan immediately. The scan data is complete but gets
        # reported as SANE_STATUS_IO_ERROR instead of SANE_STATUS_EOF.
        #
        # Fix: Replace the hard-coded "return SANE_STATUS_IO_ERROR" in the
        # rc<0 path with iProcessEnd=1 + break so PageScan falls through
        # to ProcessMain which flushes buffered data. The next sane_read
        # sees iProcessEnd=1 and returns SANE_STATUS_EOF.
        #
        # The M-LNX-159 comment uniquely identifies the rc<0 error path:
        #   return SANE_STATUS_IO_ERROR;        //M-LNX-159
        sed -i '/return SANE_STATUS_IO_ERROR;.*M-LNX-159/{
s|return SANE_STATUS_IO_ERROR;.*|this->scanState.iProcessEnd = 1;|
a\
\t\t\t\tbreak;
}' "$scanner_c"

        log_debug "Patched PageScan end-of-scan handling in brother_scanner.c"
    fi

    # Check for required headers
    local sane_header=""
    for hdr_path in /usr/include/sane/sane.h "$brscan_src/include/sane/sane.h"; do
        if [[ -f "$hdr_path" ]]; then
            sane_header="$hdr_path"
            break
        fi
    done
    if [[ -z "$sane_header" ]]; then
        log_warn "SANE headers not found (install libsane-dev)"
        return 1
    fi
    log_debug "Using SANE headers from: $(dirname "$(dirname "$sane_header")")"

    # Check for libusb-0.1 header (usb.h)
    if [[ ! -f /usr/include/usb.h ]] && [[ ! -f "$brscan_src/include/usb.h" ]]; then
        log_warn "usb.h header not found (install libusb-dev)"
        return 1
    fi

    # Check for curses header (brother_advini.c needs it)
    if [[ ! -f /usr/include/curses.h ]] && [[ ! -f /usr/include/ncurses.h ]]; then
        log_warn "curses.h header not found (install libncurses-dev)"
        return 1
    fi

    # Compiler flags — use arrays to avoid eval
    local -a common_flags=(-O2 -fPIC -w
        "-I${brscan_src}" "-I${brscan_src}/include"
        "-I${brscan_src}/backend_src"
        "-I${brscan_src}/libbrscandec2" "-I${brscan_src}/libbrcolm2"
        -DHAVE_CONFIG_H -D_GNU_SOURCE
    )
    local -a backend_flags=(
        '-DPATH_SANE_CONFIG_DIR="/etc/sane.d"'
        '-DPATH_SANE_DATA_DIR="/usr/share"'
        -DV_MAJOR=1 -DV_MINOR=0 -DBRSANESUFFIX=2 -DBACKEND_NAME=brother2
    )

    # Compile main backend (brother2.c #includes all other .c files)
    log_info "Compiling SANE backend..."
    local gcc_output
    gcc_output=$(gcc -c "${common_flags[@]}" "${backend_flags[@]}" \
        "${brscan_src}/backend_src/brother2.c" -o "$build_dir/brother2.o" 2>&1) || true
    if [[ ! -f "$build_dir/brother2.o" ]]; then
        log_warn "Failed to compile brother2.c"
        log_debug "gcc output: $gcc_output"
        return 1
    fi
    log_debug "brother2.o compiled"

    # Compile sane_strstatus
    gcc -c "${common_flags[@]}" -DBACKEND_NAME=brother2 \
        "${brscan_src}/backend_src/sane_strstatus.c" -o "$build_dir/sane_strstatus.o" 2>/dev/null || true

    # Compile sanei support files
    for sf in sanei_constrain_value sanei_init_debug sanei_config; do
        gcc -c "${common_flags[@]}" \
            "${brscan_src}/sanei/${sf}.c" -o "$build_dir/${sf}.o" 2>/dev/null || true
        if [[ ! -f "$build_dir/${sf}.o" ]]; then
            log_warn "Failed to compile ${sf}.c"
            return 1
        fi
        log_debug "${sf}.o compiled"
    done

    # Compile ARM stub for libbrscandec2 (scan data decode)
    log_info "Creating ARM scan decoder library..."
    local stub_src="$SCRIPT_DIR/DCP-130C/scandec_stubs.c"
    if [[ ! -f "$stub_src" ]]; then
        log_warn "Source file not found: $stub_src"
        return 1
    fi
    gcc -shared -fPIC -O2 -w -o "$build_dir/libbrscandec2.so.1.0.0" \
        "$stub_src" || {
        log_warn "Failed to compile libbrscandec2 stub"
        return 1
    }
    log_debug "libbrscandec2.so.1.0.0 compiled (from DCP-130C/scandec_stubs.c)"

    # Compile ARM stub for libbrcolm2 (color matching — pass-through)
    log_info "Creating ARM color matching library..."
    local colm_src="$SCRIPT_DIR/DCP-130C/brcolor_stubs.c"
    if [[ ! -f "$colm_src" ]]; then
        log_warn "Source file not found: $colm_src"
        return 1
    fi
    gcc -shared -fPIC -O2 -w -o "$build_dir/libbrcolm2.so.1.0.0" \
        "$colm_src" || {
        log_warn "Failed to compile libbrcolm2 stub"
        return 1
    }
    log_debug "libbrcolm2.so.1.0.0 compiled (from DCP-130C/brcolor_stubs.c)"

    # Compile backend init stub (constructor logging + SIGSEGV handler)
    local init_src="$SCRIPT_DIR/DCP-130C/backend_init.c"
    if [[ -f "$init_src" ]]; then
        gcc -c -fPIC -O2 -w -o "$build_dir/backend_init.o" "$init_src" || {
            log_warn "Failed to compile backend_init.c (non-fatal, skipping)"
        }
        if [[ -f "$build_dir/backend_init.o" ]]; then
            log_debug "backend_init.o compiled (from DCP-130C/backend_init.c)"
        fi
    fi

    # Link the SANE backend shared library
    log_info "Linking native ARM SANE backend..."
    local -a link_objs=(
        "$build_dir/brother2.o"
        "$build_dir/sane_strstatus.o"
        "$build_dir/sanei_constrain_value.o"
        "$build_dir/sanei_init_debug.o"
        "$build_dir/sanei_config.o"
    )
    # Include backend init stub if compiled
    if [[ -f "$build_dir/backend_init.o" ]]; then
        link_objs+=("$build_dir/backend_init.o")
    fi
    local link_output
    link_output=$(gcc -shared -fPIC -o "$build_dir/libsane-brother2.so.1.0.7" \
        "${link_objs[@]}" \
        -lpthread -lusb -lm -ldl -lc \
        -Wl,-soname,libsane-brother2.so.1 2>&1) || true
    if [[ ! -f "$build_dir/libsane-brother2.so.1.0.7" ]]; then
        log_warn "Failed to link libsane-brother2.so"
        log_debug "Linker output: $link_output"
        return 1
    fi

    # Verify it's the right architecture
    local built_arch
    built_arch=$(file -b "$build_dir/libsane-brother2.so.1.0.7")
    log_debug "Built backend: $built_arch"
    if echo "$built_arch" | grep -qi "Intel 80386\|x86-64"; then
        log_warn "Built library is not ARM (got: $built_arch)"
        log_warn "This shouldn't happen on a Raspberry Pi"
        return 1
    fi

    # Install the native ARM libraries
    log_info "Installing native ARM SANE backend..."

    # Backup original i386 libraries
    for lib_path in /usr/lib/sane/libsane-brother2.so.1.0.7 \
                    /usr/lib/libbrscandec2.so.1.0.0 \
                    /usr/lib/libbrcolm2.so.1.0.0; do
        if [[ -f "$lib_path" ]] && file -b "$lib_path" 2>/dev/null | grep -qi "Intel 80386"; then
            sudo cp "$lib_path" "${lib_path}.i386.bak"
            log_debug "Backed up i386 library: ${lib_path}.i386.bak"
        fi
    done

    # Install ARM libraries
    sudo cp "$build_dir/libsane-brother2.so.1.0.7" /usr/lib/sane/
    sudo cp "$build_dir/libbrscandec2.so.1.0.0" /usr/lib/
    sudo cp "$build_dir/libbrcolm2.so.1.0.0" /usr/lib/

    # Create/update symlinks
    (cd /usr/lib/sane && sudo ln -sf libsane-brother2.so.1.0.7 libsane-brother2.so.1 && \
     sudo ln -sf libsane-brother2.so.1.0.7 libsane-brother2.so)
    (cd /usr/lib && sudo ln -sf libbrscandec2.so.1.0.0 libbrscandec2.so.1 && \
     sudo ln -sf libbrscandec2.so.1.0.0 libbrscandec2.so)
    (cd /usr/lib && sudo ln -sf libbrcolm2.so.1.0.0 libbrcolm2.so.1 && \
     sudo ln -sf libbrcolm2.so.1.0.0 libbrcolm2.so)

    # Run ldconfig to update library cache
    sudo ldconfig 2>/dev/null || true

    log_info "Native ARM SANE backend installed successfully!"
    log_debug "Libraries installed:"
    log_debug "  $(file /usr/lib/sane/libsane-brother2.so.1.0.7)"
    log_debug "  $(file /usr/lib/libbrscandec2.so.1.0.0)"
    log_debug "  $(file /usr/lib/libbrcolm2.so.1.0.0)"

    # Verify library dependencies are resolvable
    log_debug "Checking library dependencies..."
    if ! check_lib_deps /usr/lib/sane/libsane-brother2.so.1.0.7 \
                        /usr/lib/libbrscandec2.so.1.0.0 \
                        /usr/lib/libbrcolm2.so.1.0.0; then
        log_warn "Some library dependencies are missing. The scanner backend may crash."
        log_warn "Try: sudo apt-get install libusb-0.1-4 libsane1"
    fi

    # Verify exported symbols in stub libraries
    if command -v nm &>/dev/null; then
        log_debug "Verifying exported symbols..."
        local scandec_syms
        scandec_syms=$(nm -D /usr/lib/libbrscandec2.so.1.0.0 2>/dev/null | grep -c " T ScanDec" || echo 0)
        local colm_syms
        colm_syms=$(nm -D /usr/lib/libbrcolm2.so.1.0.0 2>/dev/null | grep -c " T ColorMatch" || echo 0)
        log_debug "  libbrscandec2: $scandec_syms ScanDec* exports"
        log_debug "  libbrcolm2: $colm_syms ColorMatch* exports"
        if [[ "$scandec_syms" -lt 5 ]]; then
            log_warn "libbrscandec2 has fewer exports than expected ($scandec_syms, need >= 5)"
        fi
        if [[ "$colm_syms" -lt 3 ]]; then
            log_warn "libbrcolm2 has fewer exports than expected ($colm_syms, need >= 3)"
        fi
    fi

    return 0
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

    # Use the symlink if available
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

    # Enable Brother debug logging for diagnostics
    local ini_file="/usr/local/Brother/sane/Brsane2.ini"
    if [[ -f "$ini_file" ]]; then
        if grep -q "^LogFile=" "$ini_file"; then
            # Ensure it's set to 1 (may be 0 from original deb)
            sudo sed -i 's/^LogFile=.*/LogFile=1/' "$ini_file"
        elif grep -q "^\[Driver\]" "$ini_file"; then
            sudo sed -i '/^\[Driver\]/a LogFile=1' "$ini_file"
        fi
        log_debug "Brother debug logging enabled in Brsane2.ini"
    fi
}

# Test scan
test_scan() {
    log_info "Testing scanner..."

    # Unbind the usblp kernel module from the scanner if it is attached.
    # usblp grabs USB interface 1 for printing; this blocks SANE's
    # usb_claim_interface() and can cause segfaults in older libusb-0.1.
    if lsmod 2>/dev/null | grep -q usblp; then
        log_debug "usblp kernel module is loaded"
        # Find any Brother USB device (vendor 04f9) and unbind usblp from it
        local usblp_bound=false
        for devpath in /sys/bus/usb/devices/*/idVendor; do
            local ddir
            ddir=$(dirname "$devpath")
            if [[ -f "$ddir/idVendor" ]]; then
                local vid
                vid=$(cat "$ddir/idVendor" 2>/dev/null)
                if [[ "$vid" == "04f9" ]]; then
                    # Check if usblp is bound to any interface of this device
                    local devname
                    devname=$(basename "$ddir")
                    for intf_dir in "$ddir"/"$devname":*; do
                        if [[ -L "$intf_dir/driver" ]] && readlink "$intf_dir/driver" 2>/dev/null | grep -q usblp; then
                            usblp_bound=true
                            local intf_name
                            intf_name=$(basename "$intf_dir")
                            log_debug "usblp is bound to $intf_name — unbinding for SANE access"
                            echo "$intf_name" | sudo tee /sys/bus/usb/drivers/usblp/unbind > /dev/null 2>&1 || true
                        fi
                    done
                fi
            fi
        done
        if $usblp_bound; then
            log_info "Unbound usblp from scanner to allow SANE access."
        else
            log_debug "usblp loaded but not bound to Brother scanner"
        fi
    fi

    local scan_cmd=""
    if command -v scanimage &>/dev/null; then
        scan_cmd="scanimage"
        log_debug "Using native scanimage"
    fi
    if [[ -z "$scan_cmd" ]]; then
        log_warn "scanimage not found. Install sane-utils to test scanning."
        return
    fi

    # Pre-scan: verify the SANE backend can be loaded
    if [[ -f /usr/lib/sane/libsane-brother2.so.1.0.7 ]]; then
        local missing_deps
        missing_deps=$(ldd /usr/lib/sane/libsane-brother2.so.1.0.7 2>&1 | grep "not found" || true)
        if [[ -n "$missing_deps" ]]; then
            log_warn "Backend library has missing dependencies:"
            echo "$missing_deps" | while IFS= read -r line; do log_warn "  $line"; done
        fi
    fi

    # List available scanners
    log_info "Checking for available scanners..."
    local scanners
    scanners=$($scan_cmd -L 2>&1 || true)

    if echo "$scanners" | grep -q "error while loading shared libraries\|cannot enable executable stack"; then
        local missing_so
        missing_so=$(echo "$scanners" | grep -oP 'lib[^:]+\.so[^:]*' | head -1)
        log_warn "Scanner command failed: missing library: ${missing_so:-unknown}"
        log_debug "$scan_cmd -L output: $scanners"
    elif echo "$scanners" | grep -qi "device.*brother\|DCP-130C.*scanner"; then
        log_info "Scanner detected: $scanners"
    else
        log_warn "Scanner not detected by SANE."
        log_info "$scan_cmd -L output: ${scanners:-<empty>}"
        log_info "Running SANE diagnostics..."
        local sane_debug_output
        sane_debug_output=$(SANE_DEBUG_DLL=5 SANE_DEBUG_BROTHER2=5 $scan_cmd -L 2>&1 || true)

        local error_lines
        error_lines=$(echo "$sane_debug_output" | grep -iE 'error|fail|cannot|denied|not found' | grep -v '^\s*$' | head -10 || true)
        if [[ -n "$error_lines" ]]; then
            log_debug "SANE errors:"
            while IFS= read -r line; do log_debug "  $line"; done <<< "$error_lines"
        fi
    fi

    # Collect available devices — prefer USB (direct hardware access).
    local -a scan_devices=()
    local net_device="" usb_device=""
    if echo "$scanners" | grep -q "brother2:net"; then
        net_device=$(echo "$scanners" | grep -oP "brother2:net[^'\"]*" | head -1)
    fi
    if echo "$scanners" | grep -q "brother2:bus"; then
        usb_device=$(echo "$scanners" | grep -oP "brother2:bus[^'\"]*" | head -1)
    fi

    if [[ -n "$usb_device" ]]; then
        scan_devices=("$usb_device")
        [[ -n "$net_device" ]] && scan_devices+=("$net_device")
        log_info "Selected USB scanner device: $usb_device"
    elif [[ -n "$net_device" ]]; then
        scan_devices=("$net_device")
        log_info "Selected network scanner device: $net_device"
    fi

    # Ask user if they want to perform a test scan
    read -p "Do you want to perform a test scan? (y/n): " -n 1 -r
    echo

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        local test_output="/tmp/brother_test_scan.pnm"
        local test_stderr="/tmp/brother_test_scan.err"
        local scan_ok=false
        local all_invalid_arg=true

        for try_device in "${scan_devices[@]}"; do
            local -a scan_args=(-d "$try_device" --format=pnm --resolution=150 --mode "True Gray")

            log_info "Performing test scan with device '$try_device'..."
            log_debug "Scan command: $scan_cmd ${scan_args[*]}"
            if timeout 120 "$scan_cmd" "${scan_args[@]}" > "$test_output" 2>"$test_stderr"; then
                if [[ -s "$test_output" ]]; then
                    log_info "Test scan saved to: $test_output"
                    log_info "File size: $(ls -lh "$test_output" | awk '{print $5}')"
                    scan_ok=true
                    break
                else
                    log_warn "Test scan produced an empty file (0 bytes)."
                    all_invalid_arg=false
                    continue
                fi
            else
                local exit_code=$?
                if [[ $exit_code -eq 124 ]]; then
                    log_warn "Test scan with '$try_device' timed out after 120 seconds."
                    all_invalid_arg=false
                elif [[ $exit_code -eq 139 ]]; then
                    log_warn "Segmentation fault during scan with '$try_device'."
                    all_invalid_arg=false
                else
                    log_warn "Test scan with '$try_device' failed (exit code: $exit_code)."
                fi
                if [[ -s "$test_stderr" ]]; then
                    local err_text
                    err_text=$(cat "$test_stderr")
                    local scan_err
                    scan_err=$(echo "$err_text" | grep -i "scanimage\|error\|fail\|Invalid" | head -5)
                    if [[ -n "$scan_err" ]]; then
                        log_info "Scan errors:"
                        echo "$scan_err" | while IFS= read -r line; do log_info "  $line"; done
                    fi
                    if [[ "$err_text" == *"Invalid argument"* ]]; then
                        log_debug "Device '$try_device' returned 'Invalid argument'"
                        continue
                    fi
                fi
                all_invalid_arg=false
            fi
            break
        done

        if ! $scan_ok; then
            if $all_invalid_arg; then
                log_warn "All scan devices returned 'Invalid argument'."
            fi
            log_info "Try manually: sudo $scan_cmd -d '${scan_devices[0]:-brother2:bus1;dev1}' --format=pnm > scan.pnm"
        fi
        rm -f "$test_stderr"
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
    log_info "Backend: Native ARM (compiled from source — direct USB access)"
    log_info "To scan a document (grayscale):"
    log_info "  scanimage -d 'brother2:bus1;dev1' --mode 'True Gray' --resolution=150 --format=pnm > scan.pnm"
    log_info "To scan in color:"
    log_info "  scanimage -d 'brother2:bus1;dev1' --mode '24bit Color' --resolution=300 --format=pnm > scan.pnm"
    log_info "To list available scanners:"
    log_info "  scanimage -L"
    log_info "To check SANE configuration:"
    log_info "  brsaneconfig2 -q"
    echo
    log_info "If the scanner is not detected, try:"
    log_info "  1. Disconnect and reconnect the USB cable"
    log_info "  2. Run: sudo scanimage -L"
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
    install_drivers

    # Compile native ARM SANE backend (direct USB access).
    if ! compile_arm_backend; then
        log_error "Native ARM compilation failed. Cannot install scanner backend."
        log_error "Please ensure gcc, libsane-dev, libusb-dev, and libncurses-dev are installed."
        exit 1
    fi
    log_info "Using native ARM SANE backend (direct USB access)."

    detect_scanner
    configure_scanner
    test_scan
    cleanup
    display_info
    
    log_info "Installation script completed successfully!"
}

# Run main function
main
