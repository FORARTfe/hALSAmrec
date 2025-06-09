#!/bin/sh

# Cache `arecord -l` output
arecord_list=$(arecord -l 2>/dev/null)

# Detect hardware device and parameters
device=$(echo "$arecord_list" | awk '/^card/ {print $2}' | tr -d ':')
subdevice=$(echo "$arecord_list" | grep -A 1 "card $device" | awk '/Subdevice/ {print $3}' | head -n 1 || echo 0)
hw_params=$($ARECORD -D "hw:$device,$subdevice" --dump-hw-params 2>/dev/null)

# Validate hw_params output
if [ -z "$hw_params" ]; then
	echo "Failed to probe hardware parameters for hw:$device,$subdevice. Retrying..." >&2
	sleep 1
	continue
fi

# Extract parameters with fallbacks
channels=$(echo "$hw_params" | awk -F': ' '/CHANNELS:/ {print $2}' | extract_max || echo 2)
rate=$(echo "$hw_params" | awk -F': ' '/RATE:/ {print $2}' | extract_max || echo 44100)
format=$(echo "$hw_params" | awk -F': ' '/FORMAT:/ {print $2}' | awk '{print $NF}' || echo S32_LE)
buffer_time=$(echo "$hw_params" | awk -F': ' '/BUFFER_TIME:/ {print $2}' | extract_max || echo 20000000)

# Log detected parameters
echo "Detected parameters: device=hw:$device,$subdevice channels=$channels rate=$rate format=$format buffer_time=$buffer_time"
