#!/bin/sh
#
# hALSAmrec installer v2 (All-in-One Heredoc Edition)
# by FORART (https://forart.it/), 2025-26
# GPL v3 — see <https://www.gnu.org/licenses/>

set -e

TMPDIR="/tmp/hALSAmrec-install.$$"
PACKAGES="alsa-utils kmod-usb-storage block-mount kmod-usb3 kmod-usb-audio usbutils kmod-fs-exfat"

echo "[*] Updating package lists..."
opkg update

echo "[*] Installing required packages..."
opkg install $PACKAGES

echo "[*] Unpacking embedded component scripts..."
mkdir -p "$TMPDIR"

# ---------------------------------------------------------------------------
# Component: recorder
# ---------------------------------------------------------------------------
cat << 'EOF' > "$TMPDIR/recorder"
#!/bin/sh
#
# Original script by J. Bruce Fields, 2024
# This version (v3) by FORART (https://forart.it/), 2025-26
# GPL v3 — see <https://www.gnu.org/licenses/>

MNT=/tmp/mnt
recorder=""

trap 'true' SIGHUP

sleep infinity &
dummy=$!
trap 'kill $dummy
      [ -n "$recorder" ] && kill $recorder
      umount -l "$MNT"
      exit' SIGTERM

first=0

while true;
do
    if [ $first -eq 0 ];
    then
        first=1
    else
        # Use recorder PID if active, otherwise wait on the sentinel sleep
        wait ${recorder:-$dummy}
    fi

    # Single arecord call: result reused for readiness check and number parsing
    card_line=$(arecord -l 2>/dev/null | grep '^card' | head -n 1)

    # Detect the single exFAT partition on the system
    disk="" exfat_count=0
    while read -r _maj _min _blk name;
    do
        case "$name" in sd*|mmcblk*|nvme*)
            dev="/dev/$name"
            [ -b "$dev" ] ||
            continue
            if dd if="$dev" bs=1 skip=3 count=5 2>/dev/null |
            grep -q "EXFAT"; then
                exfat_count=$((exfat_count + 1))
                disk="$dev"
            fi
        esac
    done < /proc/partitions
    [ "$exfat_count" -ne 1 ] && disk=""

    # Stale PID check: clean up if recorder exited on its own
    if [ -n "$recorder" ] && [ ! -e "/proc/$recorder" ]; then
        recorder=""
        umount -l "$MNT"
    fi

    # Not ready: disk or audio card missing
    if [ -z "$disk" ] || [ -z "$card_line" ]; then
        if [ -n "$recorder" ];
        then
            umount -l "$MNT"
            kill -9 $recorder
            recorder=""
        fi
        continue
    fi

    [ -n "$recorder" ] && continue

    mkdir -p "$MNT"
    mount "$disk" "$MNT" ||
    continue

    # Require at least 100 MB free before starting a new recording
    set -- $(df -k "$MNT" | tail -n 1)
    if [ $(($4 / 1024)) -le 100 ];
    then
        umount -l "$MNT"
        sleep 5
        continue
    fi

    # Parse card/device numbers from the already-captured arecord -l output
    card_num=$(printf '%s\n' "$card_line" | sed 's/^card \([0-9]*\):.*/\1/')
    dev_num=$( printf '%s\n' "$card_line" | sed 's/.*device \([0-9]*\):.*/\1/')

    arecord_out=$(arecord -D "hw:${card_num},${dev_num}" --dump-hw-params 2>&1)

    # Max channels: upper bound of range [min max], fallback to single value
    max_ch=$(printf '%s\n' "$arecord_out" | sed -n 's/^CHANNELS:.*\[\([0-9]*\) \([0-9]*\)\].*/\2/p')
    [ -z "$max_ch" ] && \
        max_ch=$(printf '%s\n' "$arecord_out" | sed -n 's/^CHANNELS:[[:space:]]*\[*\([0-9][0-9]*\).*/\1/p')

    # Format: last listed format token — ${var##* } replaces awk '{print $NF}'
    fmt_raw=$(printf '%s\n' "$arecord_out" | sed -n 's/^FORMAT:[[:space:]]*//p' | head -n 1)
    bitfmt="${fmt_raw##* }"

    # Max sample rate: upper bound of range, capped at 48000
    max_rate=$(printf '%s\n' "$arecord_out" |
    sed -n 's/^RATE:.*[\[(]\([0-9]*\) \([0-9]*\)[])].*/\2/p')
    [ -z "$max_rate" ] && \
        max_rate=$(printf '%s\n' "$arecord_out" | sed -n 's/^RATE:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
    [ "$max_rate" -gt 48000 ] && max_rate=48000

    # Buffer parameters
    buf_time=$(printf '%s\n' "$arecord_out" | sed -n 's/^BUFFER_TIME:.*[\[(]\([0-9]*\) \([0-9]*\)[])].*/\2/p')
    buf_size=$(printf '%s\n' "$arecord_out" | sed -n 's/^BUFFER_SIZE:.*[\[(]\([0-9]*\) \([0-9]*\)[])].*/\2/p')

    arecord --device="hw:${card_num},${dev_num}" \
        --channels="$max_ch"   \
        --file-type=raw        \
        --format="$bitfmt"     \
        --rate="$max_rate"     \
        --buffer-time="$buf_time" \
        --buffer-size="$buf_size" \
        > "${MNT}/$(date +%s)_${max_ch}-${max_rate}-${bitfmt}.raw" 2>/dev/null &

    recorder=$!
done
EOF

# ---------------------------------------------------------------------------
# Component: initscript
# ---------------------------------------------------------------------------
cat << 'EOF' > "$TMPDIR/initscript"
#!/bin/sh /etc/rc.common

START=99
STOP=1
USE_PROCD=1
PROG=/usr/sbin/recorder

start_service() {
    procd_open_instance
    procd_set_param command  "$PROG"
    procd_set_param stdout   1
    procd_set_param stderr   1
    procd_set_param reload_signal SIGHUP
    procd_close_instance
}

reload_service() {
    procd_send_signal autorecorder  # sends SIGHUP, wakes wait() in recorder loop
}
EOF

# ---------------------------------------------------------------------------
# Component: hotplug
# ---------------------------------------------------------------------------
cat << 'EOF' > "$TMPDIR/hotplug"
#!/bin/sh
service autorecorder reload
EOF

# ---------------------------------------------------------------------------
# Component: controlweb_cgi
# ---------------------------------------------------------------------------
cat << 'EOF' > "$TMPDIR/controlweb_cgi"
#!/bin/sh
#
# Simple webcontrol CGI script for hALSAmrec v2
# by FORART (https://forart.it/), 2025-26
# GPL v3 — see <https://www.gnu.org/licenses/>

RECORDER=/usr/sbin/recorder
INIT=/etc/init.d/autorecorder

echo "Content-type: text/plain"
echo ""

[ "$REQUEST_METHOD" = "GET" ] ||
{ echo "Error: Method not allowed"; exit 1; }
[ -n "$QUERY_STRING" ] || { echo "Usage: /cgi-bin/cm?cmnd=START|STOP|STATUS|PROBE"; exit 0;
}

# Pure shell QUERY_STRING parsing — no sed subprocess needed
tmp="${QUERY_STRING##*cmnd=}"
CMND="${tmp%%&*}"

is_running() { pgrep -f "$RECORDER" >/dev/null 2>&1;
}

case "$CMND" in
    START)
        if is_running;
        then
            echo "Already running"
        else
            $INIT start >/dev/null 2>&1;
            sleep 2
            is_running && echo "Started successfully" ||
            echo "Failed to start"
        fi
        ;;
    STOP)
        if ! is_running;
        then
            echo "Already stopped"
        else
            $INIT stop >/dev/null 2>&1;
            sleep 2
            is_running && echo "Failed to stop" ||
            echo "Stopped successfully"
        fi
        ;;
    STATUS)
        if is_running;
        then
            echo "RUNNING (PID: $(pgrep -f "$RECORDER"))"
        else
            echo "STOPPED"
        fi
        ;;
    PROBE)
        if is_running;
        then
            echo "WARNING: recorder is running, stop to probe!"
        else
            card_line=$(arecord -l 2>/dev/null | grep '^card' | head -n 1)
            card_num=$(printf '%s\n' "$card_line" | sed 's/^card \([0-9]*\):.*/\1/')
            dev_num=$(printf '%s\n' "$card_line" | sed 's/.*device \([0-9]*\):.*/\1/')
            arecord -D "hw:${card_num},${dev_num}" --dump-hw-params 2>&1
        fi
        ;;
    *)
        printf 'Unknown command: %s\nValid commands: START, STOP, STATUS, PROBE\n' "$CMND"
        ;;
