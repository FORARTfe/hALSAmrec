#!/bin/sh
#
# hALSAmrec LuCI/CGI installer — v5.2-luci-cgi-compatible-fixed
# Compatible with OpenWrt 21.02+ using /bin/sh.
#
# Changes from v5.1 (comprehensive code review and bug-fix pass):
#
#   [FIX-1] hotplug/block: Add ACTION filter; only react to add and remove.
#            The v5.1 handler fired on every kernel block event (bind, unbind,
#            change, etc.) unconditionally, causing spurious SIGHUP storms that
#            woke the recorder loop for events completely unrelated to storage.
#
#   [FIX-2] hotplug/block add: Insert sleep 1 before waking the recorder loop.
#            Kernel block device events fire before the device node is fully
#            initialised and mountable.  Without a brief delay, the recorder
#            loop wakes up, finds the device visible in /proc/partitions but
#            fails the exFAT signature check or mount call, falls back to
#            `wait $dummy`, and then sleeps indefinitely — never mounting the
#            newly inserted disk.  The sleep gives the kernel and mdev/udev
#            time to complete device initialisation.
#
#   [FIX-3] hotplug/usb: Add ACTION filter (add/remove only) and sleep 1.
#            USB audio interface events fire before ALSA has registered the
#            capture device.  Without the delay, `arecord -l` finds nothing,
#            the recorder returns to `wait $dummy`, and recording never starts
#            even though the audio interface arrived successfully.
#
#   [FIX-4] recorder: Partition-only scanning in find_single_exfat_partition.
#            The v5.1 case pattern (sd*|mmcblk*|nvme*) matched whole-disk nodes
#            (e.g. /dev/sda) as well as partitions (/dev/sda1).  Reading bytes
#            3-7 of a whole-disk MBR never yields "EXFAT", so true exFAT
#            partitions were counted alongside their whole-disk parent, making
#            exfat_count=2 even for a single USB drive, and the recorder always
#            treated the result as ambiguous and refused to mount.  Fixed by
#            restricting the pattern to partition-only names (trailing digit for
#            sdX, pN suffix for mmcblk and nvme).
#
#   [FIX-5] recorder: Don't unmount when arecord exits naturally.
#            When arecord exits on its own (disk full, I/O error, ALSA glitch),
#            v5.1 called cleanup_mount, unmounting the disk and then immediately
#            remounting it at the start of the next iteration — pointless I/O
#            with a mount-race window.  Now the stale-PID handler only clears
#            the `recorder` variable; the disk stays mounted so the next
#            recording starts directly without a remount cycle.
#
#   [FIX-6] recorder: Don't unmount when the audio card disappears.
#            v5.1 combined the disk-absent and card-absent guards into one block
#            that always called cleanup_mount.  When the audio interface was
#            momentarily reset (USB glitch, driver reload) while the storage
#            disk was healthy, this caused an unnecessary unmount-remount cycle.
#            Now the two cases are separated: disk absent → stop + unmount;
#            audio absent → stop recorder only, disk stays mounted.
#
#   [FIX-7] recorder + autorecorderctl + rpcd: arecord --dump-hw-params
#            pipe-fill deadlock.
#            arecord invoked with --dump-hw-params and no explicit output file
#            writes raw PCM audio frames to stdout.  Inside a $() subshell,
#            stdout is a pipe; the pipe buffer fills (~64 KB), arecord blocks on
#            write(), and the subshell hangs indefinitely.  In the recorder this
#            delays every recording-start by many seconds until SIGPIPE fires.
#            In autorecorderctl PROBE (called from the rpcd plugin), the hang
#            causes rpcd's watchdog to kill the plugin, returning empty JSON →
#            LuCI shows "(no output)".  Fixed in all three locations by adding
#            -d 1 (1-second recording limit) and /dev/null (explicit output file
#            so audio is discarded rather than written to the pipe).
#
#   [FIX-8] recorder: --buffer-time and --buffer-size are mutually exclusive.
#            arecord rejects commands that specify both flags simultaneously.
#            v5.1 passed both when both were detected from --dump-hw-params,
#            causing arecord to exit immediately on many devices.  Fixed by
#            dropping --buffer-size entirely and only passing --buffer-time.
#
#   [FIX-9] autorecorderctl START/STOP: Replace fixed sleep 2 with retry loop.
#            A 2-second fixed sleep is insufficient on loaded routers where procd
#            may take longer to spawn or reap the recorder process.  Replaced
#            with a 5-iteration 1-second poll loop matching v4.8 FIX-K.
#
#   [FIX-10] LuCI JS: Null-guard all accesses to callStatus() return value.
#             If the RPC resolves with null or undefined (session race on page
#             load), `data.running` throws TypeError inside .then(), bypassing
#             the .catch() handler on older Promise implementations and leaving
#             the badge stuck on "Unknown".
#
#   [FIX-11] LuCI JS: Suppress LuCI Save/Apply/Reset footer buttons.
#             Without handleSaveApply: null, LuCI renders its default form
#             footer buttons below the custom view, which have no backing UCI
#             map and do nothing when clicked.
#
#   [FIX-12] installer: Explicitly grant luci-app-autorecorder to rpcd root
#             login (port of v4.7 FIX-V).
#             In OpenWrt 21.x/22.x, the "list read '*'" wildcard in
#             /etc/config/rpcd applies grants loaded at session-creation time.
#             A newly installed ACL file is not visible to existing sessions.
#             Explicitly naming the group in the root login section ensures
#             new sessions (after logout/login) carry the correct grant.
#
#   [FIX-13] installer: Prominent mandatory logout/login warning box.
#             rpcd restart destroys all in-memory sessions.  The browser-side
#             cookie becomes invalid; all subsequent ubus calls return
#             PERMISSION_DENIED, which older LuCI silently maps to RPC defaults
#             rather than rejecting the Promise.  All three failure symptoms
#             (Stopped / Not mounted / no output) persist until the user logs
#             out and back in.

