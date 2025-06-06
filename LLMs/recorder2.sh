#!/bin/sh

# Percorso completo di arecord (modifica se necessario)
ARECORD="/usr/bin/arecord"

MNT=/tmp/mnt
recorder=""

trap 'true' SIGHUP

sleep infinity &
dummy=$!

trap '  kill $dummy;
        [ -n "$recorder" ] && kill $recorder;
        umount -l "$MNT";
        exit'   SIGTERM

first=0

while true; do
        if [ $first -eq 0 ]; then first=1; else
                if [ -n "$recorder" ]; then waiton=$recorder;
                                        else waiton=$dummy; fi
                wait $waiton
        fi
        card=$( arecord -l|grep '^card' )
        disk=/dev/mmcblk0?3
        [ -e $disk ] && [ -n "$card" ]
        ready=$?
        if [ -n "$recorder" -a ! -e /proc/$recorder ]; then
                recorder="";
                umount -l "$MNT"
        fi
        if [ $ready -ne 0 ]; then
                if [ -n "$recorder" ]; then
                        umount -l "$MNT"
                        kill -9 $recorder
                        recorder=""
                fi
                continue
        fi
        if [ -n "$recorder" ]; then continue; fi
        mkdir -p "$MNT"
        mount -o big_writes $disk "$MNT" || continue
        while true; do
                name=$(date +"%Y-%m-%d-%Hh%Mm%Ss")
                logfile="/${MNT}/${name}.log"
                if [ ! -e "$logfile" ]; then break; fi
                sleep 1
        done
        
        # Sposta il probing qui, prima del comando di registrazione
        $ARECORD -D hw:0,0 --dump-hw-params > /tmp/arecord_output.txt 2>&1
        arecord_output=$(cat /tmp/arecord_output.txt)
        
        max_channels=$(echo "$arecord_output" | grep "CHANNELS:" | sed -n 's/.*CHANNELS: \[\?\([0-9]*\)\( \([0-9]*\)\)\?\]/\3/p')
        if [ -z "$max_channels" ]; then
            max_channels=$(echo "$arecord_output" | grep "CHANNELS:" | sed -n 's/.*CHANNELS: \([0-9]*\)/\1/p')
        fi

        bitformat=$(echo "$arecord_output" | grep "^FORMAT:" | sed -n 's/.*FORMAT: \(.*\)/\1/p' | awk '{print $NF}')
        if [ -z "$bitformat" ]; then
            bitformat=$(echo "$arecord_output" | grep "^FORMAT:" | sed -n 's/.*FORMAT: \([A-Z0-9_]*\)/\1/p')
        fi

        extract_max_from_range() {
            echo "$1" | sed -n 's/.*[[(]\([0-9]*\) \([0-9]*\)[])]/\2/p'
        }

        buffer_time_max=$(echo "$arecord_output" | grep "BUFFER_TIME:" | while read -r line; do extract_max_from_range "$line"; done)
        buffer_size_max=$(echo "$arecord_output" | grep "BUFFER_SIZE:" | while read -r line; do extract_max_from_range "$line"; done)

        max_rate=$(echo "$arecord_output" | grep "RATE:" | while read -r line; do extract_max_from_range "$line"; done)
        if [ -z "$max_rate" ]; then
            max_rate=$(echo "$arecord_output" | grep "RATE:" | sed -n 's/.*RATE: \([0-9]*\)/\1/p')
        fi

        if [ "$max_rate" -gt 48000 ]; then
            max_rate=48000
        fi

        {
                $ARECORD --device="hw:0,0" --channels="$max_channels" --format="$bitformat" \
                         --rate="$max_rate" --buffer-time="$buffer_time_max" \
                         --buffer-size="$buffer_size_max" > "${MNT}/${name}.raw" 2> >(ts -s >&2) &
                recorder=$!
        }
done
