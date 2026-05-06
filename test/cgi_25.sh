#!/bin/sh
#
# install-autorecorder-cgi.sh — hALSAmrec CGI/bash v2.5 installer
# by FORART (https://forart.it/), 2025-26
# GPL v3 — see <https://www.gnu.org/licenses/>
#
# Self-contained single-file installer.
# All runtime scripts are embedded as heredocs — no network access required.
#
# Usage:
#   scp install-autorecorder-cgi.sh root@192.168.1.1:/tmp/
#   ssh root@192.168.1.1 sh /tmp/install-autorecorder-cgi.sh
#
# Idempotent: safe to re-run; existing config is preserved.
#
# ── Changes from v2 ──────────────────────────────────────────────────────────
#
#   [FIX-01] recorder: Kill-before-unmount order was inverted.
#            In the "not ready" branch the original called umount BEFORE
#            kill, so the live arecord process held a write reference that
#            made unmount fail.  Order corrected: kill writer first, then
#            unmount.
#
#   [FIX-02] recorder: Immediate SIGKILL replaced with graceful shutdown.
#            All kill sites now use a shared _graceful_kill() helper:
#            SIGTERM first → 1 s grace period → SIGKILL only as fallback.
#            This gives arecord a chance to flush its write buffer before
#            the process is forcibly torn down.
#
#   [FIX-03] recorder: Missing SIGINT trap added.
#            The original trapped only SIGTERM and SIGHUP.  Receiving SIGINT
#            (e.g. Ctrl+C in a manual test session) caused an unclean exit:
#            the exFAT filesystem was left mounted and arecord kept running.
#            SIGINT now shares the same cleanup handler as SIGTERM.
#
#   [FIX-04] recorder: Cleanup trap reordered.
#            Original SIGTERM trap killed $dummy first, then $recorder, then
#            unmounted.  Correct order: kill $recorder first (stop writing),
#            unmount, then kill the sentinel $dummy.
#
#   [FIX-05] recorder: Unguarded arithmetic on $max_rate.
#            [ "$max_rate" -gt 48000 ] causes "integer expression expected"
#            in busybox ash when $max_rate is empty (device reports no RATE
#            line in --dump-hw-params).  Now guarded by safe fallback.
#
#   [FIX-06] recorder: Unguarded arithmetic on df $4.
#            $(($4 / 1024)) produces an arithmetic error when $4 is empty
#            (unexpected df output or very long mount-path that wraps the
#            first df line).  Field $4 is now validated as numeric before
#            the comparison; non-numeric output skips the cycle.
#
#   [FIX-07] recorder: card_num / dev_num emptiness unchecked.
#            If arecord -l output differs from the expected format, sed
#            produces empty strings for card_num and dev_num.  Invoking
#            arecord -D "hw:," is an error.  Both values are now validated
#            as non-empty integers before use; missing values skip the cycle.
#
#   [FIX-08] recorder: Safe fallbacks for failed hw-params parsing.
#            If max_ch, bitfmt, or max_rate are still empty after both sed
#            passes (device reports no CHANNELS / FORMAT / RATE line), the
#            script now substitutes conservative defaults (1, S16_LE, 44100)
#            rather than invoking arecord with empty flag values.
#
#   [FIX-09] recorder: Unconditional empty --buffer-time= / --buffer-size=.
#            When a device does not report BUFFER_TIME or BUFFER_SIZE in
#            --dump-hw-params, empty values were passed literally:
#            arecord --buffer-time= --buffer-size=
#            These args are now omitted entirely when the values are empty
#            via unquoted ${var:+--flag=val} expansion, letting arecord pick
#            its compiled-in defaults.
#
#   [FIX-10] controlweb_cgi: Unquoted $INIT in all call sites.
#            $INIT start / $INIT stop were unquoted, which would break if
#            the path ever contained spaces.  All occurrences now use "$INIT".
#
#   [FIX-11] hotplug: ACTION filter added.
#            The original script ran unconditionally on every kernel hotplug
#            event, including USB driver bind/unbind and filesystem online/
#            offline events that are irrelevant to device arrival/departure.
#            A case filter now restricts execution to add|remove|change.
#
#   [FIX-12] installer: hotplug chmod 644 → 755.
#            OpenWrt's hotplug daemon executes scripts via execv(), not
#            source.  chmod 644 silently prevented the scripts from running.
#
#   [FIX-13] installer: opkg update failure no longer aborts.
#            The original ran under set -e; a network error during opkg
#            update caused the entire installer to exit before any package
#            was installed.  The update step now uses || WARN and continues.
#
#   [FIX-14] installer: Pre-flight checks added (root, OpenWrt, opkg).
#
#   [FIX-15] installer: Idempotency — existing config is preserved on
#            re-install; the service is restarted rather than blindly
#            re-enabled.

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
# [FIX-14] Added — the v2 installer had none of these guards.
STEP "Pre-flight checks"

