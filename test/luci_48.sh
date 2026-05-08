#!/bin/sh
#
# install-autorecorder.sh — hALSAmrec v4.8 installer
# by FORART (https://forart.it/), 2025-26
# GPL v3 — see <https://www.gnu.org/licenses/>
#
# Single-file self-contained installer.
# All runtime files are embedded as heredocs.
#
# Usage:
#   scp install-autorecorder.sh root@192.168.1.1:/tmp/
#   ssh root@192.168.1.1 sh /tmp/install-autorecorder.sh
#
# Supports: OpenWrt 21.x / 22.x / 23.x / 24.x
# Idempotent: safe to run multiple times.
#
# Changes from v4.7 (Forensic UI Fixes - Native jshn rewrite):
#
#   [FIX-W] rpcd: Eradicated raw shell JSON generation.
#            All rpcd shell output is now generated natively via 
#            /usr/share/libubox/jshn.sh. This completely eliminates 
#            JSON syntax errors caused by empty variables (e.g. {"pid": }) 
#            and automatically escapes multiline text (e.g. from arecord -l), 
#            resolving the silent Promise rejections in LuCI.
#
#   [FIX-X] rpcd: Stdin deadlock resolved.
#            Replaced `read -r input` with `INPUT_JSON=$(cat)` in the 
#            set_config method. rpcd does not guarantee a trailing newline 
#            on stdin payloads, which caused BusyBox read to hang indefinitely.
#
#   [All v4.5, v4.6, and v4.7 engineering fixes retained]

set -e

# ── Terminal helpers ──────────────────────────────────────────────────────────
if [ -t 1 ]; then
    BOLD='\033[1m'; BLUE='\033[1;34m'; GREEN='\033[1;32m'
    YELLOW='\033[1;33m'; RED='\033[1;31m'; RESET='\033[0m'
else
    BOLD=''; BLUE=''; GREEN=''; YELLOW=''; RED=''; RESET=''
fi

STEP() { printf "\n${BLUE}=> %s${RESET}\n" "$1"; }
OK()   { printf "  ${GREEN}OK %s${RESET}\n" "$1"; }
WARN() { printf "  ${YELLOW}!! %s${RESET}\n" "$1"; }
ERR()  { printf "  ${RED}FAIL %s${RESET}\n" "$1"; exit 1; }

# ── 0. Pre-flight checks ──────────────────────────────────────────────────────
STEP "Pre-flight checks"

[ "$(id -u)" -eq 0 ] || ERR "Must be run as root"
[ -f /etc/openwrt_release ] || ERR "Not an OpenWrt system"

OPENWRT_VER=$(. /etc/openwrt_release && printf '%s' "$DISTRIB_RELEASE")
OK "OpenWrt $OPENWRT_VER detected"

command -v opkg >/dev/null 2>&1 || ERR "opkg not found"
OK "opkg available"

# ── 1. Dependencies ───────────────────────────────────────────────────────────
STEP "Updating package list"
if opkg update >/dev/null 2>&1; then
    OK "Package list updated"
else
    WARN "opkg update failed — continuing with cached package list"
fi

STEP "Installing required packages"
opkg install \
    alsa-utils \
    kmod-usb-storage \
    block-mount \
    kmod-usb3 \
    kmod-usb-audio \
    usbutils \
    kmod-fs-exfat \
    jsonfilter \
    || ERR "Package installation failed — check feed availability"
OK "Packages installed"

# ── 2. Write runtime files ────────────────────────────────────────────────────
STEP "Writing runtime files"

# ── /usr/sbin/recorder ────────────────────────────────────────────────────────
cat > /usr/sbin/recorder << 'EOF_RECORDER'
#!/bin/sh
#
# /usr/sbin/recorder — hALSAmrec v4.8
# Original script by J. Bruce Fields, 2024
# This version by FORART (https://forart.it/), 2025-26
# GPL v3 — see <https://www.gnu.org/licenses/>
#
# Architecture: single supervisor loop that mounts the recording disk ONCE
# and keeps it mounted for the entire service lifetime.  arecord is a child
# process; its exit never triggers an unmount.  The disk is only unmounted
# when it is physically removed (disk="" after scan) or SIGTERM is received.
#
# Hotplug events reach this loop as SIGHUP via "service autorecorder reload",
# which interrupts the wait() call so the loop re-evaluates hardware state
# without stopping an in-progress recording.

uci_get() { uci -q get "autorecorder.config.$1" 2>/dev/null; }

# kill_recorder: SIGTERM → 1 s grace → SIGKILL.
kill_recorder() {
    local pid="$1"
    [ -z "$pid" ] && return
    kill "$pid" 2>/dev/null
    sleep 1
    kill -9 "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null || true
}

MNT=$(uci_get mount)
MNT="${MNT:-/tmp/mnt}"

recorder=""       # PID of active arecord child; empty when not recording
disk_mounted=0    # 1 when recording disk is currently mounted
active_mnt=""     # actual mountpoint in use (may differ from $MNT if UCI changed)

# SIGHUP: interrupt wait() only — never terminate recorder child.
trap 'true' SIGHUP

# Sentinel: sleep infinity gives the wait() call something to block on when
# no arecord is running, and is interruptible by SIGHUP.
sleep infinity &
dummy=$!