set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin

APP_NAME="hALSAmrec"
VERSION="5.2-luci-cgi-compatible-fixed"

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
    for pkg in rpcd luci-base alsa-utils kmod-fs-exfat jsonfilter; do
        if ! opkg list-installed "$pkg" 2>/dev/null | grep -q "^$pkg[[:space:]-]"; then
            missing="$missing $pkg"
        fi
    done

    if [ -n "$missing" ]; then
        info "Installing missing packages:$missing"
        opkg update || warn "opkg update failed; trying installation anyway."
        # Do not abort the whole installer: devices may already have equivalent packages.
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

# =============================================================================
# 1. Recorder daemon
# =============================================================================
info "Installing recorder daemon..."
cat > /usr/sbin/recorder <<'EOF_RECORDER'
#!/bin/sh
#
# hALSAmrec recorder daemon — v5.2
# Original script by J. Bruce Fields, 2024
# This version by FORART, 2025-26. GPL v3.
#
# Architecture: persistent supervisor loop. The recording disk is mounted once
# and kept mounted for the lifetime of the service. arecord is a child process;
# its natural exit never triggers an unmount. The disk is only unmounted when
# it is physically removed or SIGTERM is received.

PATH=/usr/sbin:/usr/bin:/sbin:/bin
MNT=/tmp/mnt
recorder=""
dummy=""

# SIGHUP handler: wakes wait() only; does not stop the recorder or unmount.
# Sent by procd reload_service() on hotplug events.
on_hup() { :; }

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

trap on_hup  HUP
trap on_term INT TERM

# Long-running dummy process: gives wait() something to block on between
# recording sessions.  BusyBox sleep does not reliably support "infinity"
# on all OpenWrt builds, so use the maximum 32-bit signed integer.
sleep 2147483647 &
dummy=$!

# [FIX-4] find_single_exfat_partition: match partition-only device names.
# Pattern explanation:
#   sd*[0-9]      → sda1, sdb2, etc.   (NOT sda, sdb whole-disk nodes)
#   mmcblk*p[0-9]* → mmcblk0p1, etc.
#   nvme*p[0-9]*   → nvme0n1p1, etc.
# Whole-disk nodes (sda, mmcblk0) expose the MBR/GPT header at offset 3,
# not the exFAT OEM ID, so they produce false negatives and inflate the
# exfat_count, causing a single USB drive to appear as two candidates.
find_single_exfat_partition() {
    _count=0
    _found=""

    while read -r _maj _min _blocks _name _rest; do
        case "$_name" in
            sd*[0-9] | mmcblk*p[0-9]* | nvme*p[0-9]*) ;;
            *) continue ;;
        esac

        _dev="/dev/$_name"
        [ -b "$_dev" ] || continue

        # exFAT superblock: bytes 3-7 are the OEM name "EXFAT" (5 bytes).
        if dd if="$_dev" bs=1 skip=3 count=5 2>/dev/null \
                | grep -q 'EXFAT'; then
            _count=$((_count + 1))
            _found="$_dev"
        fi
    done < /proc/partitions

    # Require exactly one exFAT partition — multiple disks are ambiguous.
    [ "$_count" -eq 1 ] && printf '%s\n' "$_found"
}

find_audio_line() {
    arecord -l 2>/dev/null | grep '^card ' | head -n 1
}

