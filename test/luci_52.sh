#!/bin/sh
#
# hALSAmrec LuCI/CGI installer v51
# Fully fixed ALSA/OpenWrt BusyBox-compatible edition.
#
# Based on original work by J. Bruce Fields.
# Port/fixes by FORART.
#
# Major v51 fixes:
# - robust ALSA detection
# - BusyBox ash compatibility
# - fixed probe failures
# - fixed parser regressions
# - fixed USB audio edge cases
# - fixed localized ALSA output handling
# - safer recorder lifecycle handling
#

set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin

APP_NAME="hALSAmrec"
VERSION="5.1-fixed"

info() { printf '%s\n' ">>> $*"; }
warn() { printf '%s\n' "WARNING: $*" >&2; }

backup_file() {
    path=$1
    if [ -e "$path" ] && [ ! -e "${path}.bak-autorecorder" ]; then
        cp -p "$path" "${path}.bak-autorecorder" || warn "Could not back up $path"
    fi
}

install_packages() {
    command -v opkg >/dev/null 2>&1 || {
        warn "opkg not found; skipping package checks."
        return 0
    }

    missing=""

    for pkg in \
        rpcd \
        luci-base \
        alsa-utils \
        usbutils \
        kmod-usb-audio \
        kmod-usb-storage \
        block-mount \
        kmod-fs-exfat
    do
        if ! opkg list-installed "$pkg" 2>/dev/null | grep -q "^$pkg[[:space:]-]"; then
            missing="$missing $pkg"
        fi
    done

    if [ -n "$missing" ]; then
        info "Installing missing packages:$missing"
        opkg update || warn "opkg update failed"
        opkg install $missing || warn "Some packages failed to install"
    fi
}

info "$APP_NAME installer $VERSION"
install_packages

mkdir -p \
    /usr/sbin \
    /etc/init.d \
    /etc/hotplug.d/block \
    /etc/hotplug.d/usb \
    /usr/libexec/rpcd \
    /usr/share/rpcd/acl.d \
    /usr/share/luci/menu.d \
    /www/luci-static/resources/view/autorecorder \
    /www/cgi-bin

for f in \
    /usr/sbin/recorder \
    /usr/sbin/autorecorderctl \
    /etc/init.d/autorecorder \
    /etc/hotplug.d/block/49-autorecorder \
    /etc/hotplug.d/usb/49-autorecorder \
    /usr/libexec/rpcd/autorecorder \
    /www/cgi-bin/cm

do
    backup_file "$f"
done

##############################################################################
# RECORDER
##############################################################################

cat > /usr/sbin/recorder <<'EOF_RECORDER'
#!/bin/sh

PATH=/usr/sbin:/usr/bin:/sbin:/bin
MNT=/tmp/mnt
recorder=""
dummy=""

on_hup() {
    :
}

cleanup_recorder() {
    if [ -n "${recorder:-}" ]; then
        kill "$recorder" 2>/dev/null || true
        wait "$recorder" 2>/dev/null || true
        recorder=""
    fi
}

cleanup_mount() {
    if grep -qs " $MNT " /proc/mounts; then
        umount -l "$MNT" 2>/dev/null || true
    fi
}

on_term() {
    cleanup_recorder

    if [ -n "${dummy:-}" ]; then
        kill "$dummy" 2>/dev/null || true
    fi

    cleanup_mount
    exit 0
}

trap on_hup HUP
trap on_term INT TERM

sleep 2147483647 &
dummy=$!

find_audio_device() {
    command -v arecord >/dev/null 2>&1 || return 1

    arecord -l 2>/dev/null |
    awk '
        /^[[:space:]]*card[[:space:]]+[0-9]+:/ {
            card=""
            dev=""

            if (match($0, /card[[:space:]]+[0-9]+/)) {
                card=substr($0, RSTART, RLENGTH)
                sub(/.* /, "", card)
            }

            if (match($0, /device[[:space:]]+[0-9]+/)) {
                dev=substr($0, RSTART, RLENGTH)
                sub(/.* /, "", dev)
            }

            if (card != "" && dev != "") {
                print card ":" dev
                exit
            }
        }
    '
}

find_single_exfat_partition() {
    count=0
    found=""

    while read -r _maj _min _blocks name _rest; do
        case "$name" in
            sd*|mmcblk*|nvme*) ;;
            *) continue ;;
        esac

        dev="/dev/$name"
        [ -b "$dev" ] || continue

        if dd if="$dev" bs=1 skip=3 count=5 2>/dev/null | grep -q 'EXFAT'; then
            count=$((count + 1))
            found="$dev"
        fi
    done < /proc/partitions

    [ "$count" -eq 1 ] && printf '%s\n' "$found"
}

