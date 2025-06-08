#!/bin/sh
#
# Optimized Audio Recording Script

MNT="/tmp/mnt"
ARECORD="/usr/bin/arecord"
RECORDER=""

# Cleanup function
cleanup() {
    [ -n "$RECORDER" ] && kill "$RECORDER" 2>/dev/null
    umount -l "$MNT" 2>/dev/null
    rm -rf "$MNT" 2>/dev/null
    exit
}

trap cleanup SIGTERM SIGHUP

# Function to extract max value from a range
extract_max() {
    echo "$1" | sed -n 's/.*[[(]\([0-9]*\) \([0-9]*\)[])]/\2/p' || echo ""
}

# Main loop
while true; do
    # Cache `arecord -l` output
    arecord_list=$(arecord -l 2>/dev/null)
    disk=$(ls /dev/sd?1 2>/dev/null)

    # Skip if no card or disk is available
    if [ -z "$arecord_list" ] || [ -z "$disk" ]; then
        [ -n "$RECORDER" ] && cleanup
        sleep 1
        continue
    fi

    # Skip if recorder is running
    [ -n "$RECORDER" ] && sleep 1 && continue

    # Mount disk only once per loop
    mkdir -p "$MNT"
    if ! mount "$disk" "$MNT" 2>/dev/null; then
        echo "Failed to mount $disk. Retrying..." >&2
        sleep 1
        continue
    fi

    # Generate unique filename
    name=$(date +"%Y-%m-%d-%Hh%Mm%Ss")
    rawfile="${MNT}/${name}.raw"
    logfile="${MNT}/${name}.log"

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

    # Start recording
    $ARECORD --device="hw:$device,$subdevice" --channels="$channels" --file-type=raw \
             --format="$format" --rate="$rate" --buffer-time="$buffer_time" \
             > "$rawfile" 2> >(ts -s > "$logfile") &
    RECORDER=$!

    # Wait for recorder to finish
    wait "$RECORDER"
done