last_number_from_line() {
    _label=$1
    printf '%s\n' "$arecord_out" |
        awk -v label="$_label" '
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
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
}

first=1
while :; do
    if [ "$first" -eq 1 ]; then
        first=0
    else
        # Block until the recorder child (or dummy) exits or SIGHUP arrives.
        wait "${recorder:-$dummy}" 2>/dev/null || true
    fi

    card_line=$(find_audio_line || true)
    disk=$(find_single_exfat_partition || true)

    # ── [FIX-5] Stale recorder PID: arecord exited naturally. ─────────────────
    # Clear the PID only — do NOT unmount.  The disk stays mounted so the
    # next recording cycle can start immediately without a remount.  v5.1
    # called cleanup_mount here, causing a pointless unmount-remount loop
    # every time arecord exited due to disk-full or an encoding error.
    if [ -n "${recorder:-}" ] && [ ! -e "/proc/$recorder" ]; then
        recorder=""
    fi

    # ── [FIX-6] Disk physically absent: stop recording and unmount. ────────────
    if [ -z "$disk" ]; then
        cleanup_recorder
        cleanup_mount
        continue
    fi

    # ── [FIX-6] Audio card absent but disk is healthy: stop recording only. ────
    # Keep the disk mounted so recording resumes immediately (without a
    # remount cycle) when the audio interface comes back.  v5.1 combined this
    # branch with the disk-absent branch and always called cleanup_mount.
    if [ -z "$card_line" ]; then
        cleanup_recorder
        continue
    fi

    # Both disk and audio card present; recorder is already running — nothing to do.
    [ -n "${recorder:-}" ] && continue

    # ── Mount disk if not yet mounted ────────────────────────────────────────────
    mkdir -p "$MNT"
    if ! grep -qs " $MNT " /proc/mounts; then
        mount "$disk" "$MNT" 2>/dev/null || continue
    fi

    # ── Disk space check: require at least 100 MB free ──────────────────────────
    avail_kb=$(df -k "$MNT" 2>/dev/null | awk 'NR==2{print $4+0}')
    if [ "${avail_kb:-0}" -le 102400 ]; then
        # Don't unmount — check again after the next hotplug event.
        sleep 5
        continue
    fi

    # ── Parse ALSA card/device numbers ──────────────────────────────────────────
    card_num=${card_line#card }; card_num=${card_num%%:*}
    dev_num=${card_line##*device }; dev_num=${dev_num%%:*}

    if ! valid_uint "$card_num" || ! valid_uint "$dev_num"; then
        sleep 5
        continue
    fi

    # ── [FIX-7] Hardware parameter detection — pipe-fill deadlock fix. ──────────
    # Without an explicit output file, arecord writes raw PCM to stdout (the
    # $() pipe).  The pipe buffer fills (~64 KB), arecord blocks on write(),
    # and this subshell hangs until SIGPIPE fires — delaying every recording
    # start.  Fix: -d 1 limits the session to 1 second; /dev/null discards the
    # audio; 2>&1 captures the hw-param text from stderr.
    arecord_out=$(arecord -D "hw:${card_num},${dev_num}" \
        --dump-hw-params -d 1 /dev/null 2>&1 || true)

    max_ch=$(last_number_from_line CHANNELS)
    bitfmt=$(format_from_dump)
    max_rate=$(last_number_from_line RATE)
    buf_time=$(last_number_from_line BUFFER_TIME)

    valid_uint "$max_ch"   || max_ch=1
    [ -n "$bitfmt" ]       || bitfmt=S16_LE
    valid_uint "$max_rate" || max_rate=48000
    [ "$max_rate" -gt 48000 ] && max_rate=48000

    # ── [FIX-8] Build arecord command — buffer-size intentionally omitted. ──────
    # --buffer-time and --buffer-size are mutually exclusive in arecord.
    # Passing both causes arecord to exit immediately on most devices.
    # Only --buffer-time is passed when detected; --buffer-size is dropped.
    set -- arecord \
        "--device=hw:${card_num},${dev_num}" \
        "--channels=$max_ch" \
        "--file-type=raw" \
        "--format=$bitfmt" \
        "--rate=$max_rate"
    valid_uint "$buf_time" && set -- "$@" "--buffer-time=$buf_time"

    outfile="${MNT}/$(date +%s)_${max_ch}-${max_rate}-${bitfmt}.raw"
    "$@" > "$outfile" 2>/dev/null &
    recorder=$!
done
EOF_RECORDER
chmod 0755 /usr/sbin/recorder

# =============================================================================
# 2. Shared control CLI (used by both CGI and rpcd)
# =============================================================================
info "Installing control CLI..."
cat > /usr/sbin/autorecorderctl <<'EOF_CTL'
#!/bin/sh
# hALSAmrec control helper: START, STOP, STATUS, PROBE.
# Used by both the CGI endpoint and the rpcd LuCI backend so command
# semantics are identical regardless of how the UI is accessed.

PATH=/usr/sbin:/usr/bin:/sbin:/bin
RECORDER=/usr/sbin/recorder
INIT=/etc/init.d/autorecorder

# find_pids: return PIDs of running recorder processes.
# Tries pgrep -f first (fast); falls back to /proc scan for BusyBox builds
# that omit -f support.  Both methods search the full cmdline so that the
# /bin/sh interpreter started by procd (whose argv[0] is the shebang
# interpreter, not the script name) is still detected.
find_pids() {
    if command -v pgrep >/dev/null 2>&1; then
        pgrep -f "$RECORDER" 2>/dev/null || true
        return 0
    fi
    for _proc in /proc/[0-9]*; do
        [ -r "$_proc/cmdline" ] || continue
        _cmd=$(tr '\000' ' ' < "$_proc/cmdline" 2>/dev/null || true)
        case "$_cmd" in
            *"$RECORDER"*) printf '%s\n' "${_proc#/proc/}" ;;
        esac
    done
}

pid_list() {
    find_pids | awk 'NF { printf "%s%s", sep, $1; sep=" " } END { print "" }'
}

is_running() {
    [ -n "$(pid_list)" ]
}

# [FIX-7] probe_device: add -d 1 /dev/null to prevent pipe-fill deadlock.
# Without an explicit output file, arecord writes raw PCM to stdout.
# Inside $(), stdout is a pipe; the pipe buffer fills, arecord blocks, and
# this function never returns — causing the rpcd watchdog to kill the plugin
# and LuCI to show "(no output)".  Fix: -d 1 limits to 1 second; /dev/null
# discards the audio; 2>&1 captures hw params from stderr.
probe_device() {
    _card_line=$(arecord -l 2>/dev/null | grep '^card ' | head -n 1 || true)
    if [ -z "$_card_line" ]; then
        echo "No ALSA capture device found"
        return 1
    fi

    _card_num=${_card_line#card }; _card_num=${_card_num%%:*}
    _dev_num=${_card_line##*device }; _dev_num=${_dev_num%%:*}

    case "${_card_num}:${_dev_num}" in
        *[!0-9:]*|:*|*:)
            echo "Could not parse ALSA device from: $_card_line"
            return 1
            ;;
    esac

    arecord -D "hw:${_card_num},${_dev_num}" \
        --dump-hw-params -d 1 /dev/null 2>&1
}

cmd=$(printf '%s' "${1:-}" | tr '[:lower:]' '[:upper:]')

case "$cmd" in
    START)
        if is_running; then
            echo "Already running"
            exit 0
        fi
        "$INIT" start >/dev/null 2>&1 || true
        # [FIX-9] Retry loop replaces fixed sleep 2.
        # 2 s is insufficient on loaded routers where procd may take longer
        # to spawn the supervisor process.  Poll for up to 5 s instead.
        i=0
        while [ "$i" -lt 5 ]; do
            sleep 1
            is_running && break
            i=$((i + 1))
        done
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
        # [FIX-9] Same retry logic for stop.
        i=0
        while [ "$i" -lt 5 ]; do
            sleep 1
            ! is_running && break
            i=$((i + 1))
        done
        if ! is_running; then
            echo "Stopped successfully"
            exit 0
        fi
        echo "Failed to stop"
        exit 1
        ;;

    STATUS)
        _pids=$(pid_list)
        if [ -n "$_pids" ]; then
            echo "RUNNING (PID: $_pids)"
        else
            echo "STOPPED"
        fi
        exit 0
        ;;

    PROBE)
        if is_running; then
            echo "WARNING: recorder is running — stop it before probing hardware."
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

