#!/bin/sh
#
# install-autorecorder.sh — hALSAmrec v4.5 installer
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
# Changes from v4:
#   [FIX-1]  Add /etc/hotplug.d/usb/50-autorecorder — USB audio card
#            plug/unplug events now correctly wake the recorder (critical)
#   [FIX-2]  JS _doStart/_doStop now inspect the rpcd result field and
#            alert the user on failure instead of silently re-enabling buttons.
#   [FIX-3]  JS poll.add error handling — per-call .catch() prevents a
#            transient rpcd failure from silently freezing the status display.
#   [FIX-4]  JS _doStart/_doStop trigger an immediate status badge refresh
#            instead of waiting for the next 5-second poll cycle.
#   [FIX-5]  rpcd disk_status: replace mountpoint(1) with /proc/mounts
#            awk check — mountpoint is util-linux, not always present in
#            busybox-only OpenWrt builds.
#   [FIX-6]  rpcd set_config: validate mount path is absolute before writing
#            to UCI; returns {"result":"invalid_mount"} on bad input.
#   [FIX-7]  rpcd set_config: JS now checks set_config result and alerts on
#            invalid_mount instead of showing the "Saved ✓" tick.
#   [FIX-8]  recorder: narrow auto-persist race window with concurrent LuCI
#            edits — double-check uci_get card immediately before commit.
#   [FIX-9]  hotplug scripts filter ACTION to add|remove|change, skipping
#            USB driver bind/unbind and other irrelevant kernel events.
#   [FIX-10] jsonfilter added to required package list — makes the rpcd
#            set_config dependency explicit (it is a separate package on
#            some older OpenWrt feeds).
#   [FIX-11] Initial /etc/config/autorecorder omits empty-string card/device
#            options — avoids ambiguity between absent and empty UCI options.

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
# block-mount provides blkid; kmod-fs-exfat for exFAT kernel support.
# jsonfilter is used by the rpcd set_config handler [FIX-10].
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
# Original script by J. Bruce Fields, 2024
# This version (v4.5) by FORART (https://forart.it/), 2025-26
# GPL v3 — see <https://www.gnu.org/licenses/>
#
# Changes from v4:
#   - [FIX-8] Narrow auto-persist race window: double-check uci_get card
#     immediately before uci commit to reduce the chance of overwriting a
#     concurrent LuCI set_config save.

uci_get() { uci -q get "autorecorder.config.$1" 2>/dev/null; }