[ "$(id -u)" -eq 0 ]         || ERR "Must be run as root"
[ -f /etc/openwrt_release ]  || ERR "Not an OpenWrt system"
command -v opkg >/dev/null 2>&1 || ERR "opkg not found"

OPENWRT_VER=$(. /etc/openwrt_release && printf '%s' "$DISTRIB_RELEASE")
OK "OpenWrt $OPENWRT_VER detected"

# ── 1. Dependencies ───────────────────────────────────────────────────────────
STEP "Updating package list"
# [FIX-13] opkg update failure used to abort via set -e; now warns and
# continues so that a transient network issue does not block installation
# when the package cache is already populated.
if opkg update >/dev/null 2>&1; then
    OK "Package list updated"
else
    WARN "opkg update failed — continuing with cached list (may be stale)"
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
    || ERR "Package installation failed — check feed availability"
OK "Packages installed"

# ── 2. Write runtime files ────────────────────────────────────────────────────
STEP "Writing runtime files"

# ── /usr/sbin/recorder ────────────────────────────────────────────────────────
cat > /usr/sbin/recorder << 'EOF_RECORDER'
#!/bin/sh
#
# Original script by J. Bruce Fields, 2024
# This version (v3.5) by FORART (https://forart.it/), 2025-26
# GPL v3 — see <https://www.gnu.org/licenses/>
#
# Changes from v3: see installer changelog FIX-01 through FIX-09.

MNT=/tmp/mnt
recorder=""

# ── Graceful kill helper [FIX-02] ─────────────────────────────────────────────
# Sends SIGTERM and waits up to 1 second before escalating to SIGKILL.
# This gives arecord a chance to flush its write buffers before teardown.
_graceful_kill() {
    local pid="$1"
    [ -z "$pid" ]          && return 0
    [ -e "/proc/$pid" ]    || return 0
    kill "$pid" 2>/dev/null            # SIGTERM — ask nicely
    sleep 1
    [ -e "/proc/$pid" ] && kill -9 "$pid" 2>/dev/null   # SIGKILL fallback
    return 0
}

# ── Signal handling ───────────────────────────────────────────────────────────

# SIGHUP: no-op handler — interrupts wait() to wake the supervisor loop
# without terminating an in-progress recording.  Used by procd reload and
# the hotplug scripts.
trap 'true' SIGHUP

# Sentinel: an idle sleep that the loop can wait on when no recording is
# active.  SIGHUP interrupts the wait; SIGTERM/SIGINT cleans it up.
sleep infinity &
dummy=$!

# SIGTERM / SIGINT cleanup [FIX-03] [FIX-04]
# Correct order:
#   1. Kill $recorder first — stops arecord from writing to the filesystem,
#      allowing a clean unmount.  Original did this LAST, which could cause
#      umount to fail with EBUSY.
#   2. Unmount the recording medium.
#   3. Kill the sentinel sleep.
# trap '' re-arm prevents re-entrant cleanup if a second signal arrives
# during shutdown.
_cleanup() {
    trap '' SIGTERM SIGINT
    _graceful_kill "$recorder"
    umount -l "$MNT" 2>/dev/null
    kill "$dummy" 2>/dev/null
    exit 0
}
trap '_cleanup' SIGTERM SIGINT