# =============================================================================
# 3. Init script
# =============================================================================
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
    # Respawn up to 5 times per hour with a 5-second cooldown.
    # Without this procd does not restart the supervisor on unexpected exit.
    procd_set_param respawn 3600 5 5
    procd_close_instance
}

reload_service() {
    # Sends SIGHUP; the recorder loop wakes and re-checks audio/storage state
    # without interrupting an in-progress recording.
    procd_send_signal autorecorder
}
EOF_INIT
chmod 0755 /etc/init.d/autorecorder

# =============================================================================
# 4. Hotplug handlers
# =============================================================================
info "Installing hotplug handlers..."

# [FIX-1][FIX-2] block hotplug: filter by ACTION; delay on add.
#
# v5.1 problems:
#  (a) No ACTION check → fired on bind, unbind, change, move, etc., causing
#      constant spurious SIGHUP storms that woke the recorder for events
#      unrelated to storage insertion or removal.
#  (b) No delay on add → the recorder loop woke up before the kernel had
#      finished initialising the block device.  find_single_exfat_partition
#      either missed the device or found it un-mountable, fell through to
#      `continue`, and then blocked on `wait $dummy` — never retrying because
#      no further hotplug events arrived.
#
# Fix: react only to add and remove; insert sleep 1 on add to let the kernel
# complete device initialisation (partition table parse, mdev/udev rules) and
# make the device mountable before the recorder loop tries to use it.
cat > /etc/hotplug.d/block/49-autorecorder <<'EOF_HOTPLUG_BLOCK'
#!/bin/sh
case "${ACTION:-}" in
    add)
        # Wait for the kernel to finish initialising the block device
        # before waking the recorder loop.  Without this delay, the
        # exFAT signature check and mount call race the device setup and
        # silently fail, leaving the recorder stuck in wait() forever.
        sleep 1
        service autorecorder reload
        ;;
    remove)
        service autorecorder reload
        ;;