MNT=$(uci_get mount)
MNT="${MNT:-/tmp/mnt}"
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
        # Wait on active recorder PID; fall back to sentinel sleep.
        # SIGHUP (sent by hotplug via procd reload) interrupts wait without
        # terminating $recorder — this is intentional: a hotplug event wakes
        # the supervisor loop for re-evaluation without stopping an in-progress
        # recording.
        wait ${recorder:-$dummy}
    fi

    # Re-read mount point each cycle in case UCI was updated via LuCI
    MNT=$(uci_get mount)
    MNT="${MNT:-/tmp/mnt}"

    # ── Audio card detection ──────────────────────────────────────────────────
    # Use UCI-persisted card/device if available — skips arecord -l entirely.
    # If UCI has empty string (option present but blank), treat as absent.
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
    # Primary: blkid (clean, handles VFAT vs exFAT correctly).
    # Fallback: dd|grep reads raw exFAT OEM-ID bytes at superblock offset 3;
    # works without kernel module support and on busybox builds where blkid
    # was compiled without exFAT type detection.
    # Only ONE exFAT partition is allowed — multiple disks → no recording
    # (prevents ambiguous mount target).
    disk="" exfat_count=0
    while read -r _maj _min _blk name; do
        case "$name" in sd*|mmcblk*|nvme*)
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
            esac
        esac
    done < /proc/partitions
    [ "$exfat_count" -ne 1 ] && disk=""

    # ── Stale PID cleanup ─────────────────────────────────────────────────────
    if [ -n "$recorder" ] && [ ! -e "/proc/$recorder" ]; then
        recorder=""
        umount -l "$MNT"
    fi

    # ── Readiness check ───────────────────────────────────────────────────────
    if [ -z "$disk" ] || [ "$card_ready" -eq 0 ]; then
        if [ -n "$recorder" ]; then
            kill -9 $recorder
            umount -l "$MNT"
            recorder=""
        fi
        continue
    fi

    [ -n "$recorder" ] && continue

    mkdir -p "$MNT"
    mount "$disk" "$MNT" || continue

    # ── Disk space check ──────────────────────────────────────────────────────
    # Require at least 100 MB free before starting a new recording.
    set -- $(df -k "$MNT" | tail -n 1)
    if [ $(($4 / 1024)) -le 100 ]; then
        umount -l "$MNT"
        sleep 5
        continue
    fi

    # ── Hardware parameter detection ──────────────────────────────────────────
    arecord_out=$(arecord -D "hw:${card_num},${dev_num}" --dump-hw-params 2>&1)

    # Max channels: upper bound of range [min max], fallback to single value
    max_ch=$(printf '%s\n' "$arecord_out" | sed -n 's/^CHANNELS:.*\[\([0-9]*\) \([0-9]*\)\].*/\2/p')
    [ -z "$max_ch" ] && \
        max_ch=$(printf '%s\n' "$arecord_out" | sed -n 's/^CHANNELS:[[:space:]]*\[*\([0-9][0-9]*\).*/\1/p')

    # Format: last listed format token
    fmt_raw=$(printf '%s\n' "$arecord_out" | sed -n 's/^FORMAT:[[:space:]]*//p' | head -n 1)
    bitfmt="${fmt_raw##* }"

    # Max sample rate: upper bound of range, capped at 48000
    max_rate=$(printf '%s\n' "$arecord_out" | sed -n 's/^RATE:.*[\[(]\([0-9]*\) \([0-9]*\)[])].*/ \2/p')
    [ -z "$max_rate" ] && \
        max_rate=$(printf '%s\n' "$arecord_out" | sed -n 's/^RATE:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
    [ "$max_rate" -gt 48000 ] && max_rate=48000

    # Buffer parameters (may be empty on some devices; arecord uses defaults)
    buf_time=$(printf '%s\n' "$arecord_out" | sed -n 's/^BUFFER_TIME:.*[\[(]\([0-9]*\) \([0-9]*\)[])].*/ \2/p')
    buf_size=$(printf '%s\n' "$arecord_out" | sed -n 's/^BUFFER_SIZE:.*[\[(]\([0-9]*\) \([0-9]*\)[])].*/ \2/p')

    # ── Auto-persist detected card/device to UCI [FIX-8] ─────────────────────
    # Only writes if values are not already stored.
    # Double-check immediately before commit to narrow the race window with
    # a concurrent LuCI set_config call; last writer wins in UCI, but we
    # minimise the probability of clobbering a deliberate user override.
    if [ "$card_ready" -eq 1 ] && [ -z "$(uci_get card)" ]; then
        # Re-read inside the narrow window before committing
        _recheck=$(uci_get card)
        if [ -z "$_recheck" ]; then
            uci -q set autorecorder.config=autorecorder
            uci -q set autorecorder.config.card="$card_num"
            uci -q set autorecorder.config.device="$dev_num"
            uci -q commit autorecorder
        fi
    fi

    # ── Start recording ───────────────────────────────────────────────────────
    arecord --device="hw:${card_num},${dev_num}" \
        --channels="$max_ch"      \
        --file-type=raw           \
        --format="$bitfmt"        \
        --rate="$max_rate"        \
        --buffer-time="$buf_time" \
        --buffer-size="$buf_size" \
        > "${MNT}/$(date +%s)_${max_ch}-${max_rate}-${bitfmt}.raw" 2>/dev/null &

    recorder=$!
done
EOF_RECORDER
OK "/usr/sbin/recorder"

# ── /etc/init.d/autorecorder ──────────────────────────────────────────────────
cat > /etc/init.d/autorecorder << 'EOF_INIT'
#!/bin/sh /etc/rc.common
#
# autorecorder procd init script
# by FORART (https://forart.it/), 2025-26
# GPL v3 — see <https://www.gnu.org/licenses/>

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

# reload_service sends SIGHUP via procd, which interrupts the wait() in
# the recorder loop so it re-evaluates hardware state without stopping
# an in-progress recording.
reload_service() {
    procd_send_signal autorecorder
}
EOF_INIT
OK "/etc/init.d/autorecorder"

# ── /etc/hotplug.d/block/50-autorecorder ─────────────────────────────────────
mkdir -p /etc/hotplug.d/block
cat > /etc/hotplug.d/block/50-autorecorder << 'EOF_HOTPLUG_BLOCK'
#!/bin/sh
# Wake the recorder supervisor when block device state changes.
# SIGHUP interrupts wait() in the recorder loop; in-progress recordings
# are not terminated — the loop simply re-evaluates hardware readiness.
case "$ACTION" in
    add|remove|change) service autorecorder reload ;;