# Publish our PID so the rpcd plugin can find us without pgrep.
printf '%s\n' $$ > /var/run/autorecorder.pid

# SIGTERM: clean shutdown — stop arecord, unmount disk, remove PID file, exit.
trap '
    kill "$dummy" 2>/dev/null
    kill_recorder "$recorder"
    [ "$disk_mounted" -eq 1 ] && umount -l "${active_mnt:-$MNT}" 2>/dev/null
    rm -f /var/run/autorecorder.pid
    exit 0
' SIGTERM

first=0

while true; do

    if [ $first -eq 0 ]; then
        first=1
    else
        wait ${recorder:-$dummy}
    fi

    MNT=$(uci_get mount)
    MNT="${MNT:-/tmp/mnt}"

    if [ "$disk_mounted" -eq 1 ] && [ -n "$active_mnt" ] && [ "$MNT" != "$active_mnt" ]; then
        kill_recorder "$recorder"
        recorder=""
        umount -l "$active_mnt" 2>/dev/null
        disk_mounted=0
        active_mnt=""
    fi

    # ── Audio card detection ──────────────────────────────────────────────────
    card_num=$(uci_get card)
    dev_num=$(uci_get device)

    if [ -n "$card_num" ] && [ -n "$dev_num" ]; then
        card_ready=1
    else
        card_line=$(arecord -l 2>/dev/null | grep '^card' | head -n 1)
        if [ -n "$card_line" ]; then
            card_num=$(printf '%s\n' "$card_line" | sed 's/^card \([0-9]*\):.*/\1/')
            dev_num=$(printf '%s\n'  "$card_line" | sed 's/.*device \([0-9]*\):.*/\1/')
            card_ready=1
        else
            card_num="" dev_num="" card_ready=0
        fi
    fi

    # ── Disk detection ────────────────────────────────────────────────────────
    disk="" disk_uuid="" exfat_count=0
    while read -r _maj _min _blk name; do
        case "$name" in
            sd*[0-9] | mmcblk*p[0-9]* | nvme*p[0-9]*)
                dev="/dev/$name"
                [ -b "$dev" ] || continue
                fs_type=$(blkid -o value -s TYPE "$dev" 2>/dev/null)
                if [ -z "$fs_type" ]; then
                    dd if="$dev" bs=1 skip=3 count=5 2>/dev/null \
                        | grep -q 'EXFAT' && fs_type='exfat'
                fi
                case "$fs_type" in [Ee][Xx][Ff][Aa][Tt])
                    exfat_count=$((exfat_count + 1))
                    disk="$dev"
                    disk_uuid=$(blkid -o value -s UUID "$dev" 2>/dev/null)
                esac
        esac
    done < /proc/partitions

    if [ "$exfat_count" -ne 1 ]; then
        disk=""
        disk_uuid=""
    fi

    if [ "$disk_mounted" -eq 1 ] && [ -z "$disk" ]; then
        kill_recorder "$recorder"
        recorder=""
        umount -l "${active_mnt:-$MNT}" 2>/dev/null
        disk_mounted=0
        active_mnt=""
        continue
    fi

    if [ -n "$recorder" ] && [ ! -e "/proc/$recorder" ]; then
        recorder=""
    fi

    if [ "$card_ready" -eq 0 ]; then
        if [ -n "$recorder" ]; then
            kill_recorder "$recorder"
            recorder=""
        fi
        continue
    fi

    if [ -n "$disk" ] && [ "$disk_mounted" -eq 0 ]; then
        mkdir -p "$MNT"
        if [ -n "$disk_uuid" ]; then
            resolved=$(blkid -t "UUID=${disk_uuid}" -l -o device 2>/dev/null)
            [ -n "$resolved" ] && disk="$resolved"
        fi
        mount "$disk" "$MNT" 2>/dev/null || continue
        disk_mounted=1
        active_mnt="$MNT"
    fi

    [ -n "$recorder" ] && continue

    # ── Disk space check ──────────────────────────────────────────────────────
    avail_kb=$(df -k "$active_mnt" 2>/dev/null | tail -n 1 | awk '{print $4}')
    avail_kb="${avail_kb:-0}"
    if [ "$(( avail_kb / 1024 ))" -le 100 ]; then
        sleep 5
        continue
    fi

    # ── Hardware parameter detection ──────────────────────────────────────────
    arecord_out=$(arecord -D "hw:${card_num},${dev_num}" --dump-hw-params 2>&1)

    max_ch=$(printf '%s\n' "$arecord_out" \
        | sed -n 's/^CHANNELS:.*\[\([0-9]*\) \([0-9]*\)\].*/\2/p')
    [ -z "$max_ch" ] && \
        max_ch=$(printf '%s\n' "$arecord_out" \
            | sed -n 's/^CHANNELS:[[:space:]]*\[*\([0-9][0-9]*\).*/\1/p')
    max_ch="${max_ch:-2}"

    fmt_raw=$(printf '%s\n' "$arecord_out" \
        | sed -n 's/^FORMAT:[[:space:]]*//p' | head -n 1)
    bitfmt="${fmt_raw##* }"
    bitfmt="${bitfmt:-S16_LE}"

    max_rate=$(printf '%s\n' "$arecord_out" \
        | sed -n 's/^RATE:.*[\[(]\([0-9]*\) \([0-9]*\)[])].*/ \2/p')
    [ -z "$max_rate" ] && \
        max_rate=$(printf '%s\n' "$arecord_out" \
            | sed -n 's/^RATE:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
    max_rate="${max_rate:-48000}"
    case "$max_rate" in *[!0-9]*) max_rate=48000 ;; esac
    [ "$max_rate" -gt 48000 ] && max_rate=48000

    buf_time=$(printf '%s\n' "$arecord_out" \
        | sed -n 's/^BUFFER_TIME:.*[\[(]\([0-9]*\) \([0-9]*\)[])].*/ \2/p')

    # ── Auto-persist detected card/device to UCI ──────────────────────────────
    if [ "$card_ready" -eq 1 ] && [ -z "$(uci_get card)" ]; then
        _recheck=$(uci_get card)
        if [ -z "$_recheck" ]; then
            uci -q set autorecorder.config=autorecorder
            uci -q set autorecorder.config.card="$card_num"
            uci -q set autorecorder.config.device="$dev_num"
            uci -q commit autorecorder
        fi
    fi

    # ── Start recording ───────────────────────────────────────────────────────
    set -- arecord \
        "--device=hw:${card_num},${dev_num}" \
        "--channels=${max_ch}" \
        "--file-type=raw" \
        "--format=${bitfmt}" \
        "--rate=${max_rate}"
    [ -n "$buf_time" ] && set -- "$@" "--buffer-time=${buf_time}"

    "$@" > "${active_mnt}/$(date +%s)_${max_ch}-${max_rate}-${bitfmt}.raw" 2>/dev/null &
    recorder=$!