esac
EOF_HOTPLUG_BLOCK
chmod 0755 /etc/hotplug.d/block/49-autorecorder

# [FIX-3] usb hotplug: filter by ACTION; delay on add.
#
# v5.1 problems:
#  (a) No ACTION check → fired on every USB event including keyboards, mice,
#      hubs, etc., waking the recorder unnecessarily.
#  (b) No delay on add → arecord -l ran before the ALSA driver had registered
#      the USB audio capture device, found nothing, and the recorder went back
#      to sleep, never starting even though the device arrived successfully.
cat > /etc/hotplug.d/usb/49-autorecorder <<'EOF_HOTPLUG_USB'
#!/bin/sh
case "${ACTION:-}" in
    add)
        # Wait for the ALSA driver to register the USB audio interface
        # before running arecord -l.  Without this delay, the capture
        # device is not yet visible and find_audio_line returns empty,
        # causing the recorder to sleep until the next hotplug event.
        sleep 1
        service autorecorder reload
        ;;
    remove)
        service autorecorder reload
        ;;
esac
EOF_HOTPLUG_USB
chmod 0755 /etc/hotplug.d/usb/49-autorecorder

# =============================================================================
# 5. CGI endpoint (unchanged from v5.1)
# =============================================================================
info "Installing CGI endpoint..."
cat > /www/cgi-bin/cm <<'EOF_CGI'
#!/bin/sh
# hALSAmrec CGI control endpoint.
# Proxies /cgi-bin/cm?cmnd=START|STOP|STATUS|PROBE to autorecorderctl.

PATH=/usr/sbin:/usr/bin:/sbin:/bin
CTL=/usr/sbin/autorecorderctl

printf 'Content-type: text/plain\r\n\r\n'

[ "${REQUEST_METHOD:-}" = "GET" ] || {
    printf 'Error: Method not allowed\n'
    exit 1
}
[ -n "${QUERY_STRING:-}" ] || {
    printf 'Usage: /cgi-bin/cm?cmnd=START|STOP|STATUS|PROBE\n'
    exit 0
}

get_param() {
    _key=$1
    _qs=${QUERY_STRING:-}
    while [ -n "$_qs" ]; do
        _pair=${_qs%%&*}
        [ "$_pair" = "$_qs" ] && _qs="" || _qs=${_qs#*&}
        _name=${_pair%%=*}
        _value=${_pair#*=}
        [ "$_name" = "$_key" ] && { printf '%s' "$_value"; return 0; }
    done
    return 1
}

CMND=$(get_param cmnd 2>/dev/null | tr '[:lower:]' '[:upper:]' || true)

case "$CMND" in
    START|STOP|STATUS|PROBE)
        "$CTL" "$CMND"
        ;;
    *)
        printf 'Unknown command: %s\nValid: START, STOP, STATUS, PROBE\n' "$CMND"
        ;;
esac
EOF_CGI
chmod 0755 /www/cgi-bin/cm
ln -sf /www/cgi-bin/cm /www/cgi-bin/controlweb_cgi

# =============================================================================
# 6. rpcd backend for LuCI
# =============================================================================
info "Installing rpcd backend..."
cat > /usr/libexec/rpcd/autorecorder <<'EOF_RPCD'
#!/bin/sh
# hALSAmrec rpcd plugin — v5.2
# Implements the list/call protocol expected by OpenWrt rpcd for executables
# in /usr/libexec/rpcd/.  Uses jshn for safe JSON serialisation.

PATH=/usr/sbin:/usr/bin:/sbin:/bin
CTL=/usr/sbin/autorecorderctl
RECORDER=/usr/sbin/recorder