first=0

while true; do
    if [ $first -eq 0 ]; then
        first=1
    else
        # Wait on the active recorder PID; fall back to the sentinel sleep.
        # SIGHUP interrupts wait() here without killing $recorder — the
        # recording continues uninterrupted while the loop re-evaluates
        # hardware readiness.
        wait ${recorder:-$dummy}
    fi

    # ── Audio card detection ──────────────────────────────────────────────────
    # Single arecord -l call; output is reused for card/device number
    # parsing to avoid a redundant subprocess in the common case.
    card_line=$(arecord -l 2>/dev/null | grep '^card' | head -n 1)

    # ── Disk detection ────────────────────────────────────────────────────────
    # Reads the raw exFAT OEM-ID at superblock byte offset 3 ("EXFAT   ").
    # Exactly ONE exFAT partition must be present; multiple matches → no
    # recording (ambiguous mount target).
    disk="" exfat_count=0
    while read -r _maj _min _blk name; do
        case "$name" in sd*|mmcblk*|nvme*)
            dev="/dev/$name"
            [ -b "$dev" ] || continue
            if dd if="$dev" bs=1 skip=3 count=5 2>/dev/null \
                    | grep -q 'EXFAT'; then
                exfat_count=$((exfat_count + 1))
                disk="$dev"
            fi
        esac
    done < /proc/partitions
    [ "$exfat_count" -ne 1 ] && disk=""

    # ── Stale PID cleanup ─────────────────────────────────────────────────────
    # Detects if a previously started arecord exited on its own (e.g. device
    # error, disk full) and resets state so the next cycle can restart it.
    if [ -n "$recorder" ] && [ ! -e "/proc/$recorder" ]; then
        recorder=""
        umount -l "$MNT" 2>/dev/null
    fi

    # ── Readiness gate ────────────────────────────────────────────────────────
    # Both a valid exFAT disk AND a detected audio card are required.
    # If either is missing and a recording was active, stop it cleanly.
    if [ -z "$disk" ] || [ -z "$card_line" ]; then
        if [ -n "$recorder" ]; then
            _graceful_kill "$recorder"    # kill writer FIRST [FIX-01]
            recorder=""
            umount -l "$MNT" 2>/dev/null  # then unmount
        fi
        continue
    fi

    # Already recording and both resources still present — nothing to do.
    [ -n "$recorder" ] && continue

    # ── Mount ─────────────────────────────────────────────────────────────────
    mkdir -p "$MNT"
    mount "$disk" "$MNT" || continue

    # ── Disk space check [FIX-06] ─────────────────────────────────────────────
    # Require at least 100 MB free before starting a new recording.
    # Validates that df column $4 (Available KB) is a non-empty integer
    # before performing arithmetic — protects against unexpected df output
    # (e.g. long mount-path wrapping across lines on some df implementations).
    set -- $(df -k "$MNT" | tail -n 1)
    case "${4:-}" in
        ''|*[!0-9]*)
            # Cannot determine free space — skip cycle and retry after delay
            umount -l "$MNT" 2>/dev/null
            sleep 5
            continue
            ;;
    esac
    if [ $(($4 / 1024)) -le 100 ]; then
        umount -l "$MNT" 2>/dev/null
        sleep 5
        continue
    fi

    # ── Card / device number parsing [FIX-07] ────────────────────────────────
    # Parse from the already-captured arecord -l output.
    # Validate that both values are non-empty integers; if sed yields an
    # empty result (unexpected arecord -l format), skip this cycle rather
    # than invoking arecord -D "hw:,".
    card_num=$(printf '%s\n' "$card_line" | sed 's/^card \([0-9]*\):.*/\1/')
    dev_num=$(printf '%s\n'  "$card_line" | sed 's/.*device \([0-9]*\):.*/\1/')

    case "${card_num:-x}" in *[!0-9]*|'')
        umount -l "$MNT" 2>/dev/null; continue ;;
    esac
    case "${dev_num:-x}" in *[!0-9]*|'')
        umount -l "$MNT" 2>/dev/null; continue ;;
    esac

    # ── Hardware parameter detection ──────────────────────────────────────────
    arecord_out=$(arecord -D "hw:${card_num},${dev_num}" --dump-hw-params 2>&1)

    # Max channels: upper bound of "[min max]" range; fallback to single value
    max_ch=$(printf '%s\n' "$arecord_out" \
        | sed -n 's/^CHANNELS:.*\[\([0-9]*\) \([0-9]*\)\].*/\2/p')
    [ -z "$max_ch" ] && \
        max_ch=$(printf '%s\n' "$arecord_out" \
            | sed -n 's/^CHANNELS:[[:space:]]*\[*\([0-9][0-9]*\).*/\1/p')

    # Format: last listed format token  (${##* } = awk's $NF in pure shell)
    fmt_raw=$(printf '%s\n' "$arecord_out" \
        | sed -n 's/^FORMAT:[[:space:]]*//p' | head -n 1)
    bitfmt="${fmt_raw##* }"

    # Max sample rate: upper bound of range, capped at 48000 [FIX-05]
    max_rate=$(printf '%s\n' "$arecord_out" \
        | sed -n 's/^RATE:.*[\[(]\([0-9]*\) \([0-9]*\)[])].*/ \2/p')
    [ -z "$max_rate" ] && \
        max_rate=$(printf '%s\n' "$arecord_out" \
            | sed -n 's/^RATE:[[:space:]]*\([0-9][0-9]*\).*/\1/p')

    # Buffer parameters (may be absent on some devices)
    buf_time=$(printf '%s\n' "$arecord_out" \
        | sed -n 's/^BUFFER_TIME:.*[\[(]\([0-9]*\) \([0-9]*\)[])].*/ \2/p')
    buf_size=$(printf '%s\n' "$arecord_out" \
        | sed -n 's/^BUFFER_SIZE:.*[\[(]\([0-9]*\) \([0-9]*\)[])].*/ \2/p')

    # ── Safe fallbacks for failed hw-params parsing [FIX-08] ─────────────────
    # If a device's --dump-hw-params output omits CHANNELS, FORMAT, or RATE
    # (unusual but possible), substitute conservative defaults rather than
    # passing empty values to arecord.
    #   max_ch  — mono is universally safe
    #   bitfmt  — signed 16-bit LE is the most widely supported PCM format
    #   max_rate — 44100 Hz is standard CD quality, well within USB audio limits
    : "${max_ch:=1}"
    : "${bitfmt:=S16_LE}"
    : "${max_rate:=44100}"

    # Cap sample rate (safe arithmetic — max_rate is always non-empty now)
    [ "$max_rate" -gt 48000 ] && max_rate=48000

    # ── Start recording [FIX-09] ──────────────────────────────────────────────
    # --buffer-time and --buffer-size are omitted entirely when empty via
    # unquoted ${var:+--flag=val} expansion, so arecord uses its compiled-in
    # defaults rather than receiving "--buffer-time=" as a literal empty arg.
    arecord --device="hw:${card_num},${dev_num}" \
        --channels="$max_ch"  \
        --file-type=raw       \
        --format="$bitfmt"    \
        --rate="$max_rate"    \
        ${buf_time:+--buffer-time=$buf_time} \
        ${buf_size:+--buffer-size=$buf_size} \
        > "${MNT}/$(date +%s)_${max_ch}-${max_rate}-${bitfmt}.raw" 2>/dev/null &

    recorder=$!