esac
EOF_HOTPLUG_BLOCK
OK "/etc/hotplug.d/block/50-autorecorder"

# ── /etc/hotplug.d/usb/50-autorecorder ───────────────────────────────────────
mkdir -p /etc/hotplug.d/usb
cat > /etc/hotplug.d/usb/50-autorecorder << 'EOF_HOTPLUG_USB'
#!/bin/sh
# Wake the recorder supervisor on USB device arrival or departure.
# This covers USB audio interfaces, which generate usb hotplug events
# but do NOT generate block hotplug events (unlike USB storage).
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
# rpcd shell plugin for hALSAmrec autorecorder v4.5
# by FORART (https://forart.it/), 2025-26
# GPL v3 — see <https://www.gnu.org/licenses/>
#
# Methods: status, start, stop, probe, disk_status, get_config, set_config
#
# Changes from v4:
#   [FIX-5] disk_status: mountpoint(1) replaced with /proc/mounts awk check.
#            mountpoint is util-linux and is absent on busybox-only builds;
#            /proc/mounts is always present.
#   [FIX-6] set_config: mount path validated as absolute before UCI write.
#            Returns {"result":"invalid_mount"} on a relative or empty path
#            (empty means "delete the option", which is valid and passes).

RECORDER=/usr/sbin/recorder
INIT=/etc/init.d/autorecorder
MNT_DEFAULT=/tmp/mnt

# is_running: matches /usr/sbin/recorder in the full cmdline.
# pgrep -f is used because the kernel sets comm to "sh" (the interpreter),
# not "recorder", when procd exec's the shebang script via /bin/sh.
is_running() { pgrep -f "$RECORDER" >/dev/null 2>&1; }

uci_get() { uci -q get "autorecorder.config.$1" 2>/dev/null; }

# is_mounted: busybox-safe /proc/mounts check [FIX-5].
# Replaces mountpoint(1) which is not present in all busybox builds.
is_mounted() {
    awk -v m="$1" '$2 == m { found=1 } END { exit !found }' /proc/mounts 2>/dev/null
}

# json_str: escape a string for embedding in a JSON double-quoted value.
# Uses tr to convert newlines/tabs to sentinel bytes; sed replaces them.
# Busybox sed does not support \n or \t in s/// replacement strings.
json_str() {
    printf '%s' "$1" \
        | sed 's/\\/\\\\/g; s/"/\\"/g' \
        | tr '\n\t' '\001\002' \
        | sed 's/\001/\\n/g; s/\002/\\t/g'
}