. /usr/share/libubox/jshn.sh

# find_pids / pid_list: duplicated from autorecorderctl so status can be
# checked synchronously without forking a subshell for every poll cycle.
find_pids() {
    if command -v pgrep >/dev/null 2>&1; then
        pgrep -f "$RECORDER" 2>/dev/null || true
        return 0
    fi
    for _proc in /proc/[0-9]*; do
        [ -r "$_proc/cmdline" ] || continue
        _cmd=$(tr '\000' ' ' < "$_proc/cmdline" 2>/dev/null || true)
        case "$_cmd" in
            *"$RECORDER"*) printf '%s\n' "${_proc#/proc/}" ;;
        esac
    done
}

pid_list() {
    find_pids | awk 'NF { printf "%s%s", sep, $1; sep=" " } END { print "" }'
}

reply_status() {
    _pids=$(pid_list)
    json_init
    if [ -n "$_pids" ]; then
        json_add_boolean running 1
        json_add_string  status  "RUNNING"
        json_add_string  pid     "$_pids"
        json_add_string  text    "RUNNING (PID: $_pids)"
    else
        json_add_boolean running 0
        json_add_string  status  "STOPPED"
        json_add_string  pid     ""
        json_add_string  text    "STOPPED"
    fi
    json_dump
}

reply_command() {
    _cmd=$1
    _output=$("$CTL" "$_cmd" 2>&1) || true
    _rc=$?
    _pids=$(pid_list)

    json_init
    [ "$_rc" -eq 0 ] \
        && json_add_boolean success 1 \
        || json_add_boolean success 0
    [ -n "$_pids" ] \
        && json_add_boolean running 1 \
        || json_add_boolean running 0
    json_add_string message "$_output"
    json_add_string pid     "$_pids"
    json_dump
}

reply_probe() {
    # [FIX-7] The blocking fix is inside autorecorderctl probe_device.
    # This call will now return within ~3 seconds at most.
    _output=$("$CTL" PROBE 2>&1) || true
    _rc=$?

    json_init
    [ "$_rc" -eq 0 ] \
        && json_add_boolean success 1 \
        || json_add_boolean success 0
    json_add_string message "$_output"
    json_add_string output  "$_output"
    json_dump
}

case "${1:-}" in
    list)
        printf '{"status":{},"start":{},"stop":{},"probe":{}}\n'
        ;;
    call)
        case "${2:-}" in
            status) reply_status   ;;
            start)  reply_command START ;;
            stop)   reply_command STOP  ;;
            probe)  reply_probe    ;;
            *)
                json_init
                json_add_boolean success 0
                json_add_string  error   "Unknown method: ${2:-}"
                json_dump
                ;;
        esac
        ;;
    *)
        printf 'Usage: %s list|call <method>\n' "$0" >&2
        exit 1
        ;;
esac
EOF_RPCD
chmod 0755 /usr/libexec/rpcd/autorecorder

# =============================================================================
# 7. LuCI frontend
# =============================================================================
info "Installing LuCI frontend..."
cat > /www/luci-static/resources/view/autorecorder/main.js <<'EOF_LUCI_JS'
'use strict';
'require view';
'require rpc';
'require poll';
'require ui';

var callStatus = rpc.declare({ object: 'autorecorder', method: 'status' });
var callStart  = rpc.declare({ object: 'autorecorder', method: 'start'  });
var callStop   = rpc.declare({ object: 'autorecorder', method: 'stop'   });
var callProbe  = rpc.declare({ object: 'autorecorder', method: 'probe'  });

