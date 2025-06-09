#!/bin/sh

# Function to safely extract maximum parameter values
get_max_param() {
    echo "$hw_params" | awk -F': ' "/$1:/ {print \$2}" | \
    sed -n 's/.*[[(]\([0-9]*\) \([0-9]*\)[])]/\2/p' | \
    head -n 1
}

# Cache `arecord -l` output with error handling
if ! arecord_list=$(arecord -l 2>/dev/null); then
    echo "Error: Failed to execute 'arecord -l'" >&2
    exit 1
fi

# Detect hardware device with validation
device=$(echo "$arecord_list" | awk '/^card/ {print $2}' | tr -d ':' | head -n 1)
if [ -z "$device" ]; then
    echo "Error: No audio capture device found" >&2
    exit 1
fi

# Get subdevice with fallback
subdevice=$(echo "$arecord_list" | grep -A 1 "card $device" | awk '/Subdevice/ {print $3}' | head -n 1)
subdevice=${subdevice:-0}  # Default to 0 if not found

# Get hardware parameters with error handling
if ! hw_params=$(arecord -D "hw:$device,$subdevice" --dump-hw-params 2>&1); then
    echo "Error: Failed to get hardware parameters for hw:$device,$subdevice" >&2
    echo "$hw_params" >&2
    exit 1
fi

# Extract parameters with proper fallbacks
channels=$(get_max_param "CHANNELS")
rate=$(get_max_param "RATE")
format=$(echo "$hw_params" | awk -F': ' '/FORMAT:/ {print $2}' | awk '{print $NF}' | head -n 1)
buffer_time=$(get_max_param "BUFFER_TIME")
buffer_size=$(get_max_param "BUFFER_SIZE")

# Set reasonable defaults if parameters couldn't be determined
channels=${channels:-2}  # Default to stereo
rate=${rate:-44100}      # Default to 44.1kHz
format=${format:-S16_LE} # Default to signed 16-bit little-endian
buffer_time=${buffer_time:-20000000}  # Default to 20ms
buffer_size=${buffer_size:-$((rate * channels * 4 * buffer_time / 1000000))}  # Calculate based on rate/channels

# Log detected parameters
cat <<EOF
Detected parameters:
DEVICE: $device,$subdevice
-- channels: $channels
-- rate: $rate
-- format: $format
-- buffer time: $buffer_time
-- buffer size: $buffer_size
EOF
