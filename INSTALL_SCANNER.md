# Brother DCP-130C Scanner Installation — Step-by-Step Guide

This document explains in detail what `install_scanner.sh` does at every stage. The script automates the full installation of the Brother DCP-130C scanner driver on a Raspberry Pi (ARM) system, including native ARM backend compilation, SANE configuration, and optional network sharing with AirSane (eSCL) for cross-platform scanner discovery.

---

## Table of Contents

1. [Initialization](#1-initialization)
2. [Root & Architecture Checks](#2-root--architecture-checks)
3. [Scanner Sharing Prompt](#3-scanner-sharing-prompt)
4. [Fix Broken Packages](#4-fix-broken-packages)
5. [Install Dependencies](#5-install-dependencies)
6. [Download Driver](#6-download-driver)
7. [Install Driver Config Files](#7-install-driver-config-files)
8. [Compile Native ARM SANE Backend](#8-compile-native-arm-sane-backend)
9. [Detect Scanner](#9-detect-scanner)
10. [Configure Scanner](#10-configure-scanner)
11. [Set Up Scanner Sharing](#11-set-up-scanner-sharing)
12. [Test Scan](#12-test-scan)
13. [Cleanup](#13-cleanup)
14. [Display Summary](#14-display-summary)

---

## 1. Initialization

**What happens:** The script sets up its environment before doing any real work.

- **`set -e`** — Enables "exit on error" so any failing command stops the script immediately.
- **Debug mode** — Checks for `--debug` flag or `DEBUG=1` environment variable for verbose output.
- **Logging functions** — Defines four log levels: `[INFO]` (green), `[WARN]` (yellow), `[ERROR]` (red), `[DEBUG]` (cyan, only in debug mode).
- **Variables** — Sets:
  - `SCRIPT_DIR` — Absolute path to the script's directory (used to locate `DCP-130C/*.c` source files)
  - `SCANNER_MODEL="DCP-130C"` — Model name for brsaneconfig2 registration
  - `SCANNER_NAME="Brother_DCP_130C"` — Canonical scanner name
  - `TMP_DIR="/tmp/brother_dcp130c_scanner_install"` — Working directory for downloads and builds
  - `SCANNER_SHARED=false` — Whether to enable network sharing
  - `AIRSANE_INSTALLED=false` — Tracks whether AirSane was successfully installed
  - `AIRSANE_VERSION="0.4.9"` — AirSane version to build
- **Driver URLs** — Defines arrays of download URLs for:
  - The brscan2 i386 `.deb` package (config files and brsaneconfig2 binary)
  - The brscan2 source tarball (for native ARM compilation)
  - The AirSane source tarball (for eSCL server)

---

## 2. Root & Architecture Checks

### `check_root()`
Checks `$EUID`. Warns if not running as root (sudo will be needed for individual commands).

### `check_architecture()`
Verifies the system is ARM (`armv7l`, `armv6l`, or `aarch64`). Warns and asks for confirmation on non-ARM systems.

---

## 3. Scanner Sharing Prompt

### `ask_scanner_sharing()`

Asks the user whether to enable scanner sharing on the local network. If **yes**, `SCANNER_SHARED=true` triggers later:
- `saned` (SANE network daemon) configuration for Linux SANE clients
- Avahi/Bonjour advertisement for automatic discovery
- AirSane eSCL server build and installation for Windows, macOS, iOS, and Android

---

## 4. Fix Broken Packages

### `fix_broken_packages()`

Same logic as the printer script, but for `brscan2` and `brscan2:i386` packages. Cleans up broken dpkg state from previous failed installs using the same escalation strategy: neutralize maintainer scripts → aggressive purge → manual database cleanup.

---

## 5. Install Dependencies

### `install_dependencies()`

Runs `apt-get update` and installs:

| Package | Purpose |
|---------|---------|
| `sane-utils` | SANE scanner tools (`scanimage`, `sane-find-scanner`) |
| `libsane1` | SANE library |
| `libusb-0.1-4` | USB library (libusb-0.1 API used by Brother backend) |
| `gcc` | C compiler (for native ARM backend compilation) |
| `libsane-dev` | SANE development headers |
| `libusb-dev` | USB development headers |
| `libncurses-dev` | Curses headers (required by brother_advini.c) |

Uses the same `resolve_package()` / `is_package_installed()` logic as the printer script to handle t64 package name variants on newer Debian.

---

## 6. Download Driver

### `download_drivers()`

Downloads the brscan2 i386 `.deb` package (`brscan2-0.2.5-1.i386.deb`) using `try_download()` with multiple fallback URLs.

### `try_download()` (Scanner version)

Enhanced version compared to the printer script:
- Uses longer timeouts (60s) and more retries (3)
- For `.tar.gz` files, performs a `gzip -t` integrity check to catch truncated downloads
- Logs file size and type after download

---

## 7. Install Driver Config Files

### `install_drivers()`

Unlike the printer script, the scanner script does **not** install the i386 `.deb` as-is. Instead:

1. **Extracts only config files** from the `.deb` using `dpkg-deb -x`
2. **Copies to system directories** — Installs config files, calibration data, model info, and `brsaneconfig2` to `/usr/local/Brother/sane/`
3. **Creates symlink** — Links `brsaneconfig2` to `/usr/bin/brsaneconfig2` for PATH access

### i386 Support for brsaneconfig2

The `brsaneconfig2` tool is the only i386 binary needed (the SANE backend is compiled natively for ARM). To make it work:

1. **Installs `qemu-user-static`** for binfmt_misc i386 emulation
2. **Downloads i386 libc** from Debian mirrors:
   - Extracts `ld-linux.so.2` (dynamic linker) and `libc.so.6`
   - Registers i386 library paths with `ldconfig`
3. **Fixes ARM preload** — Comments out `libarmmem` in `/etc/ld.so.preload`
4. **Verifies** — Tests that `brsaneconfig2 -q` executes successfully

---

## 8. Compile Native ARM SANE Backend

### `compile_arm_backend()`

This is the key step that differentiates the scanner installer from a simple package install. Rather than trying to run the i386 SANE backend through QEMU emulation (which is slow and often crashes), the script compiles a **native ARM SANE backend** from Brother's open-source code.

### Step 8a: Download Source

Downloads `brscan2-src-0.2.5-1.tar.gz` from Brother's website. Validates existing downloads with `gzip -t` and retries on corruption.

### Step 8b: Source Patches

Before compilation, several patches are applied to fix issues:

1. **Strip dead code paths** — The source has `#if BRSANESUFFIX==2` / `#elif BRSANESUFFIX==1` blocks. Since we compile with `-DBRSANESUFFIX=2`, the `==1` code paths are removed with `awk` to eliminate confusion.

2. **Fix time_t crash** — In `brother_log.c`, the expression `(ltime%1000)` is 64-bit on 32-bit ARM with 64-bit `time_t` (Raspbian Trixie), but `sprintf`'s `%ld` reads only 32 bits. This misaligns subsequent arguments, causing SIGSEGV. Fix: cast to `(long)`.

3. **Stall detection + CPU yield** — The DCP-130C scanner sends all data then simply stops without an end-of-page marker. The original code loops forever. The patch adds:
   - **`usleep(2000)`** after zero-byte USB reads to yield CPU (reduces 100% CPU usage)
   - **Stall threshold** — After 200 consecutive zero-byte reads (following actual data), forces an EOF return
   - **Debug counters** — When `BROTHER_DEBUG=1`, tracks total reads, zero-byte reads, and bytes for a summary at EOF

4. **End-of-scan fix** — The original code returns `SANE_STATUS_IO_ERROR` when a stall is detected, which aborts the scan and reports an error. The patch changes this to set `iProcessEnd=1` + `break`, which lets the scan complete normally and return `SANE_STATUS_EOF`.

### Step 8c: Compilation

Compiles the following from source using `gcc`:

| Component | Source | Output |
|-----------|--------|--------|
| Main SANE backend | `brother2.c` (includes all other `.c` files) | `brother2.o` |
| SANE status strings | `sane_strstatus.c` | `sane_strstatus.o` |
| SANE support functions | `sanei_constrain_value.c`, `sanei_init_debug.c`, `sanei_config.c` | `.o` files |
| Scan data decoder | `DCP-130C/scandec_stubs.c` | `libbrscandec2.so.1.0.0` |
| Color matching | `DCP-130C/brcolor_stubs.c` | `libbrcolm2.so.1.0.0` |
| Backend init | `DCP-130C/backend_init.c` | `backend_init.o` |

### ARM Stub Libraries

Two proprietary i386 libraries are replaced with native ARM implementations:

#### `scandec_stubs.c` — Scan Data Decoder

Replaces Brother's proprietary `libbrscandec2.so`. Handles three compression modes:
- **SCIDC_WHITE (1)** — Entire line is white (fill with 0xFF)
- **SCIDC_NONCOMP (2)** — Uncompressed raster data (direct copy)
- **SCIDC_PACK (3)** — PackBits run-length compression (TIFF/Apple standard)

For 24-bit color, the scanner sends separate R, G, B planes. The stub buffers each plane and emits interleaved RGB when all three are received.

When `BROTHER_DEBUG=1` is set, collects timing statistics and prints a scan session summary at close.

#### `brcolor_stubs.c` — Color Matching

Replaces Brother's proprietary `libbrcolm2.so`. This is a pass-through — color matching (ICC profile application) is a cosmetic adjustment that's not essential for scanning. Returns `TRUE` without modifying data, producing uncorrected but valid scan output.

#### `backend_init.c` — Backend Initialization

Linked into `libsane-brother2.so`. Installs a SIGSEGV handler so crashes produce a visible error message instead of dying silently. When `BROTHER_DEBUG=1` is set, probes the USB environment to report bus speed, driver binding status, and QEMU binfmt_misc handlers.

### Step 8d: Linking

Links all object files into `libsane-brother2.so.1.0.7` with dependencies: `pthread`, `usb`, `m`, `dl`, `c`.

### Step 8e: Installation

1. **Backs up** original i386 libraries
2. **Installs** ARM libraries to `/usr/lib/sane/` and `/usr/lib/`
3. **Creates symlinks** (SONAME: `libsane-brother2.so.1`, `libbrscandec2.so.1`, `libbrcolm2.so.1`)
4. **Runs `ldconfig`** to update the library cache
5. **Verifies** architecture, library dependencies, and exported symbols

---

## 9. Detect Scanner

### `detect_scanner()`

1. Runs `lsusb` to check for a Brother device on USB
2. If found, calls `diagnose_usb_speed()`

### `diagnose_usb_speed()`

Reads sysfs attributes to report the scanner's USB connection speed:
- Reads `/sys/bus/usb/devices/*/speed` for the negotiated link rate
- The DCP-130C is a "USB 2.0 Full-Speed" device — USB 2.0 compliant but only supports 12 Mbit/s (not 480 Mbit/s High-Speed)
- Also checks the host controller port speed to determine if the device or host is the bottleneck

---

## 10. Configure Scanner

### `configure_scanner()`

1. **Updates SANE dll.conf** — Adds `brother2` to `/etc/sane.d/dll.conf` so SANE loads the Brother backend
2. **Registers the scanner** — Runs `brsaneconfig2 -a name=Brother_DCP_130C model=DCP-130C nodename=local_device`
3. **Configures Brsane2.ini** — In the `[Driver]` section:
   - Enables Brother debug logging (`LogFile=1`)
   - Sets `compression=1` to request PackBits compression (the scanner firmware decides whether to actually compress based on scan mode)

---

## 11. Set Up Scanner Sharing

### `setup_scanner_sharing()`

Only runs if `SCANNER_SHARED=true`. Configures three layers of network sharing:

### Layer 1: saned (SANE Network Daemon)

- Configures `/etc/sane.d/saned.conf` with RFC 1918 private network ranges:
  - `192.168.0.0/16`
  - `10.0.0.0/8`
  - `172.16.0.0/12`
- Enables `saned.socket` (systemd socket activation on port 6566)
- This allows Linux SANE clients to use the scanner over the network

### Layer 2: Avahi/mDNS Advertisement

- Installs and enables `avahi-daemon`
- Creates `/etc/avahi/services/sane.service` advertising `_sane-port._tcp` on port 6566
- This lets Linux SANE clients auto-discover the scanner via mDNS

### Layer 3: AirSane eSCL Server

### `install_airsane()`

Builds and installs [AirSane](https://github.com/SimulPiscator/AirSane) from source. AirSane exposes SANE scanners via the eSCL/AirScan protocol (`_uscan._tcp`), enabling automatic discovery by **Windows 10/11, macOS, iOS, and Android**.

**Build process:**
1. Installs build dependencies: `cmake`, `g++`, `libjpeg-dev`, `libpng-dev`, `libavahi-client-dev`, `libusb-1.0-0-dev`
2. Downloads AirSane v0.4.9 source tarball from GitHub
3. Builds with `cmake` + `make -j$(nproc)`
4. Installs with `make install`

**Post-install configuration:**
- Adds `saned` user to `scanner` and `lp` groups
- Creates a udev rule (`/etc/udev/rules.d/60-brother-scanner.rules`) granting the `scanner` group access to the Brother USB device (vendor `04f9`, product `01a8`)
- Enables and starts the `airsaned` systemd service

---

## 12. Test Scan

### `test_scan()`

1. **Unbinds usblp** — If the `usblp` kernel module is bound to the scanner, it blocks SANE's USB access. The script finds any Brother device (vendor `04f9`) and unbinds usblp from its interfaces.

2. **Pre-scan verification** — Checks the SANE backend library for missing dependencies using `ldd`.

3. **Lists scanners** — Runs `scanimage -L` and checks the output:
   - If a Brother scanner is detected, proceeds
   - If not found, runs SANE diagnostics with debug flags (`SANE_DEBUG_DLL=5 SANE_DEBUG_BROTHER2=5`)

4. **Device selection** — Prefers USB device (`brother2:bus*`) over network device (`brother2:net*`).

5. **Asks user** whether to perform a test scan.

6. **Performs scan** — Runs `scanimage` with:
   - Device: the detected USB or network device
   - Format: PNM
   - Resolution: 150 DPI
   - Mode: "True Gray" (fastest mode — 3x less data than color)
   - Timeout: 120 seconds
   
   Saves output to `/tmp/brother_test_scan.pnm`. Reports file size on success. On failure, reports the error and suggests a manual command.

---

## 13. Cleanup

### `cleanup()`

Removes the temporary working directory (`/tmp/brother_dcp130c_scanner_install`) with safety checks.

---

## 14. Display Summary

### `display_info()`

Shows a comprehensive summary of the completed installation:

- **Scanner name** and backend type (Native ARM)
- **Usage commands** — `scanimage` examples for grayscale and color scans
- **Performance notes** — USB speed limitations, compression behavior, CPU usage explanation
- **Sharing status** — If enabled, shows:
  - Linux client instructions
  - saned port info (6566)
  - If AirSane is installed: Windows, macOS, iOS, Android discovery instructions + web interface URL
  - If AirSane failed: notes that only Linux SANE clients can use the shared scanner
- **Troubleshooting** — USB reconnection, `scanimage -L`, debug mode instructions
