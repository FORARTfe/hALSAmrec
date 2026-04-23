# HALSAmRec Audio Devices LuCI Interface

LuCI web interface for:
- checking recorder service status
- starting and stopping the recorder service
- probing ALSA hardware parameters for `hw:0,0`

## Features

- recorder service start/stop toggle
- real-time status refresh every 3 seconds
- probe button disabled while recorder is running
- raw `arecord --dump-hw-params -D hw:0,0` output

## Installation

1. Copy `luci-app-halsamrec` into the OpenWrt build tree under `package/`
2. Enable it in `make menuconfig`
3. Build with `make package/luci-app-halsamrec/compile`
4. Install the generated `.ipk` on the target device

## Menu path

`Admin -> Audio Devices`

## Notes

The package currently ships an example UCI config file and a passive init script. The LuCI page itself does not depend on that init script to serve the UI.
