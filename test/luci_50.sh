#!/bin/sh
#
# hALSAmrec LuCI/CGI installer
# Installs the original CGI-version recording stack and adds a LuCI UI.
# Compatible with OpenWrt 21.02+ using /bin/sh.
#

set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin

APP_NAME="hALSAmrec"
VERSION="5.1-luci-cgi-compatible"

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
    for pkg in rpcd luci-base alsa-utils kmod-fs-exfat; do
        if ! opkg list-installed "$pkg" 2>/dev/null | grep -q "^$pkg[[:space:]-]"; then
            missing="$missing $pkg"
        fi
    done

    if [ -n "$missing" ]; then
        info "Installing missing packages:$missing"
        opkg update || warn "opkg update failed; trying installation anyway."
        opkg install $missing || warn "Some packages could not be installed: $missing"
    fi
}

info "$APP_NAME installer $VERSION"
info "Checking packages..."
install_packages

info "Creating directories..."
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
    /www/cgi-bin/cm \
    /www/luci-static/resources/view/autorecorder/main.js \
    /usr/share/luci/menu.d/autorecorder.json \
    /usr/share/rpcd/acl.d/autorecorder.json; do
    backup_file "$f"
done

# ---------------------------------------------------------
# 1. Recorder daemon
# ---------------------------------------------------------
info "Installing recorder daemon..."
cat > /usr/sbin/recorder <<'EOF_RECORDER'
#!/bin/sh
#
# hALSAmrec recorder daemon
# Original script by J. Bruce Fields, 2024
# This LuCI/CGI-compatible version by FORART, 2025-26, with OpenWrt-safe fixes.
# GPL v3 — see <https://www.gnu.org/licenses/>

PATH=/usr/sbin:/usr/bin:/sbin:/bin
MNT=/tmp/mnt
recorder=""
dummy=""

on_hup() {
    # procd reload/hotplug sends SIGHUP. The trap only wakes wait().
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
    [ -n "${dummy:-}" ] && kill "$dummy" 2>/dev/null || true
    cleanup_mount
    exit 0
}

trap on_hup HUP
trap on_term INT TERM

# BusyBox sleep does not reliably support "infinity" on all OpenWrt builds.
sleep 2147483647 &
dummy=$!

