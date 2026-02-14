# BrotherDCP130C_ARM
Driver installer for Brother DCP-130C on Raspberry PI 2B

## Overview

This repository contains an automated installation script for the Brother DCP-130C printer driver on Raspberry Pi ARM-based systems (armv7l, armv6l, aarch64).

## System Requirements

- Raspberry Pi (tested on Raspberry Pi 2B)
- Raspbian/Raspberry Pi OS
- Linux kernel 6.x or compatible
- Internet connection for downloading drivers
- Brother DCP-130C printer connected via USB

## Features

The installation script (`install_printer.sh`) performs the following:

1. **Installs Dependencies**: Automatically installs CUPS and required packages
2. **Downloads Drivers**: Fetches official Brother DCP-130C drivers from Brother's website
3. **ARM Compatibility**: Modifies i386 drivers to work on ARM architecture
4. **Automatic Configuration**: Configures the printer in CUPS automatically
5. **Test Print**: Offers optional test page printing to verify installation
6. **Error Handling**: Includes robust error checking and logging

## Installation

### Quick Start

1. Clone this repository:
   ```bash
   git clone https://github.com/viperx1/BrotherDCP130C_ARM.git
   cd BrotherDCP130C_ARM
   ```

2. Connect your Brother DCP-130C printer via USB and power it on

3. Run the installation script:
   ```bash
   ./install_printer.sh
   ```

4. Follow the on-screen prompts

### Manual Installation

If you prefer to run the script step by step or with sudo:

```bash
sudo ./install_printer.sh
```

The script will:
- Check system architecture
- Install CUPS and dependencies
- Download and prepare drivers for ARM
- Install the printer drivers
- Configure the printer in CUPS
- Optionally print a test page

## Usage

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

## Verification

To verify the printer is detected:

```bash
lpinfo -v | grep Brother
```

Expected output:
```
direct usb://Brother/DCP-130C?serial=BROB7F595603
```

## Troubleshooting

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

## Technical Details

### Driver Sources

- **LPR Driver**: dcp130clpr-1.1.2-1.i386.deb
- **CUPS Wrapper**: dcp130ccupswrapper-1.1.2-1.i386.deb

The script modifies these i386 packages to work on ARM architecture by:
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
