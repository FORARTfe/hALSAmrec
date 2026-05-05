#!/bin/sh
#
# install-autorecorder.sh — hALSAmrec v4 installer
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
# block-mount provides blkid; kmod-fs-exfat for exFAT kernel support
opkg install alsa-utils kmod-usb-storage block-mount kmod-usb3 kmod-usb-audio usbutils kmod-fs-exfat || \
    ERR "Package installation failed — check feed availability"
OK "Packages installed"

# ── 2. Write runtime files ────────────────────────────────────────────────────
STEP "Writing runtime files"

# ── /usr/sbin/recorder ────────────────────────────────────────────────────────
cat > /usr/sbin/recorder << 'EOF_RECORDER'
#!/bin/sh
#
# Original script by J. Bruce Fields, 2024
# This version (v4) by FORART (https://forart.it/), 2025-26
# GPL v3 — see <https://www.gnu.org/licenses/>
#
# Changes from v3:
#   - Disk detection: blkid primary, dd|grep EXFAT fallback (handles busybox
#     builds where blkid lacks exFAT probe support)
#   - fs_type variable replaces 'type' (avoids shadowing the shell builtin)
#   - UCI-persisted card/device: eliminates arecord -l from the hot loop on
#     stable hardware; auto-persists on first successful detection
#   - Mount point also read from UCI (autorecorder.config.mount)

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
        # Wait on active recorder PID; fall back to sentinel sleep
        wait ${recorder:-$dummy}
    fi

    # Re-read mount point each cycle in case UCI was updated
    MNT=$(uci_get mount)
    MNT="${MNT:-/tmp/mnt}"

    # ── Audio card detection ──────────────────────────────────────────────────
    # Use UCI-persisted card/device if available — skips arecord -l entirely
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
    set -- $(df -k "$MNT" | tail -n 1)
    if [ $(($4 / 1024)) -le 100 ]; then
        umount -l "$MNT"
        sleep 5
        continue
    fi

    # ── Hardware parameter detection ──────────────────────────────────────────
    arecord_out=$(arecord -D "hw:${card_num},${dev_num}" --dump-hw-params 2>&1)

    max_ch=$(printf '%s\n' "$arecord_out" | sed -n 's/^CHANNELS:.*\[\([0-9]*\) \([0-9]*\)\].*/\2/p')
    [ -z "$max_ch" ] && \
        max_ch=$(printf '%s\n' "$arecord_out" | sed -n 's/^CHANNELS:[[:space:]]*\[*\([0-9][0-9]*\).*/\1/p')

    fmt_raw=$(printf '%s\n' "$arecord_out" | sed -n 's/^FORMAT:[[:space:]]*//p' | head -n 1)
    bitfmt="${fmt_raw##* }"

    max_rate=$(printf '%s\n' "$arecord_out" | sed -n 's/^RATE:.*[\[(]\([0-9]*\) \([0-9]*\)[])].*/\2/p')
    [ -z "$max_rate" ] && \
        max_rate=$(printf '%s\n' "$arecord_out" | sed -n 's/^RATE:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
    [ "$max_rate" -gt 48000 ] && max_rate=48000

    buf_time=$(printf '%s\n' "$arecord_out" | sed -n 's/^BUFFER_TIME:.*[\[(]\([0-9]*\) \([0-9]*\)[])].*/\2/p')
    buf_size=$(printf '%s\n' "$arecord_out" | sed -n 's/^BUFFER_SIZE:.*[\[(]\([0-9]*\) \([0-9]*\)[])].*/\2/p')

    # ── Auto-persist detected card/device to UCI ──────────────────────────────
    # Only writes if values are not already stored; subsequent cycles will
    # skip the arecord -l probe entirely until the user clears via LuCI.
    if [ "$card_ready" -eq 1 ] && [ -z "$(uci_get card)" ]; then
        uci -q set autorecorder.config=autorecorder
        uci -q set autorecorder.config.card="$card_num"
        uci -q set autorecorder.config.device="$dev_num"
        uci -q commit autorecorder
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

reload_service() {
    procd_send_signal autorecorder
}
EOF_INIT
OK "/etc/init.d/autorecorder"

# ── /etc/hotplug.d/block/50-autorecorder ─────────────────────────────────────
mkdir -p /etc/hotplug.d/block
cat > /etc/hotplug.d/block/50-autorecorder << 'EOF_HOTPLUG'
#!/bin/sh
service autorecorder reload
EOF_HOTPLUG
OK "/etc/hotplug.d/block/50-autorecorder"

# ── /etc/hotplug.d/usb/50-autorecorder ────────────────────────────────────────
mkdir -p /etc/hotplug.d/usb
cat > /etc/hotplug.d/usb/50-autorecorder << 'EOF_HOTPLUG_USB'
#!/bin/sh
service autorecorder reload
EOF_HOTPLUG_USB
chmod 0755 /etc/hotplug.d/usb/50-autorecorder
OK "/etc/hotplug.d/usb/50-autorecorder"

# ── /usr/libexec/rpcd/autorecorder ───────────────────────────────────────────
mkdir -p /usr/libexec/rpcd
cat > /usr/libexec/rpcd/autorecorder << 'EOF_RPCD'
#!/bin/sh
#
# rpcd shell plugin for hALSAmrec autorecorder
# by FORART (https://forart.it/), 2025-26
# GPL v3 — see <https://www.gnu.org/licenses/>
#
# Methods: status, start, stop, probe, disk_status, get_config, set_config

RECORDER=/usr/sbin/recorder
INIT=/etc/init.d/autorecorder
MNT_DEFAULT=/tmp/mnt

is_running() { pgrep -f "$RECORDER" >/dev/null 2>&1; }

uci_get() { uci -q get "autorecorder.config.$1" 2>/dev/null; }

# Escape a string for embedding in a JSON double-quoted value.
# Uses tr to convert newlines and tabs to unique sentinel bytes, then sed
# replaces the sentinels — busybox sed does not support \n or \t in s///.
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
                if mountpoint -q "$mnt" 2>/dev/null; then
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
        // Each call has its own .catch() so that a single transient RPC failure
        // (rpcd still starting, session race on page load) does not cause
        // Promise.all to reject and leave the page blank. render() always runs.
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
                      'Clear to revert to auto-detection (e.g. after a hardware change). ' +
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
        poll.add(function() {
            return Promise.all([callStatus(), callDiskStatus()]).then(function(results) {
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

    // ── Action handlers ───────────────────────────────────────────────────────

    _doStart: function() {
        var self = this;
        self._setBusy(true);
        return callStart().catch(function(err) {
            window.alert(_('RPC error: ') + (err.message || String(err)));
        }).then(function() { self._setBusy(false); });
    },

    _doStop: function() {
        var self = this;
        self._setBusy(true);
        return callStop().catch(function(err) {
            window.alert(_('RPC error: ') + (err.message || String(err)));
        }).then(function() { self._setBusy(false); });
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

        if ((card !== '' && !/^\d+$/.test(card)) ||
            (device !== '' && !/^\d+$/.test(device))) {
            window.alert(_('Card and Device must be numeric (or empty for auto-detect).'));
            return;
        }

        self._setBusy(true);
        return callSetConfig(card, device, mount).then(function() {
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
        return callSetConfig('', '', '').then(function() {
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
# Written as a plain text file — no uci calls used here.
# A UCI config file is just text; writing it directly avoids the
# "Entry not found" error uci commit emits on 24.x when the package
# does not yet exist on disk. Guard preserves existing runtime settings.
if [ -f /etc/config/autorecorder ]; then
    OK "/etc/config/autorecorder (already exists — preserving settings)"
else
    cat > /etc/config/autorecorder << 'EOF_UCI'
config autorecorder 'config'
	option card ''
	option device ''
	option mount '/tmp/mnt'
EOF_UCI
    OK "/etc/config/autorecorder"
fi

# ── 3. Permissions ────────────────────────────────────────────────────────────
STEP "Setting permissions"
chmod 0755 /usr/sbin/recorder
chmod 0755 /etc/init.d/autorecorder
chmod 0755 /etc/hotplug.d/block/50-autorecorder
chmod 0755 /usr/libexec/rpcd/autorecorder
chmod 0644 /www/luci-static/resources/view/autorecorder/main.js
chmod 0644 /usr/share/luci/menu.d/autorecorder.json
chmod 0644 /usr/share/rpcd/acl.d/autorecorder.json
chmod 0644 /etc/config/autorecorder
OK "Permissions set"

# ── 4. Enable and start service ───────────────────────────────────────────────
STEP "Enabling and starting autorecorder service"
/etc/init.d/autorecorder enable
OK "Autorecorder enabled (starts on boot)"
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
printf "${BOLD}${GREEN}  Installation complete!${RESET}\n"
printf "${BOLD}${GREEN}============================================${RESET}\n"
printf "\n"
printf "  ${BOLD}LuCI${RESET}   ->  Services -> ALSA Recorder\n"
printf "  ${BOLD}Status${RESET} ->  ubus call autorecorder status\n"
printf "  ${BOLD}Disk${RESET}   ->  ubus call autorecorder disk_status\n"
printf "  ${BOLD}Config${RESET} ->  ubus call autorecorder get_config\n"
printf "\n"
printf "  ${YELLOW}Note:${RESET} Card/device indices are auto-detected and persisted\n"
printf "  to UCI after the first successful recording cycle.\n"
printf "  Override manually via LuCI or:\n"
printf "    uci set autorecorder.config.card=0\n"
printf "    uci set autorecorder.config.device=0\n"
printf "    uci commit autorecorder\n"
printf "\n"