done
EOF_RECORDER
OK "/usr/sbin/recorder (v3.5)"

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

# reload_service sends SIGHUP to the recorder via procd.
# SIGHUP interrupts the wait() inside the recorder loop, waking the
# supervisor for hardware re-evaluation without terminating an in-progress
# recording.
reload_service() {
    procd_send_signal autorecorder
}
EOF_INIT
OK "/etc/init.d/autorecorder"

# ── /etc/hotplug.d/block/autorecorder ────────────────────────────────────────
# Fires when a block device (USB storage) is added, removed, or changed.
# Both add and remove are intentional — add wakes the recorder when storage
# appears; remove causes re-evaluation so recording stops cleanly on pull.
mkdir -p /etc/hotplug.d/block
cat > /etc/hotplug.d/block/autorecorder << 'EOF_HOTPLUG'
#!/bin/sh
#
# autorecorder block hotplug handler
# by FORART (https://forart.it/), 2025-26
# GPL v3 — see <https://www.gnu.org/licenses/>
#
# [FIX-11] Filter to relevant actions only.
# The original ran unconditionally on every hotplug event, including USB
# driver bind/unbind and filesystem online/offline events that have nothing
# to do with device arrival or departure.  The case filter prevents spurious
# SIGHUP signals while still waking the recorder when storage connects or
# disconnects.
case "$ACTION" in
    add|remove|change) service autorecorder reload ;;