find_audio_line() {
    arecord -l 2>/dev/null | grep '^card ' | head -n 1
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

        # FIX: use plain substring match — dd outputs exactly 5 raw bytes
        # ("EXFAT") with no trailing newline, so the '^EXFAT$' anchored
        # pattern is unreliable with BusyBox grep on some OpenWrt builds.
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
                for (i = n; i >= 1; i--) if (a[i] != "") { print a[i]; exit }
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
                for (i = n; i >= 1; i--) if (a[i] != "") { print a[i]; exit }
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

    card_line=$(find_audio_line || true)
    disk=$(find_single_exfat_partition || true)

    # Clean up stale arecord PID if it exited on its own.
    if [ -n "${recorder:-}" ] && [ ! -e "/proc/$recorder" ]; then
        recorder=""
        cleanup_mount
    fi

    # Not ready: disk or audio card missing.
    if [ -z "$disk" ] || [ -z "$card_line" ]; then
        cleanup_recorder
        cleanup_mount
        continue
    fi

    # Recorder is already active and hardware/storage are still visible.
    [ -n "${recorder:-}" ] && continue

    mkdir -p "$MNT"
    if ! grep -qs " $MNT " /proc/mounts; then
        mount "$disk" "$MNT" || continue
    fi

    # Require at least 100 MB free before starting a new recording.
    avail_kb=$(df -k "$MNT" 2>/dev/null | awk 'NR == 2 { print $4 }')
    if ! valid_uint "${avail_kb:-}" || [ "$avail_kb" -le 102400 ]; then
        cleanup_mount
        sleep 5
        continue
    fi

    card_num=${card_line#card }
    card_num=${card_num%%:*}
    dev_num=${card_line##*device }
    dev_num=${dev_num%%:*}

    if ! valid_uint "$card_num" || ! valid_uint "$dev_num"; then
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
        arecord --device="hw:${card_num},${dev_num}" \
            --channels="$max_ch" \
            --file-type=raw \
            --format="$bitfmt" \
            --rate="$max_rate" \
            --buffer-time="$buf_time" \
            --buffer-size="$buf_size" \
            > "$outfile" 2>/dev/null &
    else
        arecord --device="hw:${card_num},${dev_num}" \
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

# ---------------------------------------------------------
# 2. Shared control CLI used by CGI and RPCD.
# ---------------------------------------------------------
info "Installing control CLI..."
cat > /usr/sbin/autorecorderctl <<'EOF_CTL'
#!/bin/sh
# hALSAmrec control helper: START, STOP, STATUS, PROBE.

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
    find_pids | awk 'NF { printf "%s%s", sep, $1; sep=" " } END { print "" }'
}

is_running() {
    [ -n "$(pid_list)" ]
}

first_audio_device() {
    arecord -l 2>/dev/null | grep '^card ' | head -n 1
}

probe_device() {
    card_line=$(first_audio_device || true)
    if [ -z "$card_line" ]; then
        echo "No ALSA capture device found"
        return 1
    fi

    card_num=${card_line#card }
    card_num=${card_num%%:*}
    dev_num=${card_line##*device }
    dev_num=${dev_num%%:*}

    # FIX: validate each number independently so that empty values (which
    # would produce "hw:,N" or "hw:N,") are caught.  The previous combined
    # pattern  *[!0-9:]*  accepted strings like ":0" or "0:" because colon
    # is explicitly allowed, leaving card_num or dev_num silently empty.
    case "$card_num" in
        ''|*[!0-9]*) echo "Could not parse card number from: $card_line"; return 1 ;;
    esac
    case "$dev_num" in
        ''|*[!0-9]*) echo "Could not parse device number from: $card_line"; return 1 ;;
    esac

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
            exit 0
        fi
        echo "STOPPED"
        exit 0
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

# ---------------------------------------------------------
# 3. Init script
# ---------------------------------------------------------
info "Installing init script..."
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
    # Sends SIGHUP; the recorder loop wakes and re-checks audio/storage state.
    procd_send_signal autorecorder
}
EOF_INIT
chmod 0755 /etc/init.d/autorecorder

# ---------------------------------------------------------
# 4. Hotplug handlers
# ---------------------------------------------------------
info "Installing hotplug handlers..."
cat > /etc/hotplug.d/block/49-autorecorder <<'EOF_HOTPLUG_BLOCK'
#!/bin/sh
logger -t autorecorder "block hotplug: ${ACTION:-unknown} ${DEVNAME:-unknown}"
service autorecorder reload
EOF_HOTPLUG_BLOCK
chmod 0755 /etc/hotplug.d/block/49-autorecorder

cat > /etc/hotplug.d/usb/49-autorecorder <<'EOF_HOTPLUG_USB'
#!/bin/sh
logger -t autorecorder "usb hotplug: ${ACTION:-unknown} ${PRODUCT:-unknown}"
service autorecorder reload
EOF_HOTPLUG_USB
chmod 0755 /etc/hotplug.d/usb/49-autorecorder

# ---------------------------------------------------------
# 5. CGI endpoint
# ---------------------------------------------------------
info "Installing CGI endpoint..."
cat > /www/cgi-bin/cm <<'EOF_CGI'
#!/bin/sh
# hALSAmrec CGI control endpoint.

PATH=/usr/sbin:/usr/bin:/sbin:/bin
CTL=/usr/sbin/autorecorderctl

echo "Content-type: text/plain"
echo ""

[ "${REQUEST_METHOD:-}" = "GET" ] || { echo "Error: Method not allowed"; exit 1; }
[ -n "${QUERY_STRING:-}" ] || { echo "Usage: /cgi-bin/cm?cmnd=START|STOP|STATUS|PROBE"; exit 0; }

get_param() {
    key=$1
    qs=${QUERY_STRING:-}

    while [ -n "$qs" ]; do
        pair=${qs%%&*}
        if [ "$pair" = "$qs" ]; then
            qs=""
        else
            qs=${qs#*&}
        fi

        name=${pair%%=*}
        value=${pair#*=}
        [ "$name" = "$key" ] && { printf '%s' "$value"; return 0; }
    done
    return 1
}

CMND=$(get_param cmnd 2>/dev/null | tr '[:lower:]' '[:upper:]')

case "$CMND" in
    START|STOP|STATUS|PROBE)
        "$CTL" "$CMND"
        ;;
    *)
        printf 'Unknown command: %s\nValid commands: START, STOP, STATUS, PROBE\n' "$CMND"
        ;;
esac
EOF_CGI
chmod 0755 /www/cgi-bin/cm
ln -sf /www/cgi-bin/cm /www/cgi-bin/controlweb_cgi

# ---------------------------------------------------------
# 6. RPCD backend for LuCI.
# ---------------------------------------------------------
info "Installing RPCD backend..."
cat > /usr/libexec/rpcd/autorecorder <<'EOF_RPCD'
#!/bin/sh
# hALSAmrec rpcd plugin.

PATH=/usr/sbin:/usr/bin:/sbin:/bin
CTL=/usr/sbin/autorecorderctl
RECORDER=/usr/sbin/recorder

. /usr/share/libubox/jshn.sh

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
    find_pids | awk 'NF { printf "%s%s", sep, $1; sep=" " } END { print "" }'
}

json_bool() {
    name=$1
    value=$2
    if [ "$value" -eq 1 ] 2>/dev/null; then
        json_add_boolean "$name" 1
    else
        json_add_boolean "$name" 0
    fi
}

reply_status() {
    pids=$(pid_list)
    json_init
    if [ -n "$pids" ]; then
        json_bool running 1
        json_add_string status "RUNNING"
        json_add_string pid "$pids"
        json_add_string text "RUNNING (PID: $pids)"
    else
        json_bool running 0
        json_add_string status "STOPPED"
        json_add_string pid ""
        json_add_string text "STOPPED"
    fi
    json_dump
}

reply_command() {
    command=$1
    output=$($CTL "$command" 2>&1)
    rc=$?
    pids=$(pid_list)

    json_init
    [ "$rc" -eq 0 ] && json_bool success 1 || json_bool success 0
    [ -n "$pids" ] && json_bool running 1 || json_bool running 0
    json_add_string message "$output"
    json_add_string pid "$pids"
    json_dump
}

reply_probe() {
    output=$($CTL PROBE 2>&1)
    rc=$?

    json_init
    [ "$rc" -eq 0 ] && json_bool success 1 || json_bool success 0
    json_add_string message "$output"
    json_add_string output "$output"
    json_dump
}

case "${1:-}" in
    list)
        echo '{"status":{},"start":{},"stop":{},"probe":{}}'
        ;;
    call)
        case "${2:-}" in
            status) reply_status ;;
            start) reply_command START ;;
            stop) reply_command STOP ;;
            probe) reply_probe ;;
            *)
                json_init
                json_bool success 0
                json_add_string error "Unknown method"
                json_dump
                ;;
        esac
        ;;
    *)
        echo "Usage: $0 list|call <method>" >&2
        exit 1
        ;;