esac
EOF

# ---------------------------------------------------------------------------
# Install scripts
# ---------------------------------------------------------------------------
echo "[*] Installing scripts..."
cd "$TMPDIR"

cp recorder           /usr/sbin/recorder           && chmod 755 /usr/sbin/recorder
cp initscript         /etc/init.d/autorecorder      && chmod 755 /etc/init.d/autorecorder

mkdir -p /etc/hotplug.d/block /etc/hotplug.d/usb
cp hotplug /etc/hotplug.d/block/autorecorder        && chmod 644 /etc/hotplug.d/block/autorecorder
cp hotplug /etc/hotplug.d/usb/autorecorder          && chmod 644 /etc/hotplug.d/usb/autorecorder

echo "[*] Enabling service..."
/etc/init.d/autorecorder enable

echo "[*] Setting up CGI web interface..."
mkdir -p /www/cgi-bin
cp controlweb_cgi /www/cgi-bin/cm                   && chmod 755 /www/cgi-bin/cm

LAN_IP=$(uci get network.lan.ipaddr 2>/dev/null || echo '<your-ip>')
echo "[*] Web interface ready. Available commands:"
for cmd in START STOP STATUS PROBE; do
    echo "- http://${LAN_IP}/cgi-bin/cm?cmnd=${cmd}"
done

echo "[*] Cleaning up..."
cd /; rm -rf "$TMPDIR"
echo "[*] Installation complete!"

echo ""
printf "A reboot is recommended. Reboot device now? [y/N]: "
read answer
case "$answer" in
    [yY]*) echo "Rebooting..."; reboot ;;
    *)     echo "Please reboot manually when ready." ;;
esac
