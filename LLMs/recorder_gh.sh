#!/bin/sh

# Full path to arecord (modify if needed)
ARECORD="/usr/bin/arecord"
MNT=/tmp/mnt
recorder=""

trap 'true' SIGHUP

first=0

# Clean shutdown on SIGTERM
trap '
  [ -n "$recorder" ] && kill $recorder 2>/dev/null
  umount -l "$MNT" 2>/dev/null
  exit
' SIGTERM

while true; do
    if [ $first -eq 0 ]; then first=1; else
        if [ -n "$recorder" ]; then waiton=$recorder;
                                else waiton=;
        fi
        [ -n "$waiton" ] && wait $waiton
    fi

    card=$(arecord -l | grep '^card')
    disk=/dev/mmcblk0?3
    [ -e $disk ] && [ -n "$card" ]
    ready=$?

    # Handle if recorder process died
    if [ -n "$recorder" ] && ! [ -e /proc/$recorder ]; then
        recorder=""
        umount -l "$MNT" 2>/dev/null
    fi

    if [ $ready -ne 0 ]; then
        if [ -n "$recorder" ]; then
            umount -l "$MNT" 2>/dev/null
            kill -9 $recorder 2>/dev/null
            recorder=""
        fi
        sleep 2
        continue
    fi

    if [ -n "$recorder" ]; then
        sleep 2
        continue
    fi

    mkdir -p "$MNT"
    mount -o big_writes $disk "$MNT" || continue

    # Find a unique logfile and recording file name
    while true; do
        name=$(date +"%Y-%m-%d-%Hh%Mm%Ss")
        logfile="${MNT}/${name}.log"
        rawfile="${MNT}/${name}.raw"
        [ ! -e "$logfile" ] && break
        sleep 1
    done

    # --- DEVICE PROBE LOGIC: KEEPING ORIGINAL ---
    $ARECORD -D hw:0,0 --dump-hw-params > /tmp/arecord_output.txt 2>&1
    arecord_output=$(cat /tmp/arecord_output.txt)

    # Extract max channels: pick the highest number in "CHANNELS: [n m]" or "CHANNELS: n"
    max_channels=$(echo "$arecord_output" | grep "CHANNELS:" | \
        sed -n 's/.*CHANNELS: \[\?\([0-9]*\)\( \([0-9]*\)\)\?\]/\3/p' | sort -nu | tail -1)
    if [ -z "$max_channels" ]; then
        max_channels=$(echo "$arecord_output" | grep "CHANNELS:" | sed -n 's/.*CHANNELS: \([0-9]*\)/\1/p')
    fi

    # Extract bit format: pick last word after "FORMAT:" on the line, fallback to any uppercase format in line
    bitformat=$(echo "$arecord_output" | grep "^FORMAT:" | sed -n 's/.*FORMAT: \(.*\)/\1/p' | awk '{print $NF}')
    if [ -z "$bitformat" ]; then
        bitformat=$(echo "$arecord_output" | grep "^FORMAT:" | sed -n 's/.*FORMAT: \([A-Z0-9_]*\)/\1/p')
    fi

    # Helper to extract max from [min max] ranges
    extract_max_from_range() {
        echo "$1" | sed -n 's/.*[[(]\([0-9]*\) \([0-9]*\)[])]/\2/p'
    }

    buffer_time_max=$(echo "$arecord_output" | grep "BUFFER_TIME:" | while read -r line; do extract_max_from_range "$line"; done | sort -nu | tail -1)
    buffer_size_max=$(echo "$arecord_output" | grep "BUFFER_SIZE:" | while read -r line; do extract_max_from_range "$line"; done | sort -nu | tail -1)

    # Extract max rate: pick last value in "RATE: [n m]" or "RATE: n"
    max_rate=$(echo "$arecord_output" | grep "RATE:" | while read -r line; do extract_max_from_range "$line"; done | sort -nu | tail -1)
    if [ -z "$max_rate" ]; then
        max_rate=$(echo "$arecord_output" | grep "RATE:" | sed -n 's/.*RATE: \([0-9]*\)/\1/p')
    fi
    # Clamp to 48000
    [ -n "$max_rate" ] && [ "$max_rate" -gt 48000 ] && max_rate=48000

    # Logging of chosen values (for debug)
    echo "[$(date)] Starting recording: rate=$max_rate ch=$max_channels fmt=$bitformat" >> "$logfile"

    # Start recording
    $ARECORD --device="hw:0,0" --channels="$max_channels" --format="$bitformat" \
        --rate="$max_rate" --buffer-time="$buffer_time_max" \
        --buffer-size="$buffer_size_max" > "$rawfile" 2>>"$logfile" &
    recorder=$!
done