esac
EOF_RPCD
chmod 0755 /usr/libexec/rpcd/autorecorder

# ---------------------------------------------------------
# 7. LuCI frontend.
# ---------------------------------------------------------
info "Installing LuCI frontend..."
cat > /www/luci-static/resources/view/autorecorder/main.js <<'EOF_LUCI_JS'
'use strict';
'require view';
'require rpc';
'require poll';
'require ui';

var callStatus = rpc.declare({ object: 'autorecorder', method: 'status' });
var callStart = rpc.declare({ object: 'autorecorder', method: 'start' });
var callStop = rpc.declare({ object: 'autorecorder', method: 'stop' });
var callProbe = rpc.declare({ object: 'autorecorder', method: 'probe' });

return view.extend({
    render: function() {
        var statusBadge = E('span', { 'class': 'badge' }, _('Unknown'));
        var statusText = E('pre', { 'style': 'white-space: pre-wrap; margin-top: 1em;' }, _('Loading...'));
        var probeOutput = E('pre', { 'style': 'white-space: pre-wrap; margin-top: 1em; display: none;' });
        var buttons = [];

        function setBadge(running, label) {
            statusBadge.textContent = label || (running ? _('RUNNING') : _('STOPPED'));
            statusBadge.style.color = '#fff';
            statusBadge.style.backgroundColor = running ? '#37a237' : '#a93737';
        }

        function refreshStatus() {
            return callStatus().then(function(data) {
                var running = !!data.running;
                setBadge(running, data.status || (running ? 'RUNNING' : 'STOPPED'));
                statusText.textContent = data.text || (running ? 'RUNNING' : 'STOPPED');
            }).catch(function(err) {
                setBadge(false, _('ERROR'));
                statusText.textContent = _('Unable to read recorder status: ') + err;
            });
        }

        function setButtonsDisabled(disabled) {
            for (var i = 0; i < buttons.length; i++)
                buttons[i].disabled = disabled;
        }

        function runCommand(fn, doneMessage, showProbe) {
            setButtonsDisabled(true);
            probeOutput.style.display = 'none';

            return fn().then(function(res) {
                var msg = res.message || doneMessage;
                ui.addNotification(null, E('p', {}, msg), res.success === false ? 'warning' : 'info');
                if (showProbe) {
                    probeOutput.style.display = '';
                    probeOutput.textContent = res.output || msg;
                }
                return refreshStatus();
            }).catch(function(err) {
                ui.addNotification(null, E('p', {}, _('Command failed: ') + err), 'danger');
            }).then(function() {
                setButtonsDisabled(false);
            });
        }

        buttons.push(E('button', {
            'class': 'btn cbi-button cbi-button-action',
            'click': function(ev) {
                ev.preventDefault();
                return runCommand(callStart, _('Start command sent'), false);
            }
        }, _('START')));

        buttons.push(E('button', {
            'class': 'btn cbi-button cbi-button-negative',
            'style': 'margin-left: .5em;',
            'click': function(ev) {
                ev.preventDefault();
                return runCommand(callStop, _('Stop command sent'), false);
            }
        }, _('STOP')));

        buttons.push(E('button', {
            'class': 'btn cbi-button cbi-button-neutral',
            'style': 'margin-left: .5em;',
            'click': function(ev) {
                ev.preventDefault();
                return runCommand(callProbe, _('Probe completed'), true);
            }
        }, _('PROBE')));

        refreshStatus();
        poll.add(refreshStatus, 5);

        return E('div', { 'class': 'cbi-map' }, [
            E('h2', {}, _('hALSAmrec')),
            E('div', { 'class': 'cbi-map-descr' }, _('Control the autorecorder daemon. This page exposes the same START, STOP, STATUS and PROBE functions as the CGI endpoint.')),
            E('div', { 'class': 'cbi-section' }, [
                E('h3', {}, _('Status')),
                statusBadge,
                statusText,
                E('div', { 'style': 'margin-top: 1em;' }, buttons),
                probeOutput
            ])
        ]);
    }
});
EOF_LUCI_JS
chmod 0644 /www/luci-static/resources/view/autorecorder/main.js