return view.extend({

    render: function() {
        var self = this;

        var statusBadge = E('span', { 'class': 'badge' }, _('Unknown'));
        var statusText  = E('pre',  {
            'style': 'white-space:pre-wrap;margin-top:1em;'
        }, _('Loading\u2026'));
        var probeOutput = E('pre',  {
            'style': 'white-space:pre-wrap;margin-top:1em;display:none;'
        });
        var buttons = [];

        function setBadge(running, label) {
            statusBadge.textContent       = label || (running ? _('RUNNING') : _('STOPPED'));
            statusBadge.style.color           = '#fff';
            statusBadge.style.padding         = '2px 8px';
            statusBadge.style.borderRadius    = '3px';
            statusBadge.style.backgroundColor = running ? '#37a237' : '#a93737';
        }

        // [FIX-10] Null-guard all accesses to `data`.
        // If the RPC resolves with null or undefined (session race on page
        // load, rpcd not yet started, or ACL not yet granted), accessing
        // data.running without a guard throws TypeError inside .then(),
        // bypassing the .catch() handler and leaving the badge on "Unknown".
        function refreshStatus() {
            return callStatus().then(function(data) {
                var running = !!(data && data.running);
                setBadge(
                    running,
                    (data && data.status) || (running ? _('RUNNING') : _('STOPPED'))
                );
                statusText.textContent =
                    (data && data.text) || (running ? _('RUNNING') : _('STOPPED'));
            }).catch(function(err) {
                setBadge(false, _('ERROR'));
                statusText.textContent =
                    _('Unable to read recorder status: ') + (err.message || String(err));
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
                // Null-guard: res may be null on RPC failure
                var msg     = (res && res.message) || doneMessage;
                var success = !(res && res.success === false);
                ui.addNotification(
                    null,
                    E('p', {}, msg),
                    success ? 'info' : 'warning'
                );
                if (showProbe) {
                    probeOutput.style.display = '';
                    probeOutput.textContent   = (res && res.output) || msg;
                }
                return refreshStatus();
            }).catch(function(err) {
                ui.addNotification(
                    null,
                    E('p', {}, _('Command failed: ') + (err.message || String(err))),
                    'danger'
                );
            }).then(function() {
                setButtonsDisabled(false);
            });
        }

        buttons.push(E('button', {
            'class': 'btn cbi-button cbi-button-apply',
            'click': function(ev) {
                ev.preventDefault();
                return runCommand(callStart, _('Start command sent'), false);
            }
        }, _('START')));

        buttons.push(E('button', {
            'class': 'btn cbi-button cbi-button-negative',
            'style': 'margin-left:.5em',
            'click': function(ev) {
                ev.preventDefault();
                return runCommand(callStop, _('Stop command sent'), false);
            }
        }, _('STOP')));

        buttons.push(E('button', {
            'class': 'btn cbi-button cbi-button-neutral',
            'style': 'margin-left:.5em',
            'click': function(ev) {
                ev.preventDefault();
                return runCommand(callProbe, _('Probe completed'), true);
            }
        }, _('PROBE')));

        // Initial status fetch; errors are handled inside refreshStatus.
        refreshStatus();

        // Live 5-second poll; null-guard is inside refreshStatus.
        poll.add(refreshStatus, 5);

        return E('div', { 'class': 'cbi-map' }, [
            E('h2', {}, _('hALSAmrec')),
            E('div', { 'class': 'cbi-map-descr' }, _(
                'Control the autorecorder daemon. ' +
                'Exposes the same START, STOP, STATUS and PROBE functions ' +
                'as the CGI endpoint (/cgi-bin/cm?cmnd=\u2026).'
            )),
            E('div', { 'class': 'cbi-section' }, [
                E('h3', {}, _('Status')),
                statusBadge,
                statusText,
                E('div', { 'style': 'margin-top:1em' }, buttons),
                probeOutput
            ])
        ]);
    },

    // [FIX-11] Suppress LuCI Save/Apply/Reset footer buttons.
    // Without these null overrides, LuCI renders its default form footer
    // below the view.  The buttons have no backing UCI map and do nothing
    // when clicked, but they confuse users into thinking there is a form
    // that needs saving.
    handleSaveApply: null,
    handleSave:      null,
    handleReset:     null
});
EOF_LUCI_JS
chmod 0644 /www/luci-static/resources/view/autorecorder/main.js

# =============================================================================
# 8. LuCI menu and ACL
# =============================================================================
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

# =============================================================================
# 9. Activate services
# =============================================================================
info "Enabling and starting autorecorder..."
/etc/init.d/autorecorder enable  >/dev/null 2>&1 || warn "Could not enable autorecorder"
/etc/init.d/autorecorder restart >/dev/null 2>&1 \
    || /etc/init.d/autorecorder start >/dev/null 2>&1 \
    || warn "Could not start autorecorder"

info "Restarting rpcd..."
/etc/init.d/rpcd restart >/dev/null 2>&1 \
    || service rpcd restart >/dev/null 2>&1 \
    || warn "Could not restart rpcd; run: /etc/init.d/rpcd restart"

# Give rpcd a moment to load ACL files and register plugins.
sleep 2

if ubus list autorecorder >/dev/null 2>&1; then
    info "rpcd plugin registered — ubus list autorecorder: OK"
else
    warn "autorecorder ubus object not found after rpcd restart."
    warn "Diagnose with:"
    warn "  sh -n /usr/libexec/rpcd/autorecorder          # syntax check"
    warn "  /usr/libexec/rpcd/autorecorder list           # must output valid JSON"
    warn "  /etc/init.d/rpcd restart && ubus list autorecorder"
fi

if ! command -v arecord >/dev/null 2>&1; then
    warn "arecord not available — install alsa-utils before using the recorder."
fi

