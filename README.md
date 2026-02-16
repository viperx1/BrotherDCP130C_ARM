# BrotherDCP130C_ARM
Driver installer for Brother DCP-130C on Raspberry PI 2B

## Overview

This repository contains automated installation scripts for the Brother DCP-130C printer and scanner drivers on Raspberry Pi ARM-based systems (armv7l, armv6l, aarch64).

## System Requirements

- Raspberry Pi (tested on Raspberry Pi 2B)
- Raspbian/Raspberry Pi OS
- Linux kernel 6.x or compatible
- Internet connection for downloading drivers
- Brother DCP-130C connected via USB

## Features

### Printer (`install_printer.sh`)

1. **Installs Dependencies**: Automatically installs CUPS and required packages
2. **Downloads Drivers**: Fetches official Brother DCP-130C drivers from Brother's website
3. **ARM Compatibility**: Modifies i386 drivers to work on ARM architecture
4. **Automatic Configuration**: Configures the printer in CUPS automatically
5. **Printer Sharing**: Optional LAN sharing with Avahi/Bonjour discovery so other devices on the network can find and use the printer
6. **Test Print**: Offers optional test page printing to verify installation
7. **Error Handling**: Includes robust error checking and logging

### Scanner (`install_scanner.sh`)

1. **Installs Dependencies**: Automatically installs SANE and required packages
2. **Downloads Drivers**: Fetches official Brother brscan2 scanner driver from Brother's website
3. **ARM Compatibility**: Modifies i386 driver to work on ARM architecture
4. **Automatic Configuration**: Configures the scanner in SANE with brsaneconfig2
5. **Test Scan**: Offers optional test scan to verify installation
6. **Error Handling**: Includes robust error checking and logging

## Installation

### Quick Start

1. Clone this repository:
   ```bash
   git clone https://github.com/viperx1/BrotherDCP130C_ARM.git
   cd BrotherDCP130C_ARM
   ```

2. Connect your Brother DCP-130C via USB and power it on

3. Install the printer driver:
   ```bash
   ./install_printer.sh
   ```

4. Install the scanner driver:
   ```bash
   ./install_scanner.sh
   ```

5. Follow the on-screen prompts

### Manual Installation

If you prefer to run the scripts with sudo:

```bash
sudo ./install_printer.sh
sudo ./install_scanner.sh
```

The printer script will:
- Check system architecture
- Ask whether to enable printer sharing on the local network
- Install CUPS and dependencies (plus Avahi if sharing is enabled)
- Download and prepare drivers for ARM
- Install the printer drivers
- Configure the printer in CUPS
- If sharing was enabled, configure CUPS for network access and Avahi/Bonjour discovery
- Optionally print a test page

The scanner script will:
- Check system architecture
- Install SANE and dependencies
- Download and prepare the brscan2 driver for ARM
- Install the scanner driver
- Configure the scanner with brsaneconfig2
- Optionally perform a test scan

## Usage

### Printing

After installation, you can:

- **Print a file**:
  ```bash
  lpr -P Brother_DCP_130C myfile.txt
  ```

- **Check printer status**:
  ```bash
  lpstat -p Brother_DCP_130C
  ```

- **View print queue**:
  ```bash
  lpq -P Brother_DCP_130C
  ```

- **Manage printer via web interface**:
  Open http://localhost:631 in your browser

### Scanning

After installation, you can:

- **Scan a document**:
  ```bash
  scanimage --format=png --resolution=300 > scan.png
  ```

- **List available scanners**:
  ```bash
  scanimage -L
  ```

- **Check scanner configuration**:
  ```bash
  brsaneconfig2 -q
  ```

### Printer Sharing

During installation, the script asks whether you want to share the printer on your local network. If you choose **yes**:

- CUPS is configured to listen on all network interfaces (port 631)
- Avahi (mDNS/Bonjour) is installed and enabled so other devices can automatically discover the printer
- The printer is marked as shared in CUPS

Other devices on the same network can then discover and use the printer automatically:

- **Android**: The printer appears in the built-in **Default Print Service** (no app needed). Open any document, tap **Print**, and select the Brother printer.
- **macOS / iOS**: It will appear in **System Settings > Printers & Scanners** and in the print dialog.
- **Linux**: It will appear through CUPS browsing.
- **Windows**: It can be added via the CUPS IPP URL (e.g. `http://<raspberry-pi-ip>:631/printers/Brother_DCP_130C`).

If you chose **no** during installation, the printer is only available locally on the Raspberry Pi.

## Verification

### Printer

To verify the printer is detected:

```bash
lpinfo -v | grep Brother
```

Expected output:
```
direct usb://Brother/DCP-130C?serial=BROB7F595603
```