done
EOF_RECORDER
OK "/usr/sbin/recorder"

# ── /etc/init.d/autorecorder ──────────────────────────────────────────────────
cat > /etc/init.d/autorecorder << 'EOF_INIT'
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
    procd_set_param respawn  3600 5 5
    procd_close_instance
}

reload_service() {
    procd_send_signal autorecorder
}
EOF_INIT
OK "/etc/init.d/autorecorder"

# ── /etc/hotplug.d/block/50-autorecorder ─────────────────────────────────────
mkdir -p /etc/hotplug.d/block
cat > /etc/hotplug.d/block/50-autorecorder << 'EOF_HOTPLUG_BLOCK'
#!/bin/sh
case "$ACTION" in
    add|remove|change) service autorecorder reload ;;
esac
EOF_HOTPLUG_BLOCK
OK "/etc/hotplug.d/block/50-autorecorder"

# ── /etc/hotplug.d/usb/50-autorecorder ───────────────────────────────────────
mkdir -p /etc/hotplug.d/usb
cat > /etc/hotplug.d/usb/50-autorecorder << 'EOF_HOTPLUG_USB'
#!/bin/sh
case "$ACTION" in
    add|remove|change) service autorecorder reload ;;
esac
EOF_HOTPLUG_USB
OK "/etc/hotplug.d/usb/50-autorecorder"

# ── /usr/libexec/rpcd/autorecorder ───────────────────────────────────────────
mkdir -p /usr/libexec/rpcd
cat > /usr/libexec/rpcd/autorecorder << 'EOF_RPCD'
#!/bin/sh
#
# rpcd shell plugin for hALSAmrec autorecorder v4.8
# by FORART (https://forart.it/), 2025-26
# GPL v3 — see <https://www.gnu.org/licenses/>

# [FIX-W] Source native OpenWrt JSHN to guarantee valid JSON responses
. /usr/share/libubox/jshn.sh

RECORDER=/usr/sbin/recorder
INIT=/etc/init.d/autorecorder
MNT_DEFAULT=/tmp/mnt
PIDFILE=/var/run/autorecorder.pid

is_running() {
    local pid
    pid=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
        tr '\000' '\n' < "/proc/$pid/cmdline" 2>/dev/null \
            | grep -qF "$RECORDER" && return 0
    fi
    for _cl in /proc/[0-9]*/cmdline; do
        tr '\000' '\n' < "$_cl" 2>/dev/null \
            | grep -qF "$RECORDER" && return 0
    done
    return 1
}

get_recorder_pid() {
    local pid
    pid=$(cat "$PIDFILE" 2>/dev/null) || return
    [ -n "$pid" ] && [ -d "/proc/$pid" ] && printf '%s' "$pid"
}

uci_get() { uci -q get "autorecorder.config.$1" 2>/dev/null; }

is_mounted() {
    awk -v m="$1" '$2 == m { found=1 } END { exit !found }' /proc/mounts 2>/dev/null
}