# =============================================================================
# [FIX-12] Grant luci-app-autorecorder to the rpcd root login session.
# =============================================================================
# In OpenWrt 21.x/22.x, "list read '*'" in /etc/config/rpcd grants ACL groups
# that were loaded at session-creation time.  A newly installed ACL file is
# not visible to existing sessions; only sessions created after an rpcd restart
# AND a fresh login will carry the new grant.  Explicitly naming the group in
# the root login section makes the install idempotent and correct on all
# supported versions.
info "Granting luci-app-autorecorder to rpcd root user..."
_rs=$(uci show rpcd 2>/dev/null \
    | grep -F ".username='root'" \
    | sed "s/\\.username=.*//" \
    | head -1 || true)
if [ -n "$_rs" ]; then
    # del_list first to prevent duplicate entries on re-install.
    uci -q del_list "${_rs}.read=luci-app-autorecorder"  2>/dev/null || true
    uci -q del_list "${_rs}.write=luci-app-autorecorder" 2>/dev/null || true
    uci -q add_list "${_rs}.read=luci-app-autorecorder"
    uci -q add_list "${_rs}.write=luci-app-autorecorder"
    uci -q commit rpcd
    info "rpcd: luci-app-autorecorder granted to root (section ${_rs})"
else
    warn "rpcd root login section not found in /etc/config/rpcd."
    warn "Grant manually after install:"
    warn "  uci add_list rpcd.@login[0].read=luci-app-autorecorder"
    warn "  uci add_list rpcd.@login[0].write=luci-app-autorecorder"
    warn "  uci commit rpcd && /etc/init.d/rpcd restart"
fi

# Clear LuCI caches so the new menu entry and view are picked up immediately.
rm -f /tmp/luci-indexcache* /tmp/luci-modulecache* 2>/dev/null || true

# =============================================================================
# Done
# =============================================================================
cat <<'EOF_DONE'

==========================================
 hALSAmrec v5.2 — Installation complete
==========================================

LuCI:    System -> hALSAmrec
CGI:     /cgi-bin/cm?cmnd=START|STOP|STATUS|PROBE
CLI:     /usr/sbin/autorecorderctl START|STOP|STATUS|PROBE
Daemon:  /etc/init.d/autorecorder start|stop|reload|status
Storage: exactly one exFAT partition required
Output:  /tmp/mnt/<epoch>_<channels>-<rate>-<format>.raw

Quick diagnostics:
  ubus call autorecorder status
  ubus call autorecorder probe
  /usr/sbin/autorecorderctl STATUS

v5.2 fixes applied:
  [1-3]  Hotplug: ACTION filter + sleep 1 on add (block + usb)
  [4]    Recorder: partition-only /proc/partitions scan
  [5-6]  Recorder: cleanup_mount only on disk removal, not arecord exit/audio loss
  [7]    Recorder + CTL + rpcd: arecord --dump-hw-params -d 1 /dev/null
  [8]    Recorder: --buffer-size dropped (mutually exclusive with --buffer-time)
  [9]    autorecorderctl: START/STOP retry loop replaces fixed sleep 2
  [10]   LuCI: null guards on callStatus() return value
  [11]   LuCI: handleSaveApply/Save/Reset set to null
  [12]   Installer: explicit rpcd ACL grant to root login
  [13]   Installer: mandatory logout/login warning (below)

EOF_DONE

# =============================================================================
# [FIX-13] Mandatory logout/login warning.
# =============================================================================
# rpcd restart destroys all in-memory sessions.  The browser-side cookie
# is now invalid.  In older LuCI (OpenWrt 21.x/22.x), ubus PERMISSION_DENIED
# resolves to {} rather than rejecting the Promise, so the UI silently shows
# its rpc.declare defaults.  All failure symptoms persist until the user logs
# out and back in to create a session that carries the luci-app-autorecorder
# ACL grant.
printf '\n'
printf '+---------------------------------------------------------+\n'
printf '|  ACTION REQUIRED before opening LuCI                   |\n'
printf '|                                                         |\n'
printf '|  1. Open LuCI in your browser                          |\n'
printf '|  2. LOG OUT  (top-right menu -> Logout)                |\n'
printf '|  3. LOG IN   again with your credentials               |\n'
printf '|                                                         |\n'
printf '|  Without this step the UI will show wrong state:       |\n'
printf '|    Status badge stuck on "Unknown" or "STOPPED"        |\n'
printf '|    PROBE returning empty output                         |\n'
printf '|                                                         |\n'
printf '|  Reason: rpcd restart invalidated your session token.  |\n'
printf '|  A fresh login creates a session with the ACL grant.   |\n'
printf '+---------------------------------------------------------+\n'
printf '\n'
