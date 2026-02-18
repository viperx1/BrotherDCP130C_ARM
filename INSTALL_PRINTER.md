# Brother DCP-130C Printer Installation — Step-by-Step Guide

This document explains in detail what `install_printer.sh` does at every stage. The script automates the full installation of the Brother DCP-130C printer driver on a Raspberry Pi (ARM) system, from dependency installation through CUPS configuration and optional network sharing.

---

## Table of Contents

1. [Initialization](#1-initialization)
2. [Root & Architecture Checks](#2-root--architecture-checks)
3. [Printer Sharing Prompt](#3-printer-sharing-prompt)
4. [Fix Broken Packages](#4-fix-broken-packages)
5. [Install Dependencies](#5-install-dependencies)
6. [Set Up CUPS Service](#6-set-up-cups-service)
7. [Download Drivers](#7-download-drivers)
8. [Extract & Modify Drivers for ARM](#8-extract--modify-drivers-for-arm)
9. [Repackage Drivers](#9-repackage-drivers)
10. [Install Drivers](#10-install-drivers)
11. [Detect Printer](#11-detect-printer)
12. [Configure Printer in CUPS](#12-configure-printer-in-cups)
13. [Test Print](#13-test-print)
14. [Cleanup](#14-cleanup)
15. [Display Summary](#15-display-summary)

---

## 1. Initialization

**What happens:** The script sets up its environment before doing any real work.

- **`set -e`** — Enables "exit on error" so any failing command stops the script immediately rather than continuing in a broken state.
- **Debug mode** — Checks for `--debug` flag or `DEBUG=1` environment variable. When enabled, the script emits verbose `[DEBUG]` messages to stderr showing internal state, command outputs, and decision points.
- **Color codes** — Defines ANSI color escape sequences for the four log levels:
  - `[INFO]` (green) — normal progress messages
  - `[WARN]` (yellow) — non-fatal issues
  - `[ERROR]` (red) — fatal problems
  - `[DEBUG]` (cyan) — verbose diagnostics (only shown in debug mode)
- **Variables** — Sets:
  - `PRINTER_NAME="Brother_DCP_130C"` — the canonical CUPS queue name
  - `TMP_DIR="/tmp/brother_dcp130c_install"` — working directory for downloads
  - `PRINTER_SHARED=false` — whether to enable network sharing (set later by user prompt)
- **Driver URLs** — Defines arrays of download URLs for the LPR driver (`dcp130clpr-1.0.1-1.i386.deb`) and CUPS wrapper driver (`dcp130ccupswrapper-1.0.1-1.i386.deb`). Multiple mirrors are listed because Brother has moved files across domains over the years; the Internet Archive is included as a last resort.

---

## 2. Root & Architecture Checks

### `check_root()`

Checks the effective user ID (`$EUID`). If running as root, logs a note; otherwise warns that `sudo` will be needed for privileged commands. The script works either way — it uses `sudo` for individual commands rather than requiring root for the entire script.

### `check_architecture()`

Runs `uname -m` to detect the CPU architecture. The script is designed for:
- `armv7l` — Raspberry Pi 2/3/4 (32-bit)
- `armv6l` — Raspberry Pi Zero/1
- `aarch64` — Raspberry Pi 3/4/5 (64-bit)

If a non-ARM architecture is detected, the user is warned and asked whether to continue.

---

## 3. Printer Sharing Prompt

### `ask_printer_sharing()`

Asks the user whether to enable printer sharing on the local network. If the user answers **yes**, `PRINTER_SHARED` is set to `true`, which later triggers:
- CUPS configuration to listen on all network interfaces
- Avahi/Bonjour daemon installation for mDNS printer discovery
- The printer queue is marked as shared in CUPS

If **no**, the printer is only accessible locally on the Raspberry Pi.

---

## 4. Fix Broken Packages

### `fix_broken_packages()`

**Why this is needed:** A previous failed installation can leave Brother packages (e.g., `dcp130clpr`, `dcp130ccupswrapper`) in a broken dpkg state ("needs to be reinstalled", "half-installed", "half-configured", or "unpacked"). This blocks ALL `apt-get` operations on the system.

**What it does, step by step:**

1. Iterates through the four package variants: `dcp130clpr`, `dcp130ccupswrapper`, `dcp130clpr:i386`, `dcp130ccupswrapper:i386`
2. For each, checks `dpkg -s` for broken status indicators
3. If broken:
   - **Neutralizes maintainer scripts** — Replaces `preinst`, `postinst`, `prerm`, `postrm` with simple `exit 0` scripts. This is necessary because the original scripts may reference `/etc/init.d/lpd` which doesn't exist on modern systems, causing dpkg to fail.
   - **Attempts aggressive purge** — Runs `dpkg --purge --force-all`
   - **Last resort: manual database cleanup** — If dpkg purge fails, directly removes the package's info files from `/var/lib/dpkg/info/` and edits `/var/lib/dpkg/status` to remove the package entry
4. After cleanup, runs `apt-get install -f` to fix remaining dependency issues
5. Verifies `apt-get check` passes

---

## 5. Install Dependencies

### `install_dependencies()`

Runs `apt-get update` and then installs the required packages:

| Package | Purpose |
|---------|---------|
| `cups` | The CUPS print server |
| `cups-client` | Command-line CUPS tools (`lpr`, `lpstat`, etc.) |
| `cups-bsd` | BSD printing compatibility (`lpr`, `lpq`) |
| `libcups2` (or `libcups2t64`) | CUPS client library |
| `libcupsimage2` (or `libcupsimage2t64`) | CUPS image library |
| `printer-driver-all` | Common printer drivers |
| `ghostscript` | PostScript/PDF interpreter |
| `psutils` | PostScript utilities |
| `a2ps` | Text-to-PostScript converter |

**Package name resolution:** On newer Debian/Raspbian (Trixie+), some libraries were renamed with a `t64` suffix (e.g., `libcups2` → `libcups2t64`). The `resolve_package()` function detects which variant is available by:
1. Checking if the original or t64 variant is already installed (`is_package_installed()`)
2. Querying `apt-cache policy` for available candidates
3. Falling back to the original name if neither is found

---

## 6. Set Up CUPS Service

### `setup_cups_service()`

**Basic setup:**
1. Enables and starts the CUPS systemd service
2. Adds the current user to the `lpadmin` group (needed for printer administration)

**If printer sharing is enabled (`PRINTER_SHARED=true`):**

The function modifies `/etc/cups/cupsd.conf`:

| Change | Purpose |
|--------|---------|
| `Listen localhost:631` → `Port 631` | Listen on all network interfaces, not just localhost |
| Add `ServerAlias *` | Accept requests using any hostname (fixes Android "printing service is not enabled" error caused by mDNS hostname mismatch) |
| `Browsing On` | Enable CUPS printer browsing |
| `BrowseLocalProtocols dnssd` | Advertise printers via DNS-SD/mDNS |
| Add `Allow @LOCAL` to `<Location />` and `<Location /printers>` | Allow LAN clients to access the printer |

Then installs and enables **Avahi daemon** for mDNS/Bonjour printer discovery, and restarts CUPS to apply changes.

---

## 7. Download Drivers

### `download_drivers()`

Downloads two `.deb` files from Brother's servers:

1. **LPR driver** (`dcp130clpr-1.0.1-1.i386.deb`) — Contains the core printer filter binaries and configuration
2. **CUPS wrapper** (`dcp130ccupswrapper-1.0.1-1.i386.deb`) — Contains the CUPS filter wrapper script, PPD template, and cupswrapper setup script

### `try_download()`

For each file, tries multiple URLs in order until one succeeds:
1. `download.brother.com` (HTTPS)
2. `download.brother.com` (HTTP)
3. `www.brother.com/pub/bsc/linux/dlf/`
4. `web.archive.org` (Internet Archive fallback)

After downloading, validates the file is a real Debian package (not an HTML error page) using the `file` command.

---

## 8. Extract & Modify Drivers for ARM

### `extract_and_modify_drivers()`

The Brother drivers are built for i386 (x86 32-bit). This step modifies them to install on ARM:

1. **Extracts both `.deb` packages** using `dpkg-deb -x` (data) and `dpkg-deb -e` (control files)

2. **Changes architecture** — In both `DEBIAN/control` files, replaces `Architecture: i386` with `Architecture: all`. This lets dpkg install the package on any architecture.

3. **Removes placeholder conflict** — The CUPS wrapper control file has `Conflicts: CONFLICT_PACKAGE` (a Brother build artifact). This is removed.

4. **Patches `/etc/init.d/lpd` references** — Brother's maintainer scripts reference `/etc/init.d/lpd` which doesn't exist on modern systems (systemd). All such references are replaced with `/bin/true`.

5. **Patches `lpadmin` calls** — The `patch_lpadmin_calls()` function comments out all `lpadmin` invocations in:
   - CUPS wrapper postinst/prerm scripts
   - The cupswrapper script itself (`cupswrapperdcp130c`)
   
   This prevents Brother's scripts from auto-creating a printer named "DCP130C", which would conflict with our canonical name "Brother_DCP_130C". The script uses its own `configure_printer()` function instead.

---

## 9. Repackage Drivers

### `repackage_drivers()`

Rebuilds both modified packages using `dpkg-deb -b`:
- `dcp130clpr_arm.deb` — Modified LPR driver
- `dcp130ccupswrapper_arm.deb` — Modified CUPS wrapper

---

## 10. Install Drivers

### `install_drivers()`

This is the most complex step, handling the actual driver installation and i386 binary compatibility:

1. **Cleans up broken package state** from any previous installs
2. **Installs both `.deb` packages** using `dpkg -i --force-all`
3. **Fixes dependencies** with `apt-get install -f`
4. **Patches the installed cupswrapper script** — Re-applies `/etc/init.d/lpd` and `lpadmin` patches to the now-installed file at `/usr/local/Brother/Printer/dcp130c/cupswrapper/cupswrapperdcp130c`
5. **Re-runs the cupswrapper script** to ensure the CUPS filter pipeline (PPD + filter scripts) is set up correctly
6. **Removes duplicate printers** created by the cupswrapper script

### `remove_duplicate_printers()`

Brother's cupswrapper script creates a printer named "DCP130C" via `lpadmin`. Despite our patches, this can happen if the postinst ran before patches took effect, or from a previous install. This function:

1. Checks for known name variants: `DCP130C`, `dcp130c`, `DCP-130C`, `Brother-DCP-130C`
2. Scans all CUPS printers for any DCP-130C pattern match (case-insensitive)
3. Removes any that don't match our canonical `Brother_DCP_130C` name
4. Cleans up orphan PPD files to prevent CUPS from recreating removed queues

### i386 Binary Support

The LPR driver contains actual i386 ELF binaries (e.g., `brdcp130cfilter`, `brprintconfdcp130c`). On ARM, these need:

1. **`qemu-user-static`** — Provides binfmt_misc i386 emulation
2. **i386 dynamic linker** (`/lib/ld-linux.so.2`) — Downloaded from Debian's libc6 i386 package
3. **i386 C library** (`/lib/i386-linux-gnu/libc.so.6`) — Extracted from the same package
4. **Library path registration** — Creates `/etc/ld.so.conf.d/i386-linux-gnu.conf`
5. **ARM preload fix** — Comments out `libarmmem` in `/etc/ld.so.preload` to prevent errors under qemu

After installing i386 support, the script re-checks all Brother binaries to verify they can execute.

### Grayscale Patch

Patches the Brother filter script (`brlpdwrapperdcp130c`) to translate CUPS color mode options to Brother's proprietary `BRMonoColor` option. When Android/iOS sends `print-color-mode=monochrome`, CUPS maps it to `ColorModel=Gray` (standard PPD), but the Brother driver only reads `BRMonoColor`. The patch detects `ColorModel=Gray` or `print-color-mode=monochrome` in CUPS job options and injects `BRMonoColor=BrMono`.

---

## 11. Detect Printer

### `detect_printer()`

Verifies the printer is connected:
1. Runs `lsusb` to check for a Brother device on USB
2. Runs `lpinfo -v` to check if CUPS has discovered the printer backend

---

## 12. Configure Printer in CUPS

### `configure_printer()`

Sets up the printer queue in CUPS:

1. **Removes duplicate printers** (again, in case CUPS restarts recreated them)
2. **Detects the printer URI** — Queries `lpinfo -v` for `Brother.*DCP-130C`. Falls back to `usb://Brother/DCP-130C` if auto-detection fails.
3. **Finds the PPD file** — Searches common locations:
   - `/usr/share/cups/model/Brother/brother_dcp130c_printer_en.ppd`
   - Dynamic search via `find` and `lpinfo -m`
4. **Patches the PPD** — Adds `APPrinterPreset` entries for print-color-mode mapping (allows Android/iOS to switch between color and monochrome)
5. **Generates a fallback PPD** — If no Brother PPD is found, generates a basic PPD with standard page sizes, resolutions, and color modes
6. **Creates the printer queue** — Uses `lpadmin -p` with the PPD, URI, and sharing options
7. **Sets color mode defaults** — Configures `print-color-mode-supported=color,monochrome`
8. **Sets as default printer** and enables the queue

---

## 13. Test Print

### `test_print()`

1. Shows printer status via `lpstat`
2. Asks the user if they want to print a test page
3. If yes:
   - Creates a simple text test page in `/tmp/test_page.txt`
   - In debug mode, temporarily enables CUPS debug logging
   - Sends the test page via `lpr -P Brother_DCP_130C`
   - Waits for the job to be processed and shows status
   - Checks CUPS error log for filter/backend errors and reports diagnostics
   - Restores original CUPS log level if changed

---

## 14. Cleanup

### `cleanup()`

Removes the temporary working directory (`/tmp/brother_dcp130c_install`) with a safety check to ensure `TMP_DIR` is set and not `/`.

---

## 15. Display Summary

### `display_info()`

Shows a summary of the completed installation:
- Printer name and status
- If sharing is enabled: IP address, CUPS web interface URL, Android discovery instructions
- Usage commands (`lpr`, `lpstat`, `lpq`, CUPS web interface URL)
- Reminder about lpadmin group re-login

The main function also performs a **final duplicate printer cleanup** and CUPS restart before displaying the summary.