case "$1" in
    list)
        # Static introspection JSON response
        printf '{"status":{},"start":{},"stop":{},"probe":{},"disk_status":{},"get_config":{},"set_config":{"card":"","device":"","mount":""}}\n'
        ;;

    call)
        case "$2" in

            status)
                json_init
                if is_running; then
                    pid=$(get_recorder_pid)
                    json_add_boolean "running" 1
                    json_add_int "pid" "${pid:-0}"
                else
                    json_add_boolean "running" 0
                    json_add_int "pid" 0
                fi
                json_dump
                ;;

            start)
                json_init
                if is_running; then
                    json_add_string "result" "already_running"
                else
                    "$INIT" start >/dev/null 2>&1
                    i=0
                    while [ $i -lt 4 ]; do
                        sleep 1
                        is_running && break
                        i=$((i + 1))
                    done
                    if is_running; then
                        json_add_string "result" "started"
                    else
                        json_add_string "result" "failed"
                    fi
                fi
                json_dump
                ;;

            stop)
                json_init
                if ! is_running; then
                    json_add_string "result" "already_stopped"
                else
                    "$INIT" stop >/dev/null 2>&1
                    i=0
                    while [ $i -lt 4 ]; do
                        sleep 1
                        ! is_running && break
                        i=$((i + 1))
                    done
                    if ! is_running; then
                        json_add_string "result" "stopped"
                    else
                        json_add_string "result" "failed"
                    fi
                fi
                json_dump
                ;;

            probe)
                json_init
                if is_running; then
                    json_add_string "error" "recorder_running"
                    json_add_string "output" ""
                else
                    card=$(uci_get card); card="${card:-0}"
                    dev=$(uci_get device);  dev="${dev:-0}"
                    mnt=$(uci_get mount);   mnt="${mnt:-$MNT_DEFAULT}"

                    card_list=$(arecord -l 2>&1 || printf '(arecord -l failed)')
                    hw_params=$(arecord -D "hw:${card},${dev}" --dump-hw-params 2>&1)
                    hw_rc=$?

                    if is_mounted "$mnt"; then
                        df_line=$(df -k "$mnt" 2>/dev/null | tail -n 1)
                        disk_info="Mounted at ${mnt}\n${df_line}"
                    else
                        disk_info="NOT mounted at ${mnt}"
                    fi

                    part_info=$(cat /proc/partitions 2>/dev/null)

                    combined="=== ALSA CAPTURE DEVICES ===
${card_list}

=== HW PARAMS (hw:${card},${dev}) ===
${hw_params}

=== STORAGE (${mnt}) ===
${disk_info}

