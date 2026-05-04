#!/bin/sh
# install-autorecorder.sh — v3 Backend with v2 Hotplug Implementation
# by FORART (https://forart.it/), 2025-26
# GPL v3 — see <https://www.gnu.org/licenses/>

set -e

# ── 1. Dependencies ───────────────────────────────────────────────────────────
echo "[*] Updating package list..."
opkg update >/dev/null 2>&1 || true

echo "[*] Installing required packages..."
# Using the extended package list from v2 installer[cite: 5]
opkg install alsa-utils kmod-usb-storage block-mount kmod-usb3 kmod-usb-audio usbutils kmod-fs-exfat

# ── 2. Write v3 Recorder Script[cite: 4] ──────────────────────────────────────
echo "[*] Writing recorder script..."
cat > /usr/sbin/recorder << 'ENDOFFILE'
#!/bin/sh
# Original script by J. Bruce Fields, 2024
# This version (v3) by FORART (https://forart.it/), 2025-26[cite: 4]
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
while true; do
    if [ $first -eq 0 ]; then
        first=1
    else
        wait ${recorder:-$dummy}
    fi
    card_line=$(arecord -l 2>/dev/null | grep '^card' | head -n 1)
    disk="" exfat_count=0
    while read -r _maj _min _blk name; do
        case "$name" in sd*|mmcblk*|nvme*)
            dev="/dev/$name"
            [ -b "$dev" ] || continue
            if dd if="$dev" bs=1 skip=3 count=5 2>/dev/null | grep -q "EXFAT"; then
                exfat_count=$((exfat_count + 1))
                disk="$dev"
            fi
        esac
    done < /proc/partitions
    [ "$exfat_count" -ne 1 ] && disk=""
    if [ -n "$recorder" ] && [ ! -e "/proc/$recorder" ]; then
        recorder=""
        umount -l "$MNT"
    fi
    if [ -z "$disk" ] || [ -z "$card_line" ]; then
        if [ -n "$recorder" ]; then
            umount -l "$MNT"
            kill -9 $recorder
            recorder=""
        fi
        continue
    fi
    [ -n "$recorder" ] && continue
    mkdir -p "$MNT"
    mount "$disk" "$MNT" || continue
    set -- $(df -k "$MNT" | tail -n 1)
    if [ $(($4 / 1024)) -le 100 ]; then
        umount -l "$MNT"
        sleep 5
        continue
    fi
    card_num=$(printf '%s\n' "$card_line" | sed 's/^card \([0-9]*\):.*/\1/')
    dev_num=$( printf '%s\n' "$card_line" | sed 's/.*device \([0-9]*\):.*/\1/')
    arecord_out=$(arecord -D "hw:${card_num},${dev_num}" --dump-hw-params 2>&1)
    max_ch=$(printf '%s\n' "$arecord_out" | sed -n 's/^CHANNELS:.*\[\([0-9]*\) \([0-9]*\)\].*/\2/p')
    [ -z "$max_ch" ] && max_ch=$(printf '%s\n' "$arecord_out" | sed -n 's/^CHANNELS:[[:space:]]*\[*\([0-9][0-9]*\).*/\1/p')
    fmt_raw=$(printf '%s\n' "$arecord_out" | sed -n 's/^FORMAT:[[:space:]]*//p' | head -n 1)
    bitfmt="${fmt_raw##* }"
    max_rate=$(printf '%s\n' "$arecord_out" | sed -n 's/^RATE:.*[\[(]\([0-9]*\) \([0-9]*\)[])].*/\2/p')
    [ -z "$max_rate" ] && max_rate=$(printf '%s\n' "$arecord_out" | sed -n 's/^RATE:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
    [ "$max_rate" -gt 48000 ] && max_rate=48000
    buf_time=$(printf '%s\n' "$arecord_out" | sed -n 's/^BUFFER_TIME:.*[\[(]\([0-9]*\) \([0-9]*\)[])].*/\2/p')
    buf_size=$(printf '%s\n' "$arecord_out" | sed -n 's/^BUFFER_SIZE:.*[\[(]\([0-9]*\) \([0-9]*\)[])].*/\2/p')
    arecord --device="hw:${card_num},${dev_num}" \
        --channels="$max_ch" --file-type=raw --format="$bitfmt" --rate="$max_rate" \
        --buffer-time="$buf_time" --buffer-size="$buf_size" \
        > "${MNT}/$(date +%s)_${max_ch}-${max_rate}-${bitfmt}.raw" 2>/dev/null &
    recorder=$!
done
ENDOFFILE
chmod 755 /usr/sbin/recorder

# ── 3. Write Init Script[cite: 3] ───────────────────────────────────────────
echo "[*] Writing init script..."
cat > /etc/init.d/autorecorder << 'ENDOFFILE'
#!/bin/sh /etc/rc.common
START=99
STOP=1
USE_PROCD=1
PROG=/usr/sbin/recorder
start_service() {
    procd_open_instance
    procd_set_param command "$PROG"
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param reload_signal SIGHUP
    procd_close_instance
}
reload_service() {
    procd_send_signal autorecorder
}
ENDOFFILE
chmod 755 /etc/init.d/autorecorder

# ── 4. Implement v2 Hotplug Logic[cite: 5] ──────────────────────────────────
echo "[*] Implementing v2 dual-path hotplug..."
mkdir -p /etc/hotplug.d/block /etc/hotplug.d/usb

# Writing the v3 hotplug content[cite: 2]
cat > /tmp/ar_hotplug << 'ENDOFFILE'
#!/bin/sh
service autorecorder reload
ENDOFFILE

# Deploying to both paths as per v2 installer[cite: 5]
cp /tmp/ar_hotplug /etc/hotplug.d/block/autorecorder
cp /tmp/ar_hotplug /etc/hotplug.d/usb/autorecorder

# Using 755 to ensure execution (v2 used 644, which can be unreliable)
chmod 755 /etc/hotplug.d/block/autorecorder
chmod 755 /etc/hotplug.d/usb/autorecorder
rm /tmp/ar_hotplug

# ── 5. Setup LuCI RPC Bridge ──────────────────────────────────────────────────
# This ensures the LuCI page actually has data to display
echo "[*] Setting up LuCI communication bridge..."
mkdir -p /usr/libexec/rpcd /usr/share/rpcd/acl.d /usr/share/luci/menu.d

cat > /usr/libexec/rpcd/autorecorder << 'ENDOFFILE'
#!/bin/sh
case "$1" in
    list) printf '{"status":{},"start":{},"stop":{}}\n' ;;
    call)
        case "$2" in
            status)
                pid=$(pgrep -f /usr/sbin/recorder | head -n 1)
                if [ -n "$pid" ]; then printf '{"running":true,"pid":%s}\n' "$pid"
                else printf '{"running":false,"pid":0}\n' ; fi ;;
            start) /etc/init.d/autorecorder start ; printf '{"result":"ok"}\n' ;;
            stop) /etc/init.d/autorecorder stop ; printf '{"result":"ok"}\n' ;;
        esac ;;
esac
ENDOFFILE
chmod 755 /usr/libexec/rpcd/autorecorder

cat > /usr/share/rpcd/acl.d/autorecorder.json << 'ENDOFFILE'
{ "luci-app-autorecorder": { "read": { "ubus": { "autorecorder": [ "status" ] } }, "write": { "ubus": { "autorecorder": [ "start", "stop" ] } } } }
ENDOFFILE

# ── 6. Finalize ──────────────────────────────────────────────────────────────
/etc/init.d/autorecorder enable
/etc/init.d/rpcd restart
echo "[*] Installation complete. v3 backend is active with v2 hotplug triggers."