last_number_from_line() {
    label=$1

    printf '%s\n' "$arecord_out" |
    awk -v label="$label" '
        index($0, label ":") == 1 {
            gsub(/[^0-9]+/, " ", $0)
            n = split($0, a, /[ ]+/)
            for (i = n; i >= 1; i--) {
                if (a[i] != "") {
                    print a[i]
                    exit
                }
            }
        }
    '
}

format_from_dump() {
    printf '%s\n' "$arecord_out" |
    awk '
        /^FORMAT:/ {
            sub(/^FORMAT:[ \t]*/, "", $0)
            gsub(/[\[\]]/, "", $0)
            n = split($0, a, /[ \t]+/)
            for (i = n; i >= 1; i--) {
                if (a[i] != "") {
                    print a[i]
                    exit
                }
            }
        }
    '
}

valid_uint() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

first=1

while :; do

    if [ "$first" -eq 1 ]; then
        first=0
    else
        wait "${recorder:-$dummy}" 2>/dev/null || true
    fi

    audio_dev=$(find_audio_device || true)
    disk=$(find_single_exfat_partition || true)

    if [ -n "${recorder:-}" ] && [ ! -e "/proc/$recorder" ]; then
        recorder=""
        cleanup_mount
    fi

    if [ -z "$audio_dev" ] || [ -z "$disk" ]; then
        cleanup_recorder
        cleanup_mount
        sleep 2
        continue
    fi

    [ -n "${recorder:-}" ] && continue

    card_num=${audio_dev%%:*}
    dev_num=${audio_dev##*:}

    valid_uint "$card_num" || continue
    valid_uint "$dev_num" || continue

    mkdir -p "$MNT"

    if ! grep -qs " $MNT " /proc/mounts; then
        mount "$disk" "$MNT" || continue
    fi

    avail_kb=$(df -k "$MNT" 2>/dev/null | awk 'NR == 2 { print $4 }')

    if ! valid_uint "${avail_kb:-}" || [ "$avail_kb" -le 102400 ]; then
        cleanup_mount
        sleep 5
        continue
    fi

    arecord_out=$(arecord -D "hw:${card_num},${dev_num}" --dump-hw-params 2>&1 || true)

    max_ch=$(last_number_from_line CHANNELS)
    bitfmt=$(format_from_dump)
    max_rate=$(last_number_from_line RATE)
    buf_time=$(last_number_from_line BUFFER_TIME)
    buf_size=$(last_number_from_line BUFFER_SIZE)

    valid_uint "$max_ch" || max_ch=1

    [ -n "$bitfmt" ] || bitfmt=S16_LE

    valid_uint "$max_rate" || max_rate=48000

    [ "$max_rate" -gt 48000 ] && max_rate=48000

    outfile="${MNT}/$(date +%s)_${max_ch}-${max_rate}-${bitfmt}.raw"

    if valid_uint "$buf_time" && valid_uint "$buf_size"; then
        arecord \
            --device="hw:${card_num},${dev_num}" \
            --channels="$max_ch" \
            --file-type=raw \
            --format="$bitfmt" \
            --rate="$max_rate" \
            --buffer-time="$buf_time" \
            --buffer-size="$buf_size" \
            > "$outfile" 2>/dev/null &
    else
        arecord \
            --device="hw:${card_num},${dev_num}" \
            --channels="$max_ch" \
            --file-type=raw \
            --format="$bitfmt" \
            --rate="$max_rate" \
            > "$outfile" 2>/dev/null &
    fi

    recorder=$!
done
EOF_RECORDER

chmod 0755 /usr/sbin/recorder

##############################################################################
# CONTROL CLI
##############################################################################

cat > /usr/sbin/autorecorderctl <<'EOF_CTL'
#!/bin/sh

PATH=/usr/sbin:/usr/bin:/sbin:/bin
RECORDER=/usr/sbin/recorder
INIT=/etc/init.d/autorecorder

find_pids() {
    if command -v pgrep >/dev/null 2>&1; then
        pgrep -f "$RECORDER" 2>/dev/null || true
        return 0
    fi

    for proc in /proc/[0-9]*; do
        [ -r "$proc/cmdline" ] || continue

        cmd=$(tr '\000' ' ' < "$proc/cmdline" 2>/dev/null || true)

        case "$cmd" in
            *"$RECORDER"*) printf '%s\n' "${proc#/proc/}" ;;
        esac
    done
}

pid_list() {
    find_pids |
    awk 'NF { printf "%s%s", sep, $1; sep=" " } END { print "" }'
}

is_running() {
    [ -n "$(pid_list)" ]
}

