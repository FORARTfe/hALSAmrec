#!/bin/sh

MNT=/tmp/mnt
recorder=""

trap 'true' SIGHUP

sleep infinity &
dummy=$!

trap '	kill $dummy;
	[ -n "$recorder" ] && kill $recorder;
	umount -l "$MNT";
	exit'	SIGTERM

first=0

# Function to probe audio interface and get optimal parameters
probe_audio_interface() {
    # Get the first available capture device
    device=$(arecord -l | grep -m 1 'card' | sed -e 's/card \([0-9]*\).*device \([0-9]*\).*/hw:\1,\2/')
    
    if [ -z "$device" ]; then
        echo "No audio capture device found" >&2
        return 1
    fi
    
    # Get supported formats
    formats=$(arecord -D $device --dump-hw-params 2>&1 | grep -A 10 'FORMAT:' | grep -v 'FORMAT:')
    
    # Prefer S32_LE if available, otherwise use first available format
    if echo "$formats" | grep -q 'S32_LE'; then
        format='S32_LE'
    else
        format=$(echo "$formats" | head -n 1 | awk '{print $1}')
    fi
    
    # Get max channels
    channels=$(arecord -D $device --dump-hw-params 2>&1 | grep 'CHANNELS:' | awk '{print $2}')
    
    # Get max rate
    rate=$(arecord -D $device --dump-hw-params 2>&1 | grep 'RATE:' | awk '{print $2}' | sort -n | tail -1)
    
    # Get buffer time (use 20000000 as default if not available)
    buffer_time=20000000
    
    echo "$device $channels $format $rate $buffer_time"
    return 0
}

while true; do
    if [ $first -eq 0 ]; then first=1; else
        if [ -n "$recorder" ]; then waiton=$recorder;
                    else waiton=$dummy; fi
        wait $waiton
    fi
    
    # Probe for audio interface
    audio_params=$(probe_audio_interface)
    if [ $? -ne 0 ]; then
        audio_params=""
    fi
    
    disk=/dev/mmcblk0?3
    [ -e $disk ] && [ -n "$audio_params" ]
    ready=$?
    
    # PIDs can be reused, but this test is probably reliable enough
    # for our purposes:
    if [ -n "$recorder" -a ! -e /proc/$recorder ]; then
        recorder="";
        umount -l "$MNT"
    fi
    
    if [ $ready -ne 0 ]; then
        if [ -n "$recorder" ]; then
            # recording's still running but something's
            # been disconnected; try to clean up:
            # openwrt actually seems to unmount automatically,
            # but, just to be sure:
            umount -l "$MNT"
            kill -9 $recorder
            recorder=""
        fi
        continue
    fi
    
    if [ -n "$recorder" ]; then continue; fi
    
    # openwrt seems to delete mountpoints on unmount automatically,
    # so we need to recreate it here:
    mkdir -p "$MNT"
    mount -o big_writes $disk "$MNT" || continue
    
    # Extract audio parameters
    read device channels format rate buffer_time <<EOF
$audio_params
EOF
    
    # Generate filename with Unix timestamp and parameters
    timestamp=$(date +%s)
    filename="${timestamp} at ${channels}-${format}-${rate}.raw"
    
    {
        # Calculate buffer size (rate * channels * 4 bytes * 0.5 seconds as a reasonable buffer)
        buffer_size=$((rate * channels * 4 * 5 / 10))
        
        arecord --device=$device --channels=$channels --file-type=raw \
                --format=$format --rate=$rate \
                --buffer-time=$buffer_time --buffer-size=$buffer_size \
                > "${MNT}/${filename}" 2> >(ts -s >&2) &
        recorder=$!
    }
done