# ---------------------------------------------------------
# 8. LuCI menu and ACL.
# ---------------------------------------------------------
info "Installing LuCI menu and ACL..."
cat > /usr/share/luci/menu.d/autorecorder.json <<'EOF_MENU'
{
    "admin/system/autorecorder": {
        "title": "hALSAmrec",
        "action": {
            "type": "view",
            "path": "autorecorder/main"
        },
        "depends": {
            "acl": [ "luci-app-autorecorder" ]
        }
    }
}
EOF_MENU
chmod 0644 /usr/share/luci/menu.d/autorecorder.json

cat > /usr/share/rpcd/acl.d/autorecorder.json <<'EOF_ACL'
{
    "luci-app-autorecorder": {
        "description": "Grant LuCI access to hALSAmrec",
        "read": {
            "ubus": {
                "autorecorder": [ "status", "probe" ]
            }
        },
        "write": {
            "ubus": {
                "autorecorder": [ "start", "stop" ]
            }
        }
    }
}
EOF_ACL
chmod 0644 /usr/share/rpcd/acl.d/autorecorder.json

# ---------------------------------------------------------
# 9. Activate services.
# ---------------------------------------------------------
info "Reloading services..."
/etc/init.d/rpcd restart >/dev/null 2>&1 || service rpcd restart >/dev/null 2>&1 || warn "Could not restart rpcd"
/etc/init.d/autorecorder enable >/dev/null 2>&1 || warn "Could not enable autorecorder"
/etc/init.d/autorecorder restart >/dev/null 2>&1 || /etc/init.d/autorecorder start >/dev/null 2>&1 || warn "Could not start autorecorder"

if ! command -v arecord >/dev/null 2>&1; then
    warn "arecord is not available. Install alsa-utils before using the recorder."
fi

cat <<'EOF_DONE'

==========================================
Installation complete
==========================================

LuCI:      System -> hALSAmrec
CGI:       /cgi-bin/cm?cmnd=START|STOP|STATUS|PROBE
CLI:       /usr/sbin/autorecorderctl START|STOP|STATUS|PROBE
Daemon:    /etc/init.d/autorecorder start|stop|reload|status
Storage:   exactly one exFAT partition is required
Output:    /tmp/mnt/<epoch>_<channels>-<rate>-<format>.raw

EOF_DONE