esac
EOF_HOTPLUG
OK "/etc/hotplug.d/block/autorecorder"

# ── /etc/hotplug.d/usb/autorecorder ──────────────────────────────────────────
# Fires when a USB device (including USB audio interfaces) is added or
# removed.  USB audio cards generate usb hotplug events but do NOT generate
# block hotplug events, so this handler is required for the core use-case of
# a dedicated USB microphone or USB sound card.
mkdir -p /etc/hotplug.d/usb
cat > /etc/hotplug.d/usb/autorecorder << 'EOF_HOTPLUG'
#!/bin/sh
#
# autorecorder USB hotplug handler
# by FORART (https://forart.it/), 2025-26
# GPL v3 — see <https://www.gnu.org/licenses/>
case "$ACTION" in
    add|remove|change) service autorecorder reload ;;
esac
EOF_HOTPLUG
OK "/etc/hotplug.d/usb/autorecorder"

# ── /www/cgi-bin/cm ───────────────────────────────────────────────────────────
mkdir -p /www/cgi-bin
cat > /www/cgi-bin/cm << 'EOF_CGI'
#!/bin/sh
#
# Simple web-control CGI script for hALSAmrec v2.5
# by FORART (https://forart.it/), 2025-26
# GPL v3 — see <https://www.gnu.org/licenses/>
#
# Changes from v2:
#   [FIX-10] Quoted "$INIT" in all call sites.

RECORDER=/usr/sbin/recorder
INIT=/etc/init.d/autorecorder

echo "Content-type: text/plain"
echo ""

[ "$REQUEST_METHOD" = "GET" ] || { echo "Error: Method not allowed"; exit 1; }
[ -n "$QUERY_STRING" ]        || { echo "Usage: /cgi-bin/cm?cmnd=START|STOP|STATUS|PROBE"; exit 0; }

# Pure-shell QUERY_STRING parsing — no subprocess needed.
# ##*cmnd= : greedy left-strip to the last "cmnd=" occurrence (last wins if
#            the parameter appears more than once in the query string).
# %%&*     : strips everything from the first "&" onwards.
tmp="${QUERY_STRING##*cmnd=}"
CMND="${tmp%%&*}"

# is_running: matches /usr/sbin/recorder in the full process cmdline.
# pgrep -f is used because procd executes the shebang script via /bin/sh,
# so the kernel sets the process comm to "sh" rather than "recorder".
is_running() { pgrep -f "$RECORDER" >/dev/null 2>&1; }