=== BLOCK DEVICES (/proc/partitions) ===
${part_info}"

                    if [ "$hw_rc" -ne 0 ]; then
                        json_add_string "error" "probe_warnings"
                    else
                        json_add_string "error" ""
                    fi
                    json_add_string "output" "$combined"
                fi
                json_dump
                ;;

            disk_status)
                json_init
                mnt=$(uci_get mount); mnt="${mnt:-$MNT_DEFAULT}"
                if is_mounted "$mnt"; then
                    df_line=$(df -k "$mnt" 2>/dev/null | tail -n 1)
                    total_kb=$(printf '%s\n' "$df_line" | awk '{print ($2+0)}')
                    used_kb=$(printf '%s\n'  "$df_line" | awk '{print ($3+0)}')
                    avail_kb=$(printf '%s\n' "$df_line" | awk '{print ($4+0)}')
                    
                    json_add_boolean "mounted" 1
                    json_add_int "total_kb" "${total_kb:-0}"
                    json_add_int "used_kb" "${used_kb:-0}"
                    json_add_int "avail_kb" "${avail_kb:-0}"
                    json_add_string "mount" "$mnt"
                else
                    json_add_boolean "mounted" 0
                    json_add_int "total_kb" 0
                    json_add_int "used_kb" 0
                    json_add_int "avail_kb" 0
                    json_add_string "mount" "$mnt"
                fi
                json_dump
                ;;

            get_config)
                json_init
                card=$(uci_get card)
                device=$(uci_get device)
                mount=$(uci_get mount)
                
                json_add_string "card" "${card:-}"
                json_add_string "device" "${device:-}"
                json_add_string "mount" "${mount:-$MNT_DEFAULT}"
                json_dump
                ;;

            set_config)
                # [FIX-X] Read all of stdin securely, preventing read -r hang
                INPUT_JSON=$(cat)
                
                card=$(printf '%s' "$INPUT_JSON" | jsonfilter -e '@.card' 2>/dev/null)
                device=$(printf '%s' "$INPUT_JSON" | jsonfilter -e '@.device' 2>/dev/null)
                mount_path=$(printf '%s' "$INPUT_JSON" | jsonfilter -e '@.mount' 2>/dev/null)

                json_init

                if [ -n "$mount_path" ]; then
                    case "$mount_path" in
                        /*) ;;
                        *)
                            json_add_string "result" "invalid_mount"
                            json_dump
                            exit 0
                            ;;
                    esac
                fi

                uci -q set autorecorder.config=autorecorder

                if [ -n "$card" ]; then
                    uci -q set autorecorder.config.card="$card"
                else
                    uci -q delete autorecorder.config.card 2>/dev/null || true
                fi

                if [ -n "$device" ]; then
                    uci -q set autorecorder.config.device="$device"
                else
                    uci -q delete autorecorder.config.device 2>/dev/null || true
                fi

                if [ -n "$mount_path" ]; then
                    uci -q set autorecorder.config.mount="$mount_path"
                else
                    uci -q delete autorecorder.config.mount 2>/dev/null || true
                fi

                uci -q commit autorecorder
                
                json_add_string "result" "ok"
                json_dump
                ;;

            *)
                json_init
                json_add_string "error" "unknown_method"
                json_dump
                ;;
        esac
        ;;
esac
EOF_RPCD
OK "/usr/libexec/rpcd/autorecorder"

# ── /www/luci-static/resources/view/autorecorder/main.js ─────────────────────
mkdir -p /www/luci-static/resources/view/autorecorder
cat > /www/luci-static/resources/view/autorecorder/main.js << 'EOF_JS'
'use strict';
'require view';
'require rpc';
'require poll';
'require dom';

var callStatus = rpc.declare({
    object: 'autorecorder',
    method: 'status',
    expect: { running: false, pid: 0 }
});

var callStart = rpc.declare({
    object: 'autorecorder',
    method: 'start',
    expect: { result: '' }
});

var callStop = rpc.declare({
    object: 'autorecorder',
    method: 'stop',
    expect: { result: '' }
});

var callProbe = rpc.declare({
    object: 'autorecorder',
    method: 'probe',
    expect: { error: '', output: '' }
});

var callDiskStatus = rpc.declare({
    object: 'autorecorder',
    method: 'disk_status',
    expect: { mounted: false, total_kb: 0, used_kb: 0, avail_kb: 0, mount: '' }
});

var callGetConfig = rpc.declare({
    object: 'autorecorder',
    method: 'get_config',
    expect: { card: '', device: '', mount: '' }
});

var callSetConfig = rpc.declare({
    object: 'autorecorder',
    method: 'set_config',
    params: ['card', 'device', 'mount'],
    expect: { result: '' }
});

return view.extend({

    load: function() {
        return Promise.all([
            callStatus().catch(function() {
                return { running: false, pid: 0 };
            }),
            callDiskStatus().catch(function() {
                return { mounted: false, total_kb: 0, used_kb: 0, avail_kb: 0, mount: '/tmp/mnt' };
            }),
            callGetConfig().catch(function() {
                return { card: '', device: '', mount: '/tmp/mnt' };
            })
        ]);
    },

    render: function(data) {
        var self   = this;
        var status = data[0];
        var disk   = data[1];
        var config = data[2];

        var running = !!(status && status.running);
        var btnToggle = E('button', {
            'class': 'btn cbi-button ' +
                     (running ? 'cbi-button-negative' : 'cbi-button-apply'),
            'id':    'ar-btn-toggle',
            'style': 'min-width:90px;font-weight:bold;color:#fff;' +
                     (running
                         ? 'background:#dc3545;border-color:#dc3545'
                         : 'background:#28a745;border-color:#28a745'),
            'click': function() { self._doToggle(); }
        }, running ? _('STOP') : _('START'));

        var cardInput = E('input', {
            'type':        'text',
            'id':          'ar-cfg-card',
            'class':       'cbi-input-text',
            'style':       'width:60px',
            'placeholder': _('auto'),
            'value':       config.card || ''
        });

        var deviceInput = E('input', {
            'type':        'text',
            'id':          'ar-cfg-device',
            'class':       'cbi-input-text',
            'style':       'width:60px',
            'placeholder': '0',
            'value':       config.device || ''
        });

        var mountInput = E('input', {
            'type':        'text',
            'id':          'ar-cfg-mount',
            'class':       'cbi-input-text',
            'style':       'width:240px',
            'placeholder': '/tmp/mnt',
            'value':       config.mount || ''
        });

        var btnSaveCfg = E('button', {
            'class': 'btn cbi-button cbi-button-save',
            'id':    'ar-btn-savecfg',
            'click': function() { self._doSaveConfig(); }
        }, _('Save'));

        var btnClearCfg = E('button', {
            'class': 'btn cbi-button cbi-button-reset',
            'id':    'ar-btn-clearcfg',
            'click': function() { self._doClearConfig(); }
        }, _('Clear (revert to auto-detect)'));

        var btnProbe = E('button', {
            'class': 'btn cbi-button cbi-button-action',
            'id':    'ar-btn-probe',
            'click': function() { self._doProbe(); }
        }, _('Probe Hardware'));

        var probeOutput = E('pre', {
            'id':    'ar-probe-output',
            'style': 'display:none;margin-top:0.75em;padding:8px 10px;' +
                     'background:#f4f4f4;border:1px solid #ddd;border-radius:3px;' +
                     'font-size:0.82em;white-space:pre-wrap;word-break:break-all;' +
                     'max-height:360px;overflow-y:auto'
        });

        var page = E('div', { 'class': 'cbi-map' }, [

            E('h2', _('ALSA Recorder')),

            E('div', { 'class': 'cbi-section' }, [
                E('h3', _('Service')),
                E('div', { 'class': 'cbi-section-descr' },
                    _('Status refreshes automatically every 5 seconds.')),
                E('table', { 'class': 'table cbi-section-table' }, [
                    E('tr', { 'class': 'tr cbi-rowstyle-1' }, [
                        E('td', {
                            'class': 'td left',
                            'style': 'width:180px;font-weight:bold;vertical-align:middle'
                        }, _('Recorder')),
                        E('td', { 'class': 'td left', 'id': 'ar-status-cell' },
                            [self._statusBadge(status)])
                    ]),
                    E('tr', { 'class': 'tr cbi-rowstyle-2' }, [
                        E('td', {
                            'class': 'td left',
                            'style': 'font-weight:bold;vertical-align:middle'
                        }, _('Storage')),
                        E('td', { 'class': 'td left', 'id': 'ar-disk-cell' },
                            [self._diskInfo(disk)])
                    ])
                ]),
                E('div', { 'style': 'margin-top:1em;display:flex;gap:6px;flex-wrap:wrap' }, [
                    btnToggle
                ])
            ]),

            E('div', { 'class': 'cbi-section' }, [
                E('h3', _('Hardware Configuration')),
                E('div', { 'class': 'cbi-section-descr' },
                    _('Persist ALSA card and device indices to UCI. ' +
                      'When set, the recorder skips the arecord\u00a0-l probe on every cycle. ' +
                      'The recorder auto-populates these on first successful detection. ' +
                      'Clear to revert to auto-detection (e.g.\u00a0after a hardware change). ' +
                      'A service restart is required for changes to take effect.')),
                E('table', { 'class': 'table cbi-section-table' }, [
                    E('tr', { 'class': 'tr cbi-rowstyle-1' }, [
                        E('td', { 'class': 'td left', 'style': 'width:180px;font-weight:bold' },
                            _('ALSA Card')),
                        E('td', { 'class': 'td left' }, [cardInput])
                    ]),
                    E('tr', { 'class': 'tr cbi-rowstyle-2' }, [
                        E('td', { 'class': 'td left', 'style': 'font-weight:bold' },
                            _('ALSA Device')),
                        E('td', { 'class': 'td left' }, [deviceInput])
                    ]),
                    E('tr', { 'class': 'tr cbi-rowstyle-1' }, [
                        E('td', { 'class': 'td left', 'style': 'font-weight:bold' },
                            _('Mount Point')),
                        E('td', { 'class': 'td left' }, [mountInput])
                    ])
                ]),
                E('div', { 'style': 'margin-top:1em;display:flex;gap:6px;flex-wrap:wrap' }, [
                    btnSaveCfg, btnClearCfg
                ])
            ]),

            E('div', { 'class': 'cbi-section' }, [
                E('h3', _('Hardware Probe')),
                E('div', { 'class': 'cbi-section-descr' },
                    _('Dump ALSA hardware parameters, storage status, and block-device ' +
                      'snapshot for the configured card/device (falls back to hw:0,0). ' +
                      'The recorder must be stopped first.')),
                btnProbe,
                probeOutput
            ])
        ]);

        poll.add(function() {
            return Promise.all([
                callStatus().catch(function() {
                    return { running: false, pid: 0 };
                }),
                callDiskStatus().catch(function() {
                    return { mounted: false, total_kb: 0, used_kb: 0, avail_kb: 0, mount: '/tmp/mnt' };
                })
            ]).then(function(results) {
                var sc = document.getElementById('ar-status-cell');
                var dc = document.getElementById('ar-disk-cell');
                if (sc) dom.content(sc, self._statusBadge(results[0]));
                if (dc) dom.content(dc, self._diskInfo(results[1]));
                self._updateToggle(!!(results[0] && results[0].running));
            });
        }, 5);

        return page;
    },

    _statusBadge: function(status) {
        var running = status && status.running;
        var label   = running
            ? ('\u25cf\u00a0' + _('Running') + '\u00a0\u2014\u00a0PID\u00a0' + status.pid)
            : ('\u25cf\u00a0' + _('Stopped'));
        return E('span', {
            'style': running ? 'color:#28a745;font-weight:bold'
                             : 'color:#dc3545;font-weight:bold'
        }, label);
    },

    _diskInfo: function(disk) {
        if (!disk || !disk.mounted) {
            return E('span', { 'style': 'color:#6c757d' }, _('Not mounted'));
        }
        var pct   = disk.total_kb > 0
            ? Math.round((disk.used_kb / disk.total_kb) * 100) : 0;
        var free  = this._fmtKb(disk.avail_kb);
        var total = this._fmtKb(disk.total_kb);
        var bar   = E('div', {
            'style': 'margin-top:4px;height:4px;width:160px;background:#dee2e6;border-radius:2px'
        }, [E('div', {
            'style': 'height:100%;width:' + pct + '%;background:' +
                     (pct > 90 ? '#dc3545' : pct > 70 ? '#ffc107' : '#28a745') +
                     ';border-radius:2px;transition:width 0.3s'
        })]);
        return E('span', {}, [
            E('span', { 'style': 'color:#28a745;font-weight:bold' }, '\u25cf\u00a0'),
            free + '\u00a0' + _('free of') + '\u00a0' + total +
                '\u00a0(' + pct + '%\u00a0' + _('used') + ')',
            E('br'),
            bar,
            E('small', { 'style': 'color:#6c757d' }, disk.mount)
        ]);
    },

    _fmtKb: function(kb) {
        if (kb >= 1048576) return (kb / 1048576).toFixed(1) + '\u00a0GB';
        if (kb >= 1024)    return Math.round(kb / 1024)     + '\u00a0MB';
        return kb + '\u00a0KB';
    },

    _setBusy: function(busy) {
        ['ar-btn-toggle', 'ar-btn-probe',
         'ar-btn-savecfg', 'ar-btn-clearcfg'].forEach(function(id) {
            var el = document.getElementById(id);
            if (el) el.disabled = busy;
        });
    },

    _updateToggle: function(running) {
        var btn = document.getElementById('ar-btn-toggle');
        if (!btn || btn.disabled) return;
        if (running) {
            btn.textContent  = _('STOP');
            btn.style.cssText = 'min-width:90px;font-weight:bold;color:#fff;' +
                                'background:#dc3545;border-color:#dc3545';
            btn.className = 'btn cbi-button cbi-button-negative';
        } else {
            btn.textContent  = _('START');
            btn.style.cssText = 'min-width:90px;font-weight:bold;color:#fff;' +
                                'background:#28a745;border-color:#28a745';
            btn.className = 'btn cbi-button cbi-button-apply';
        }
    },

    _refreshStatus: function() {
        var self = this;
        return callStatus().catch(function() {
            return { running: false, pid: 0 };
        }).then(function(status) {
            var sc = document.getElementById('ar-status-cell');
            if (sc) dom.content(sc, self._statusBadge(status));
            self._updateToggle(!!(status && status.running));
        });
    },

    _doToggle: function() {
        var self = this;
        var btn  = document.getElementById('ar-btn-toggle');
        if (!btn || btn.disabled) return;
        var willStop = (btn.textContent.trim() === _('STOP'));
        self._setBusy(true);
        var action = willStop ? callStop() : callStart();
        return action.then(function(res) {
            if (!res || res.result === 'failed') {
                window.alert(willStop
                    ? _('Failed to stop recorder. Check system logs.')
                    : _('Failed to start recorder. Check system logs.'));
            }
        }).catch(function(err) {
            window.alert(_('RPC error: ') + (err.message || String(err)));
        }).then(function() {
            return self._refreshStatus();
        }).then(function() {
            self._setBusy(false);
        });
    },

    _doProbe: function() {
        var self = this;
        var pre  = document.getElementById('ar-probe-output');
        if (!pre) return;
        pre.style.display = 'block';
        pre.textContent   = _('Querying hardware\u2026');
        self._setBusy(true);
        return callProbe().then(function(res) {
            if (res.error === 'recorder_running') {
                pre.textContent = _('Cannot probe: stop the recorder first.');
            } else if (res.error === 'probe_warnings') {
                pre.textContent = _('[Probe completed with warnings — check hw:card,device below]\n\n') +
                                  (res.output || _('(no output)'));
            } else {
                pre.textContent = res.output || _('(no output)');
            }
        }).catch(function(err) {
            pre.textContent = _('RPC error: ') + (err.message || String(err));
        }).then(function() { self._setBusy(false); });
    },

    _doSaveConfig: function() {
        var self   = this;
        var card   = (document.getElementById('ar-cfg-card')   || {}).value || '';
        var device = (document.getElementById('ar-cfg-device') || {}).value || '';
        var mount  = (document.getElementById('ar-cfg-mount')  || {}).value || '';

        if ((card   !== '' && !/^\d+$/.test(card)) ||
            (device !== '' && !/^\d+$/.test(device))) {
            window.alert(_('Card and Device must be numeric (or empty for auto-detect).'));
            return;
        }

        self._setBusy(true);
        return callSetConfig(card, device, mount).then(function(res) {
            if (!res || res.result === 'invalid_mount') {
                window.alert(_('Invalid mount path: must be an absolute path (e.g.\u00a0/tmp/mnt).'));
                self._setBusy(false);
                return;
            }
            var btn = document.getElementById('ar-btn-savecfg');
            if (btn) {
                var orig = btn.textContent;
                btn.textContent = _('Saved \u2713');
                setTimeout(function() { btn.textContent = orig; self._setBusy(false); }, 1800);
            } else {
                self._setBusy(false);
            }
        }).catch(function(err) {
            window.alert(_('RPC error: ') + (err.message || String(err)));
            self._setBusy(false);
        });
    },

    _doClearConfig: function() {
        var self = this;
        ['ar-cfg-card', 'ar-cfg-device', 'ar-cfg-mount'].forEach(function(id) {
            var el = document.getElementById(id);
            if (el) el.value = '';
        });
        self._setBusy(true);
        return callSetConfig('', '', '').then(function(res) {
            if (!res || res.result === 'invalid_mount') {
                window.alert(_('Unexpected error clearing config.'));
                self._setBusy(false);
                return;
            }
            var btn = document.getElementById('ar-btn-clearcfg');
            if (btn) {
                var orig = btn.textContent;
                btn.textContent = _('Cleared \u2713');
                setTimeout(function() { btn.textContent = orig; self._setBusy(false); }, 1800);
            } else {
                self._setBusy(false);
            }
        }).catch(function(err) {
            window.alert(_('RPC error: ') + (err.message || String(err)));
            self._setBusy(false);
        });
    },

    handleSaveApply: null,
    handleSave:      null,
    handleReset:     null
});
EOF_JS
OK "/www/luci-static/resources/view/autorecorder/main.js"

# ── LuCI menu entry ───────────────────────────────────────────────────────────
mkdir -p /usr/share/luci/menu.d
cat > /usr/share/luci/menu.d/autorecorder.json << 'EOF_MENU'
{
    "admin/services/autorecorder": {
        "title": "ALSA Recorder",
        "order": 60,
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
OK "/usr/share/luci/menu.d/autorecorder.json"

# ── rpcd ACL ──────────────────────────────────────────────────────────────────
mkdir -p /usr/share/rpcd/acl.d
cat > /usr/share/rpcd/acl.d/autorecorder.json << 'EOF_ACL'
{
    "luci-app-autorecorder": {
        "description": "Grant access to ALSA Recorder controls",
        "read": {
            "ubus": {
                "autorecorder": [ "status", "probe", "disk_status", "get_config" ]
            }
        },
        "write": {
            "ubus": {
                "autorecorder": [ "start", "stop", "set_config" ]
            }
        }
    }
}
EOF_ACL
OK "/usr/share/rpcd/acl.d/autorecorder.json"

STEP "Granting luci-app-autorecorder to rpcd root user"
_rs=$(uci show rpcd 2>/dev/null \
    | grep -F ".username='root'" \
    | sed "s/\\.username=.*//" \
    | head -1)