### Scanner

To verify the scanner is detected:

```bash
scanimage -L
```

Expected output:
```
device `brother2:bus1;dev1' is a Brother DCP-130C USB scanner
```

## Troubleshooting

### Debug mode

Run the scripts with `--debug` for verbose diagnostic output:
```bash
sudo ./install_printer.sh --debug
sudo ./install_scanner.sh --debug
```

### Driver download fails

Brother may remove or move driver files over time. The scripts try multiple
download sources automatically. If all sources fail, you can download the
drivers manually and place them in the temporary directory:

**Printer drivers:**
```bash
mkdir -p /tmp/brother_dcp130c_install
# Download dcp130clpr-1.0.1-1.i386.deb and dcp130ccupswrapper-1.0.1-1.i386.deb
# from Brother's support website or another source, then:
cp dcp130clpr-1.0.1-1.i386.deb /tmp/brother_dcp130c_install/dcp130clpr.deb
cp dcp130ccupswrapper-1.0.1-1.i386.deb /tmp/brother_dcp130c_install/dcp130ccupswrapper.deb
```

**Scanner driver:**
```bash
mkdir -p /tmp/brother_dcp130c_scanner_install
# Download brscan2-0.2.5-1.i386.deb from Brother's support website or another source, then:
cp brscan2-0.2.5-1.i386.deb /tmp/brother_dcp130c_scanner_install/brscan2.deb
```

### Printer not detected
- Ensure the printer is powered on and connected via USB
- Try a different USB cable or port
- Run `lsusb` to check if the printer appears

### Permission issues
- Make sure you're in the `lpadmin` group: `groups $USER`
- Log out and back in after installation if you were added to the group
- Try running with sudo: `sudo ./install_printer.sh`

### Print job stuck in queue
- Check printer status: `lpstat -p Brother_DCP_130C`
- Cancel stuck jobs: `cancel -a Brother_DCP_130C`
- Restart CUPS: `sudo systemctl restart cups`

### Android: color settings ignored
CUPS maps IPP `print-color-mode=monochrome` to the PPD's standard `ColorModel`
option. But the Brother driver reads its own proprietary `BRMonoColor` option
and ignores `ColorModel`. The script patches the installed Brother filter script
(`brlpdwrapperdcp130c`) to detect `ColorModel=Gray` or `print-color-mode=monochrome`
in the CUPS job options and translate them to `BRMonoColor=BrMono`, so the
Brother driver receives the grayscale instruction in its native format.
If you installed before this fix, re-run the installer.

### Android: "printing service is not enabled" error
This is caused by a hostname mismatch — Android connects using the
mDNS-discovered name but CUPS only accepts its own `ServerName` by default.
The script adds `ServerAlias *` to `cupsd.conf` to accept any hostname.
If the error persists after re-running the installer, verify manually:
```bash
grep 'ServerAlias' /etc/cups/cupsd.conf
# Should show: ServerAlias *
```

### Android: stale/dead printers showing up
Android caches previously discovered printers. If you see old or dead printer
entries, clear the Android print service cache:

**Settings → Apps → Default Print Service → Storage → Clear Cache**

### Scanner not detected
- Ensure the device is powered on and connected via USB
- Try a different USB cable or port
- Run `lsusb` to check if the Brother device appears
- Run `sudo scanimage -L` to list detected scanners
- Verify the SANE backend: `grep brother2 /etc/sane.d/dll.conf`

### Scanner permission issues
- Check if your user has access to the USB device
- Try running with sudo: `sudo scanimage -L`
- You may need to add udev rules for the Brother scanner

## Technical Details

### Driver Sources

**Printer:**
- **LPR Driver**: dcp130clpr-1.0.1-1.i386.deb
- **CUPS Wrapper**: dcp130ccupswrapper-1.0.1-1.i386.deb

**Scanner:**
- **SANE Backend**: brscan2-0.2.5-1.i386.deb

The scripts modify these i386 packages to work on ARM architecture by:
1. Extracting the .deb packages
2. Changing architecture from i386 to "all" in control files
3. Repackaging for ARM installation

### System Information

Tested on:
- **System**: Linux BrotherDCP130C 6.12.47+rpt-rpi-v7
- **Architecture**: armv7l
- **OS**: Raspbian 1:6.12.47-1+rpt1 (2025-09-16)
- **Hardware**: Raspberry Pi 2B

## License

This project is provided as-is for educational and practical purposes. Brother printer drivers are subject to Brother Industries' license terms.

## Contributing

Contributions are welcome! Please feel free to submit issues or pull requests.

## Acknowledgments

- Brother Industries for providing Linux drivers
- The CUPS project for printer management
- The Raspberry Pi community