case "$CMND" in
    START)
        if is_running; then
            echo "Already running"
        else
            "$INIT" start >/dev/null 2>&1; sleep 2   # [FIX-10]
            is_running && echo "Started successfully" || echo "Failed to start"
        fi
        ;;
    STOP)
        if ! is_running; then
            echo "Already stopped"
        else
            "$INIT" stop >/dev/null 2>&1; sleep 2   # [FIX-10]
            is_running && echo "Failed to stop" || echo "Stopped successfully"
        fi
        ;;
    STATUS)
        if is_running; then
            echo "RUNNING (PID: $(pgrep -f "$RECORDER"))"
        else
            echo "STOPPED"
        fi
        ;;
    PROBE)
        if is_running; then
            echo "WARNING: recorder is running, stop to probe!"
        else
            arecord -D "hw:0,0" --dump-hw-params 2>&1
        fi
        ;;
    *)
        printf 'Unknown command: %s\nValid commands: START, STOP, STATUS, PROBE\n' "$CMND"
        ;;
esac
EOF_CGI
OK "/www/cgi-bin/cm (v2.5)"

# ── 3. Permissions ────────────────────────────────────────────────────────────
# [FIX-12] hotplug scripts now get 755.
# OpenWrt's hotplug daemon executes scripts via execv(), not source — a
# script without execute permission is silently skipped.  The original
# installer set 644, which meant neither hotplug handler ever ran.
STEP "Setting permissions"
chmod 0755 /usr/sbin/recorder
chmod 0755 /etc/init.d/autorecorder
chmod 0755 /etc/hotplug.d/block/autorecorder   # [FIX-12]
chmod 0755 /etc/hotplug.d/usb/autorecorder     # [FIX-12]
chmod 0755 /www/cgi-bin/cm
OK "Permissions set"

# ── 4. Enable and (re)start service ──────────────────────────────────────────
# [FIX-15] Idempotency: restart if already running rather than blindly
# re-enabling (which would fail with "already enabled" on some init systems).
STEP "Enabling and starting autorecorder service"
/etc/init.d/autorecorder enable
if /etc/init.d/autorecorder running 2>/dev/null; then
    /etc/init.d/autorecorder restart
    OK "Autorecorder restarted"
else
    /etc/init.d/autorecorder start
    OK "Autorecorder started"
fi

# ── 5. Summary ────────────────────────────────────────────────────────────────
LAN_IP=$(uci get network.lan.ipaddr 2>/dev/null || echo '<your-router-ip>')

printf "\n${BOLD}${GREEN}============================================${RESET}\n"
printf "${BOLD}${GREEN}  hALSAmrec v2.5 — Installation complete!${RESET}\n"
printf "${BOLD}${GREEN}============================================${RESET}\n"
printf "\n"
printf "  ${BOLD}Web interface (HTTP GET, no auth required):${RESET}\n"
for cmd in START STOP STATUS PROBE; do
    printf "    http://${LAN_IP}/cgi-bin/cm?cmnd=%s\n" "$cmd"
done
printf "\n"
printf "  ${BOLD}Hotplug handlers installed:${RESET}\n"
printf "    /etc/hotplug.d/block/autorecorder  (USB storage)\n"
printf "    /etc/hotplug.d/usb/autorecorder    (USB audio card)\n"
printf "\n"
printf "  ${YELLOW}Note:${RESET} Plug in exactly ONE exFAT-formatted USB storage device\n"
printf "  and ONE USB audio interface.  The recorder starts automatically.\n"
printf "\n"
printf "  ${YELLOW}Note:${RESET} The CGI endpoint is unauthenticated.  Restrict access\n"
printf "  at the uhttpd / firewall level if the router is publicly reachable.\n"
printf "\n"

printf "A reboot is recommended. Reboot device now? [y/N]: "
read -r answer
case "$answer" in
    [yY]*) printf "Rebooting...\n"; reboot ;;
    *)     printf "Please reboot manually when ready.\n" ;;
esac