if [ -n "$_rs" ]; then
    uci -q del_list "${_rs}.read=luci-app-autorecorder"  2>/dev/null || true
    uci -q del_list "${_rs}.write=luci-app-autorecorder" 2>/dev/null || true
    uci -q add_list "${_rs}.read=luci-app-autorecorder"
    uci -q add_list "${_rs}.write=luci-app-autorecorder"
    uci -q commit rpcd
    OK "rpcd: luci-app-autorecorder granted to root (section ${_rs})"
else
    WARN "rpcd root login section not found in /etc/config/rpcd"
    WARN "Add manually: uci add_list rpcd.@login[0].read=luci-app-autorecorder"
    WARN "              uci add_list rpcd.@login[0].write=luci-app-autorecorder"
    WARN "              uci commit rpcd"
fi

# ── /etc/config/autorecorder ──────────────────────────────────────────────────
if [ -f /etc/config/autorecorder ]; then
    OK "/etc/config/autorecorder (already exists — preserving settings)"
else
    cat > /etc/config/autorecorder << 'EOF_UCI'
config autorecorder 'config'
	option mount '/tmp/mnt'
EOF_UCI
    OK "/etc/config/autorecorder"
fi

# ── 3. Permissions ────────────────────────────────────────────────────────────
STEP "Setting permissions"
chmod 0755 /usr/sbin/recorder
chmod 0755 /etc/init.d/autorecorder
chmod 0755 /etc/hotplug.d/block/50-autorecorder
chmod 0755 /etc/hotplug.d/usb/50-autorecorder
chmod 0755 /usr/libexec/rpcd/autorecorder
chmod 0644 /www/luci-static/resources/view/autorecorder/main.js
chmod 0644 /usr/share/luci/menu.d/autorecorder.json
chmod 0644 /usr/share/rpcd/acl.d/autorecorder.json
chmod 0644 /etc/config/autorecorder
OK "Permissions set"

