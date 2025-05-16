Here are some resources that could be considered in the future for more enhancements:

Repos:
- https://github.com/knutopia/Modlogr
- https://github.com/anselbrandt/pi-recorder
- https://github.com/maniac0r/rpi-usb-audio-tweaks

Similar projects:
- https://dikant.de/2018/02/28/raspberry-xr18-recorder

Hotplug:
- https://bbs.archlinux.org/viewtopic.php?id=173317

FS:
- https://darwinsdata.com/should-i-use-ntfs-or-ext4-on-ubuntu/

Raspberry:
- https://www.researchgate.net/profile/Roy-Longbottom/publication/327467963_Raspberry_Pi_3B_32_bit_and_64_bit_Benchmarks_and_Stress_Tests/links/5b91053692851c6b7ec939b3/Raspberry-Pi-3B-32-bit-and-64-bit-Benchmarks-and-Stress-Tests.pdf

ALSA/SOX/FFMPEG:
- https://explainshell.com/explain/1/arecord
- https://linux.die.net/man/1/rec
- https://trac.ffmpeg.org/wiki/Capture/ALSA

Moode:
- https://www.bitlab.nl/page_id=1103

SD cards:
- [RPi SD cards](https://elinux.org/RPi_SD_cards)
- [Demystifying 128GB SD Cards on the Raspberry Pi 4](https://thelinuxcode.com/use-128gb-sd-card-raspberry-pi/)
- [Raspberry Pi microSD card performance comparison](https://www.jeffgeerling.com/blog/2019/raspberry-pi-microsd-card-performance-comparison-2019)

Android remote control apps:
- [Home App for Android](https://github.com/Domi04151309/HomeApp#readme)

Copilot-geneted interface probing:
```
#!/bin/bash

# Function to check if required commands are available
function check_commands {
  for cmd in arecord; do
    if ! command -v $cmd &> /dev/null; then
      echo "$cmd could not be found, please install it first."
      exit 1
    fi
  done
}

# Function to list available formats
function list_formats {
  echo "Listing available formats for device hw:$CARD,$DEVICE..."
  FORMATS=("S16_LE" "S24_LE" "S32_LE")
  available_formats=()
  for format in "${FORMATS[@]}"; do
    if arecord -D hw:$CARD,$DEVICE -f $format -d 1 /dev/null &> /dev/null; then
      available_formats+=("$format")
    fi
  done
  echo "${available_formats[@]}"
}

# Function to list available sample rates
function list_sample_rates {
  echo "Listing available sample rates for device hw:$CARD,$DEVICE..."
  SAMPLERATES=(44100 48000 96000 192000)
  available_samplerates=()
  for rate in "${SAMPLERATES[@]}"; do
    if arecord -D hw:$CARD,$DEVICE -r $rate -d 1 /dev/null &> /dev/null; then
      available_samplerates+=("$rate")
    fi
  done
  echo "${available_samplerates[@]}"
}

# Function to list available channels
function list_channels {
  echo "Listing available channel configurations for device hw:$CARD,$DEVICE..."
  CHANNELS=(1 2 4 6 8)
  available_channels=()
  for channels in "${CHANNELS[@]}"; do
    if arecord -D hw:$CARD,$DEVICE -c $channels -d 1 /dev/null &> /dev/null; then
      available_channels+=("$channels")
    fi
  done
  echo "${available_channels[@]}"
}

# Function to prompt user for selection
function prompt_user_selection {
  local prompt=$1
  shift
  local options=("$@")
  PS3="$prompt"
  select opt in "${options[@]}"; do
    if [[ " ${options[*]} " == *" $opt "* ]]; then
      echo "$opt"
      return
    else
      echo "Invalid option. Please try again."
    fi
  done
}

# Check if required commands are available
check_commands

# Find the USB audio device (assuming it's the only USB audio device connected)
DEVICE=$(arecord -l | grep -i 'usb' | awk '{print $2,$3}' | sed 's/://')

if [ -z "$DEVICE" ]; then
  echo "No USB audio device found."
  exit 1
fi

CARD=$(echo $DEVICE | awk '{print $1}')
DEVICE=$(echo $DEVICE | awk '{print $2}')

echo "Using USB audio device: hw:$CARD,$DEVICE"

# List available formats, sample rates, and channels
AVAILABLE_FORMATS=($(list_formats))
AVAILABLE_SAMPLERATES=($(list_sample_rates))
AVAILABLE_CHANNELS=($(list_channels))

# Prompt user for preferred format
echo "Available formats: ${AVAILABLE_FORMATS[*]}"
PREFERRED_FORMAT=$(prompt_user_selection "Select your preferred format: " "${AVAILABLE_FORMATS[@]}")

# Prompt user for preferred sample rate
echo "Available sample rates: ${AVAILABLE_SAMPLERATES[*]}"
PREFERRED_SAMPLERATE=$(prompt_user_selection "Select your preferred sample rate: " "${AVAILABLE_SAMPLERATES[@]}")

# Prompt user for preferred channels
echo "Available channels: ${AVAILABLE_CHANNELS[*]}"
PREFERRED_CHANNELS=$(prompt_user_selection "Select your preferred channels: " "${AVAILABLE_CHANNELS[@]}")

# Display selected options
echo "You selected:"
echo "Format: $PREFERRED_FORMAT"
echo "Sample Rate: $PREFERRED_SAMPLERATE"
echo "Channels: $PREFERRED_CHANNELS"
```