case "$1" in
    list)
        printf '{"status":{},"start":{},"stop":{},"probe":{},"disk_status":{},"get_config":{},"set_config":{"card":"","device":"","mount":""}}\n'
        ;;

    call)
        case "$2" in

            status)
                if is_running; then
                    pid=$(pgrep -f "$RECORDER" | head -n 1)
                    printf '{"running":true,"pid":%s}\n' "$pid"
                else
                    printf '{"running":false,"pid":0}\n'
                fi
                ;;

            start)
                if is_running; then
                    printf '{"result":"already_running"}\n'
                else
                    "$INIT" start >/dev/null 2>&1
                    sleep 2
                    if is_running; then
                        printf '{"result":"started"}\n'
                    else
                        printf '{"result":"failed"}\n'
                    fi
                fi
                ;;

            stop)
                if ! is_running; then
                    printf '{"result":"already_stopped"}\n'
                else
                    "$INIT" stop >/dev/null 2>&1
                    sleep 2
                    if is_running; then
                        printf '{"result":"failed"}\n'
                    else
                        printf '{"result":"stopped"}\n'
                    fi
                fi
                ;;

            probe)
                if is_running; then
                    printf '{"error":"recorder_running","output":""}\n'
                else
                    card=$(uci_get card); card="${card:-0}"
                    dev=$(uci_get device); dev="${dev:-0}"
                    raw=$(arecord -D "hw:${card},${dev}" --dump-hw-params 2>&1)
                    out=$(json_str "$raw")
                    printf '{"error":"","output":"%s"}\n' "$out"
                fi
                ;;

            disk_status)
                mnt=$(uci_get mount); mnt="${mnt:-$MNT_DEFAULT}"
                # [FIX-5] Use /proc/mounts instead of mountpoint(1)
                if is_mounted "$mnt"; then
                    set -- $(df -k "$mnt" | tail -n 1)
                    printf '{"mounted":true,"total_kb":%s,"used_kb":%s,"avail_kb":%s,"mount":"%s"}\n' \
                        "$2" "$3" "$4" "$mnt"
                else
                    printf '{"mounted":false,"total_kb":0,"used_kb":0,"avail_kb":0,"mount":"%s"}\n' "$mnt"
                fi
                ;;

            get_config)
                card=$(uci_get card)
                device=$(uci_get device)
                mount=$(uci_get mount)
                printf '{"card":"%s","device":"%s","mount":"%s"}\n' \
                    "${card:-}" "${device:-}" "${mount:-$MNT_DEFAULT}"
                ;;

            set_config)
                read -r input
                card=$(printf '%s' "$input"       | jsonfilter -e '@.card'   2>/dev/null)
                device=$(printf '%s' "$input"     | jsonfilter -e '@.device' 2>/dev/null)
                mount_path=$(printf '%s' "$input" | jsonfilter -e '@.mount'  2>/dev/null)

                # [FIX-6] Validate mount path: must be absolute if non-empty.
                # Empty string is valid — it means "delete the option" (revert
                # to /tmp/mnt default). A relative path would be written to UCI
                # and silently fail when the recorder tries to use it.
                if [ -n "$mount_path" ]; then
                    case "$mount_path" in
                        /*) ;;  # absolute path — OK
                        *)
                            printf '{"result":"invalid_mount"}\n'
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
                printf '{"result":"ok"}\n'
                ;;

            *)
                printf '{"error":"unknown_method"}\n'
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

// ── RPC declarations ──────────────────────────────────────────────────────────

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

// ── View ──────────────────────────────────────────────────────────────────────

return view.extend({

    load: function() {
        // Each call has its own .catch() so a single transient RPC failure
        // (rpcd still starting, session race on page load) does not cause
        // Promise.all to reject and leave the page blank.
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

        // ── Control buttons ───────────────────────────────────────────────────
        var btnStart = E('button', {
            'class': 'btn cbi-button cbi-button-apply',
            'id':    'ar-btn-start',
            'click': function() { self._doStart(); }
        }, _('Start'));

        var btnStop = E('button', {
            'class': 'btn cbi-button cbi-button-negative',
            'id':    'ar-btn-stop',
            'click': function() { self._doStop(); }
        }, _('Stop'));

        // ── Config inputs ─────────────────────────────────────────────────────
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

        // ── Probe section ─────────────────────────────────────────────────────
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
                     'max-height:320px;overflow-y:auto'
        });

        // ── Page layout ───────────────────────────────────────────────────────
        var page = E('div', { 'class': 'cbi-map' }, [

            E('h2', _('ALSA Recorder')),

            // Section: service status + start/stop
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
                    btnStart, btnStop
                ])
            ]),

            // Section: UCI hardware configuration
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

            // Section: hardware probe
            E('div', { 'class': 'cbi-section' }, [
                E('h3', _('Hardware Probe')),
                E('div', { 'class': 'cbi-section-descr' },
                    _('Dump raw ALSA hardware parameters for the configured card/device ' +
                      '(falls back to hw:0,0 if not configured). ' +
                      'The recorder must be stopped first.')),
                btnProbe,
                probeOutput
            ])
        ]);

        // ── Poll status + disk every 5 s ──────────────────────────────────────
        // [FIX-3] Each call has its own .catch() with a safe fallback value so
        // that a transient rpcd failure (timeout, session expiry) does not
        // reject Promise.all and silently freeze the status/disk display.
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
            });
        }, 5);

        return page;
    },

    // ── Rendering helpers ─────────────────────────────────────────────────────

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

    // ── Button busy state ─────────────────────────────────────────────────────

    _setBusy: function(busy) {
        ['ar-btn-start', 'ar-btn-stop', 'ar-btn-probe',
         'ar-btn-savecfg', 'ar-btn-clearcfg'].forEach(function(id) {
            var el = document.getElementById(id);
            if (el) el.disabled = busy;
        });
    },

    // ── Status badge update helper ────────────────────────────────────────────

    _refreshStatus: function() {
        var self = this;
        return callStatus().catch(function() {
            return { running: false, pid: 0 };
        }).then(function(status) {
            var sc = document.getElementById('ar-status-cell');
            if (sc) dom.content(sc, self._statusBadge(status));
        });
    },

    // ── Action handlers ───────────────────────────────────────────────────────

    // [FIX-2] Inspect res.result and alert on failure.
    // [FIX-4] Immediately refresh the status badge after the action completes
    //         instead of waiting up to 5 s for the next poll cycle.
    _doStart: function() {
        var self = this;
        self._setBusy(true);
        return callStart().then(function(res) {
            if (!res || res.result === 'failed') {
                window.alert(_('Failed to start recorder. Check system logs.'));
            }
        }).catch(function(err) {
            window.alert(_('RPC error: ') + (err.message || String(err)));
        }).then(function() {
            // Immediate badge refresh regardless of action outcome [FIX-4]
            return self._refreshStatus();
        }).then(function() {
            self._setBusy(false);
        });
    },

    // [FIX-2] Same result inspection + immediate refresh for Stop.
    _doStop: function() {
        var self = this;
        self._setBusy(true);
        return callStop().then(function(res) {
            if (!res || res.result === 'failed') {
                window.alert(_('Failed to stop recorder. Check system logs.'));
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
            pre.textContent = (res.error === 'recorder_running')
                ? _('Cannot probe: stop the recorder first.')
                : (res.output || _('(no output)'));
        }).catch(function(err) {
            pre.textContent = _('RPC error: ') + (err.message || String(err));
        }).then(function() { self._setBusy(false); });
    },

    _doSaveConfig: function() {
        var self   = this;
        var card   = (document.getElementById('ar-cfg-card')   || {}).value || '';
        var device = (document.getElementById('ar-cfg-device') || {}).value || '';
        var mount  = (document.getElementById('ar-cfg-mount')  || {}).value || '';

        // Client-side numeric validation for card/device
        if ((card   !== '' && !/^\d+$/.test(card)) ||
            (device !== '' && !/^\d+$/.test(device))) {
            window.alert(_('Card and Device must be numeric (or empty for auto-detect).'));
            return;
        }

        self._setBusy(true);
        return callSetConfig(card, device, mount).then(function(res) {
            // [FIX-7] Check server-side validation result before showing tick
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
                // Should never happen for empty strings, but guard anyway
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

    // Suppress default LuCI save/apply/reset footer — no UCI map here
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
printf "${BOLD}${GREEN}  hALSAmrec v4.5 — Installation complete!${RESET}\n"
printf "${BOLD}${GREEN}============================================${RESET}\n"
printf "\n"
printf "  ${BOLD}LuCI${RESET}   ->  Services -> ALSA Recorder\n"
printf "  ${BOLD}Status${RESET} ->  ubus call autorecorder status\n"
printf "  ${BOLD}Disk${RESET}   ->  ubus call autorecorder disk_status\n"
printf "  ${BOLD}Config${RESET} ->  ubus call autorecorder get_config\n"
printf "\n"
printf "  ${BOLD}Hotplug${RESET} handlers installed:\n"
printf "    /etc/hotplug.d/block/50-autorecorder  (USB storage)\n"
printf "    /etc/hotplug.d/usb/50-autorecorder    (USB audio)\n"
printf "\n"
printf "  ${YELLOW}Note:${RESET} Card/device indices are auto-detected and persisted\n"
printf "  to UCI after the first successful recording cycle.\n"
printf "  Override manually via LuCI or:\n"
printf "    uci set autorecorder.config.card=0\n"
printf "    uci set autorecorder.config.device=0\n"
printf "    uci commit autorecorder\n"
printf "\n"
printf "  ${YELLOW}Note:${RESET} The old /cgi-bin/cm HTTP endpoint is not installed.\n"
printf "  Use ubus for scripted control:\n"
printf "    ubus call autorecorder start\n"
printf "    ubus call autorecorder stop\n"
printf "    ubus call autorecorder probe\n"
printf "\n"