# ── 4. Enable and start service ───────────────────────────────────────────────
STEP "Enabling and starting autorecorder service"
/etc/init.d/autorecorder enable
OK "Autorecorder enabled (starts on boot at S99)"
/etc/init.d/autorecorder start
OK "Autorecorder started"

# ── 5. Restart rpcd ───────────────────────────────────────────────────────────
STEP "Restarting rpcd"
/etc/init.d/rpcd restart
sleep 1

if ubus list autorecorder >/dev/null 2>&1; then
    OK "rpcd plugin registered — ubus list autorecorder"
else
    WARN "rpcd restarted but autorecorder not listed yet — retry: /etc/init.d/rpcd restart"
fi

# ── 6. Clear LuCI caches ──────────────────────────────────────────────────────
STEP "Clearing LuCI caches"
rm -f /tmp/luci-indexcache* /tmp/luci-modulecache* 2>/dev/null || true
OK "LuCI caches cleared"

# ── 7. Summary ────────────────────────────────────────────────────────────────
printf "\n${BOLD}${GREEN}============================================${RESET}\n"
printf "${BOLD}${GREEN}  hALSAmrec v4.8 — Installation complete!${RESET}\n"
printf "${BOLD}${GREEN}============================================${RESET}\n"
printf "\n"
printf "  ${BOLD}LuCI${RESET}   ->  Services -> ALSA Recorder\n"
printf "  ${BOLD}Status${RESET} ->  ubus call autorecorder status\n"
printf "  ${BOLD}Disk${RESET}   ->  ubus call autorecorder disk_status\n"
printf "  ${BOLD}Config${RESET} ->  ubus call autorecorder get_config\n"
printf "  ${BOLD}Probe${RESET}  ->  ubus call autorecorder probe\n"
printf "\n"
printf "  ${BOLD}v4.8 Forensic Fixes (JSHN Architecture):${RESET}\n"
printf "    [W] Completely eliminated raw shell JSON generation.\n"
printf "        Using OpenWrt native JSHN for safe serialization.\n"
printf "    [X] Fixed read -r stdin deadlock in set_config method.\n"
printf "\n"
printf "  ${YELLOW}Important:${RESET} Log out of LuCI and log back in after installation\n"
printf "  so the new rpcd session grants take effect.\n"
printf "\n"
