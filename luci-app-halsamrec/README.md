# Audio device info LuCI Interface

A dedicated LuCI web interface for viewing audio capture devices on OpenWrt.

## Features

- Displays all audio capture devices from `arecord -l`
- Shows card and device information in a clean table format
- Displays raw `arecord -l` output for detailed inspection
- One-click refresh button to update device information

## Installation

1. Copy the `luci-app-halsamrec` directory to your OpenWrt build system under `package/`
2. Run `make menuconfig` and select:
   - LuCI -> Collections -> luci-app-halsamrec
3. Build the package with `make package/luci-app-halsamrec/compile`
4. Install the generated `.ipk` package on your OpenWrt device

## Usage

After installation, navigate to:
**Services -> HALSAmRec Audio Devices -> Audio Devices**

The page will automatically load all available audio capture devices and display:
- Card number
- Device number
- Device name
- Subdevice information
- Raw `arecord -l` output

## Dependencies

- alsa-utils (for `arecord` command)
- LuCI libraries

## License

GNU General Public License v3.0
