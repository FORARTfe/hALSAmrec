# Audio Device Info LuCI Interface

A dedicated LuCI web interface for viewing and managing audio capture devices on OpenWrt with recorder service control.

## Features

- **Recorder Service Control:** Start/Stop toggle button with real-time status display
- **ALSA Hardware Probe:** Display detailed hardware parameters for `hw:0,0`
- **Status Monitoring:** Real-time status display (RUNNING/STOPPED)
- **Safety Warnings:** Prevents probing while recorder is running
- **Auto-Refresh:** Status auto-updates every 3 seconds
- **Clean Interface:** Integrated into main LuCI menu bar

## Installation

1. Copy the `luci-app-halsamrec` directory to your OpenWrt build system under `package/`
2. Run `make menuconfig` and select:
   - LuCI -> Collections -> luci-app-halsamrec
3. Build the package with `make package/luci-app-halsamrec/compile`
4. Install the generated `.ipk` package on your OpenWrt device

## Usage

After installation, navigate to:
**Main Menu → Audio Devices**

The page provides:
- **Recorder Service Section:**
  - Real-time status display (RUNNING/STOPPED with color coding)
  - Toggle button to START/STOP recorder service
  - Status messages for actions

- **ALSA Device Probe Section:**
  - Warning message when recorder is running (prevents probe)
  - Probe button (disabled when recorder is running)
  - Raw `arecord --dump-hw-params -D hw:0,0` output

## Configuration

Edit `/etc/config/halsamrec`:

config halsamrec 'main' option enabled '1' 
# Enable/disable module option device 'hw:0,0' 
# ALSA device (default: hw:0,0) option autostart '0' 
# Auto-start recorder on boot


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