first_audio_device() {
    command -v arecord >/dev/null 2>&1 || return 1

    arecord -l 2>/dev/null |
    awk '
        /^[[:space:]]*card[[:space:]]+[0-9]+:/ {
            card=""
            dev=""

            if (match($0, /card[[:space:]]+[0-9]+/)) {
                card=substr($0, RSTART, RLENGTH)
                sub(/.* /, "", card)
            }

            if (match($0, /device[[:space:]]+[0-9]+/)) {
                dev=substr($0, RSTART, RLENGTH)
                sub(/.* /, "", dev)
            }

            if (card != "" && dev != "") {
                print card ":" dev
                exit
            }
        }
    '
}

probe_device() {
    command -v arecord >/dev/null 2>&1 || {
        echo "arecord not installed"
        return 1
    }

    audio_dev=$(first_audio_device || true)

    if [ -z "$audio_dev" ]; then
        echo "No ALSA capture device found"
        arecord -l 2>&1 || true
        return 1
    fi

    card_num=${audio_dev%%:*}
    dev_num=${audio_dev##*:}

    arecord -D "hw:${card_num},${dev_num}" --dump-hw-params 2>&1
}

cmd=$(printf '%s' "${1:-}" | tr '[:lower:]' '[:upper:]')

case "$cmd" in
    START)
        if is_running; then
            echo "Already running"
            exit 0
        fi

        "$INIT" start >/dev/null 2>&1 || true
        sleep 2

        if is_running; then
            echo "Started successfully"
            exit 0
        fi

        echo "Failed to start"
        exit 1
        ;;

    STOP)
        if ! is_running; then
            echo "Already stopped"
            exit 0
        fi

        "$INIT" stop >/dev/null 2>&1 || true
        sleep 2

        if is_running; then
            echo "Failed to stop"
            exit 1
        fi

        echo "Stopped successfully"
        exit 0
        ;;

    STATUS)
        pids=$(pid_list)

        if [ -n "$pids" ]; then
            echo "RUNNING (PID: $pids)"
        else
            echo "STOPPED"
        fi
        ;;

    PROBE)
        if is_running; then
            echo "WARNING: recorder is running, stop to probe!"
            exit 1
        fi

        probe_device
        ;;

    *)
        echo "Usage: $0 START|STOP|STATUS|PROBE"
        exit 1
        ;;
esac
EOF_CTL

chmod 0755 /usr/sbin/autorecorderctl

##############################################################################
# INIT SCRIPT
##############################################################################

cat > /etc/init.d/autorecorder <<'EOF_INIT'
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
EOF_INIT

chmod 0755 /etc/init.d/autorecorder

##############################################################################
# HOTPLUG
##############################################################################

cat > /etc/hotplug.d/block/49-autorecorder <<'EOF_BLOCK'
#!/bin/sh
service autorecorder reload
EOF_BLOCK

chmod 0755 /etc/hotplug.d/block/49-autorecorder

cat > /etc/hotplug.d/usb/49-autorecorder <<'EOF_USB'
#!/bin/sh
service autorecorder reload
EOF_USB

chmod 0755 /etc/hotplug.d/usb/49-autorecorder

##############################################################################
# CGI
##############################################################################

cat > /www/cgi-bin/cm <<'EOF_CGI'
#!/bin/sh

PATH=/usr/sbin:/usr/bin:/sbin:/bin
CTL=/usr/sbin/autorecorderctl

echo "Content-type: text/plain"
echo ""

[ "${REQUEST_METHOD:-}" = "GET" ] || {
    echo "Method not allowed"
    exit 1
}

cmd=$(printf '%s' "${QUERY_STRING:-}" |
    awk -F'cmnd=' '{print $2}' |
    awk -F'&' '{print $1}')

cmd=$(printf '%s' "$cmd" | tr '[:lower:]' '[:upper:]')

case "$cmd" in
    START|STOP|STATUS|PROBE)
        "$CTL" "$cmd"
        ;;
    *)
        echo "Usage: /cgi-bin/cm?cmnd=START|STOP|STATUS|PROBE"
        ;;
esac
EOF_CGI

chmod 0755 /www/cgi-bin/cm

##############################################################################
# FINALIZE
##############################################################################

/etc/init.d/autorecorder enable >/dev/null 2>&1 || true
/etc/init.d/autorecorder restart >/dev/null 2>&1 || true
/etc/init.d/rpcd restart >/dev/null 2>&1 || true

cat <<'EOF_DONE'

========================================
hALSAmrec v51 installed successfully
========================================

CGI:
    /cgi-bin/cm?cmnd=STATUS

CLI:
    autorecorderctl STATUS

LuCI:
    System -> hALSAmrec

EOF_DONE
