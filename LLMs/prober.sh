#!/bin/sh

# Cache `arecord -l` output
arecord_list=$(arecord -l 2>/dev/null)

# Detect hardware device and parameters
device=$(echo "$arecord_list" | awk '/^card/ {print $2}' | tr -d ':')
subdevice=$(echo "$arecord_list" | grep -A 1 "card $device" | awk '/Subdevice/ {print $3}' | head -n 1 || echo 0)
hw_params=$(arecord -D "hw:$device,$subdevice" --dump-hw-params 2>/dev/null)

# Extract max values directly using sed
channels=$(echo "$hw_params" | awk -F': ' '/CHANNELS:/ {print $2}' | sed -n 's/.*[[(]\([0-9]*\) \([0-9]*\)[])]/\2/p')
rate=$(echo "$hw_params" | awk -F': ' '/RATE:/ {print $2}' | sed -n 's/.*[[(]\([0-9]*\) \([0-9]*\)[])]/\2/p')
format=$(echo "$hw_params" | awk -F': ' '/FORMAT:/ {print $2}' | awk '{print $NF}')
buffer_time=$(echo "$hw_params" | awk -F': ' '/BUFFER_TIME:/ {print $2}' | sed -n 's/.*[[(]\([0-9]*\) \([0-9]*\)[])]/\2/p')
buffer_size=$(echo "$hw_params" | awk -F': ' '/BUFFER_SIZE:/ {print $2}' | sed -n 's/.*[[(]\([0-9]*\) \([0-9]*\)[])]/\2/p')

# Log detected parameters
echo "Detected parameters:\nDEVICE: $device,$subdevice\n-- channels: $channels\n-- rate:$rate\n-- format:$format\n-- buffer time:$buffer_time\n-- buffer size:$buffer_size"
