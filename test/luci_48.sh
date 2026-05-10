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
# Changes from v4.5 (engineering fixes — see analysis document):
#
#   [FIX-A] recorder: Persistent mount architecture.
#            The recording disk is now mounted ONCE and stays mounted for
#            the entire lifetime of the supervisor process.  Previously the
#            disk was unmounted every time arecord exited (stale-PID cleanup),
#            then immediately remounted — creating a race window where the
#            lazy-unmount had not yet completed and the new mount call failed
#            with "device busy", causing an infinite unmount/remount loop.
#
#   [FIX-B] recorder: UUID-based device resolution.
#            After discovering the exFAT partition, its UUID is read once via
#            blkid and used to resolve the current /dev/sdX path on every
#            mount attempt.  This makes the recorder resilient to the kernel
#            renaming /dev/sda → /dev/sdb after a USB reconnect.
#
#   [FIX-C] recorder: active_mnt tracking.
#            The actual path at which the disk was mounted is stored in
#            $active_mnt.  If the UCI mount option is changed while the
#            service is running, the old mount is cleanly torn down and the
#            disk remounted at the new path, preventing stale-mount orphans.
#
#   [FIX-D] recorder: Graceful arecord termination.
#            kill_recorder() sends SIGTERM first, waits 1 s, then SIGKILL.
#            SIGKILL was previously used immediately, which prevented arecord
#            from flushing and closing the output file.
#
#   [FIX-E] recorder: Buffer param mutual exclusion.
#            --buffer-time and --buffer-size are mutually exclusive in
#            arecord.  v4.5 extracted both and passed both, causing arecord
#            to reject the command on many devices.  v4.6 passes only
#            --buffer-time when present; --buffer-size is never passed.
#
#   [FIX-F] recorder: Defensive defaults for hardware param detection.
#            max_ch, bitfmt, and max_rate are given safe fallback values
#            (2, S16_LE, 48000) so that failed sed extractions do not leave
#            empty variables that crash arithmetic expressions.
#
#   [FIX-G] recorder: Card-not-ready does NOT unmount disk.
#            When the audio interface is absent, the recorder is stopped but
#            the recording disk remains mounted.  Reconnecting the audio card
#            immediately starts a new recording without a remount cycle.
#
#   [FIX-H] recorder: Partition-only scanning.
#            /proc/partitions scan now matches only partition entries
#            (sd*[0-9], mmcblk*p[0-9]*, nvme*p[0-9]*) so whole-disk nodes
#            like /dev/sda are not counted as exFAT candidates, preventing
#            false exfat_count > 1 rejections.
#
#   [FIX-I] recorder: Disk-space check uses awk instead of set --.
#            Avoids positional-parameter collisions with the arecord
#            argument-building set -- call later in the same loop body.
#
#   [FIX-J] init.d: Add procd_set_param respawn.
#            Without this, procd does not restart the supervisor if it exits
#            unexpectedly (OOM, kernel signal).  Configured to allow up to
#            5 restarts per hour with a 5-second cooldown.
#
#   [FIX-K] rpcd: Replace sleep 2 with retry loop in start/stop.
#            A fixed 2-second sleep is a race condition: on loaded routers
#            procd may take longer than 2 s to spawn the process.  v4.6 polls
#            is_running() in 1-second increments for up to 4 seconds.
#
#   [FIX-L] rpcd: Probe captures arecord exit code; returns probe_warnings
#            error token on failure so the UI can distinguish "ran and
#            produced output" from "ran and succeeded".
#
#   [FIX-M] rpcd: Probe output expanded.
#            Returns ALSA card list, hw-param dump, storage status, and
#            block-device snapshot in one response for actionable diagnostics.
#
#   [FIX-N] rpcd: disk_status guards df failure with awk default.
#            If df returns nothing, fields default to 0 instead of producing
#            malformed JSON.
#
#   [FIX-O] LuCI JS: START/STOP merged into a single toggle button.
#            Green label "START" when stopped; red label "STOP" when running.
#            Disabled while transitioning; double-click safe.
#
#   [FIX-P] LuCI JS: Poll and _refreshStatus both call _updateToggle.
#            The toggle button label/colour is now updated live on every 5-s
#            poll cycle and immediately after every start/stop action.
#
#   [FIX-Q] LuCI JS: _setBusy updated for toggle button ID.
#            Removes defunct ar-btn-start / ar-btn-stop IDs; adds ar-btn-toggle.
#
#   [FIX-R] LuCI JS: Probe handler distinguishes probe_warnings from full
#            errors, showing a visual prefix in the output pane.
#
# Changes from v4.6 (LuCI runtime fixes):
#
#   [FIX-S] recorder: Write PID file /var/run/autorecorder.pid on startup.
#            The PID file is the source of truth for is_running() in the rpcd
#            plugin.  It is removed in the SIGTERM trap on clean shutdown.
#            Stale files (OOM kill, SIGKILL) are guarded by a /proc/$pid
#            existence check before the file is trusted.
#
#   [FIX-T] rpcd: Replace pgrep-based is_running() with PID-file + /proc scan.
#            pgrep -f is unreliable in many BusyBox builds:
#              (a) Some BusyBox configs omit the -f flag entirely.
#              (b) When procd exec's a shebang script, /proc/PID/cmdline begins
#                  with "/bin/sh", not the script path; pgrep -f matching the
#                  script name therefore finds nothing.
#            Both cases make is_running() permanently return false, so the LuCI
#            status badge always displays "Stopped" even while recording.
#            The new implementation reads the PID file (O(1)), verifies the PID
#            is alive in /proc, and cross-checks the cmdline to guard against
#            PID reuse.  A /proc full-scan fallback covers the window between
#            startup and the first PID-file write.
#
#   [FIX-U] rpcd: Guard status JSON against empty pid field.
#            When is_running() returned true but the second pgrep call raced
#            (process between cycles), pid="" produced {"running":true,"pid":}
#            — invalid JSON that rpcd silently dropped, causing the JS catch
#            handler to return {running:false,pid:0} → "Stopped".
#            Fixed by sourcing pid exclusively from the PID file and
#            defaulting to 0 when the file is absent or stale.
#
#   [FIX-V] installer: Explicitly grant luci-app-autorecorder to rpcd root login.
#            In OpenWrt 21.x/22.x, "list read '*'" in /etc/config/rpcd is NOT
#            a wildcard — rpcd looks for an ACL group literally named "*", which
#            does not exist.  The luci-app-autorecorder ACL group is therefore
#            never applied to the LuCI session, so every ubus call through the
#            LuCI HTTP proxy is silently rejected with "Access denied".  This
#            caused ALL three LuCI RPC failures simultaneously:
#              * status  -> catch default {running:false} -> "Stopped"
#              * get_config -> catch default {card:""} -> empty inputs
#              * probe  -> catch default {output:""}  -> "(no output)"
#            Fix: after writing the ACL file, find the root login section in
#            /etc/config/rpcd and add the grant explicitly, making the install
#            idempotent and correct on every supported OpenWrt version.
#
# Changes from v4.7 (forensic analysis fixes — see hALSAmrec_v47_forensic_analysis.md):
#
#   [FIX-W] recorder + rpcd: Prevent arecord --dump-hw-params pipe-fill deadlock.
#            arecord invoked with --dump-hw-params and no explicit output file
#            writes raw PCM audio frames to stdout.  Inside a $() command
#            substitution this stdout IS the pipe; the pipe buffer fills
#            (~64 KB on Linux), arecord blocks on write(), and the subshell
#            hangs indefinitely.  In the rpcd probe method, rpcd's watchdog
#            eventually kills the blocked plugin — producing empty stdout —
#            and the ubus call returns {}.  rpc.declare applies its expect
#            defaults {error:"",output:""}, and the JS shows "(no output)".
#            Fix: pass -d 1 (1-second recording limit) and /dev/null (explicit
#            output target so audio is discarded, not written to the pipe).
#            2>&1 continues to capture the hw-param text from stderr.
#            The same fix is applied to the recorder's own hw-param detection
#            call, which had the same structural vulnerability.
#
#   [FIX-X] rpcd: Extend json_str() to escape carriage returns (\r / 0x0D).
#            The original tr/sed pipeline converted LF and TAB but left CR
#            bytes unescaped.  Some ALSA utility versions and some df
#            implementations emit CR in their output; an unescaped CR byte
#            inside a JSON string literal makes the document technically
#            invalid per RFC 8259 section 7.  Fix: add \r to the tr
#            intermediary pipeline (ETX = 0x03 as the placeholder byte) and
#            a matching s/\003/\\r/g replacement in the final sed pass.
#            SOH/STX/ETX (0x01-0x03) never appear in arecord, df, or
#            /proc/partitions text output.
#
#   [FIX-Y] rpcd: Add ubus service list as primary is_running() detection.
#            On some procd/kernel configurations the exec mechanism does not
#            place the recorder script path in the cmdline of the interpreter
#            process (e.g. procd may exec via /proc/self/fd/N rather than a
#            named path).  In those cases the grep-qF "$RECORDER" check on
#            /proc/PID/cmdline fails, so is_running() returns false while the
#            recorder IS running — status shows "Stopped" permanently.
#            Fix: query procd's own service registry first via
#            "ubus call service list" and check the "running" field.  The
#            ubus query is authoritative and immune to cmdline representation
#            differences across procd versions.  The existing PID-file and
#            /proc-scan logic is retained as the secondary fallback for the
#            startup race window before the PID file is written.
#
#   [FIX-Z] rpcd: Pass mount path through json_str() in disk_status/get_config.
#            The mount path was embedded directly in printf format strings
#            without escaping.  A path containing a double-quote or backslash
#            (legal in POSIX) would produce malformed JSON, silently dropped
#            by rpcd's parser.  Fix: wrap $mnt through json_str() before
#            embedding it in the JSON output.  Also applied to the card and
#            device fields in get_config for completeness.
#
#   [FIX-AA] installer: Prominent mandatory logout/login warning box.
#             rpcd restart destroys ALL active in-memory sessions.  The
#             browser-side session cookie (held by the LuCI tab) becomes
#             invalid; every subsequent ubus call returns PERMISSION_DENIED.
#             In older LuCI (OpenWrt 21.x/22.x) rpc.js resolves
#             PERMISSION_DENIED to {} rather than rejecting the Promise, so
#             rpc.declare silently returns its expect-schema defaults:
#             {running:false}, {mounted:false}, {output:""}.  All three
#             failure symptoms persist until the user explicitly logs out of
#             LuCI and logs back in.  The installer now displays a bold,
#             bordered warning box listing the exact symptoms, the reason,
#             and the required action.

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
# [FIX-D] Allows arecord to flush and close the output file cleanly.
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

# [FIX-S] Publish our PID so the rpcd plugin can find us without pgrep.
# Written after the sentinel fork so $$ is the supervisor, not the sentinel.
printf '%s\n' $$ > /var/run/autorecorder.pid

# SIGTERM: clean shutdown — stop arecord, unmount disk, remove PID file, exit.
# [FIX-D] Uses kill_recorder (SIGTERM first) instead of SIGKILL.
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
        # Block until arecord (or the sentinel) exits.
        # SIGHUP interrupts this wait, allowing the loop to re-evaluate
        # hardware state while leaving a running arecord untouched.
        wait ${recorder:-$dummy}
    fi

    # Re-read mount point each cycle in case UCI was updated via LuCI.
    MNT=$(uci_get mount)
    MNT="${MNT:-/tmp/mnt}"

    # ── [FIX-C] UCI mount change while disk is mounted: remount at new path ──
    # If the user changes the mount path in LuCI while the service is running,
    # cleanly unmount the old path and remount at the new one.
    if [ "$disk_mounted" -eq 1 ] && [ -n "$active_mnt" ] && [ "$MNT" != "$active_mnt" ]; then
        kill_recorder "$recorder"
        recorder=""
        umount -l "$active_mnt" 2>/dev/null
        disk_mounted=0
        active_mnt=""
        # Fall through — will remount at new $MNT below.
    fi

    # ── Audio card detection ──────────────────────────────────────────────────
    # Use UCI-persisted card/device if available — skips arecord -l entirely.
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
    # [FIX-H] Match only partition entries (names ending in a digit) so that
    # whole-disk nodes like /dev/sda are not counted as exFAT candidates.
    # This prevents false "exfat_count > 1" rejections when a single USB drive
    # exposes both /dev/sda (whole disk, no fs) and /dev/sda1 (partition,
    # exFAT), which the old pattern sd* would count as two exFAT hits.
    #
    # [FIX-B] For each matching partition, capture the UUID so we can resolve
    # the current /dev/sdX path on every mount attempt (resilient to kernel
    # renaming /dev/sda → /dev/sdb after a USB hot-reconnect).
    disk="" disk_uuid="" exfat_count=0
    while read -r _maj _min _blk name; do
        case "$name" in
            sd*[0-9] | mmcblk*p[0-9]* | nvme*p[0-9]*)
                dev="/dev/$name"
                [ -b "$dev" ] || continue
                fs_type=$(blkid -o value -s TYPE "$dev" 2>/dev/null)
                if [ -z "$fs_type" ]; then
                    # Fallback: raw exFAT OEM-ID check at superblock offset 3.
                    # Works without kmod-fs-exfat loaded and on busybox builds
                    # where blkid was compiled without exFAT type detection.
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

    # Require exactly ONE exFAT partition — multiple disks → ambiguous target.
    if [ "$exfat_count" -ne 1 ]; then
        disk=""
        disk_uuid=""
    fi

    # ── [FIX-A] Disk removed: stop recording and unmount ─────────────────────
    # ONLY unmount here — when the physical disk is gone.
    # arecord exiting naturally does NOT trigger an unmount.
    if [ "$disk_mounted" -eq 1 ] && [ -z "$disk" ]; then
        kill_recorder "$recorder"
        recorder=""
        umount -l "${active_mnt:-$MNT}" 2>/dev/null
        disk_mounted=0
        active_mnt=""
        continue
    fi

    # ── [FIX-A] Stale PID cleanup — DO NOT unmount ───────────────────────────
    # When arecord exits (disk full, encoding error, audio glitch), clear the
    # PID so the loop can start a new recording.  The disk STAYS mounted —
    # there is no reason to unmount it just because one recording session ended.
    # v4.5 unmounted here, creating the remount race condition (see FIX-A).
    if [ -n "$recorder" ] && [ ! -e "/proc/$recorder" ]; then
        recorder=""
    fi

    # ── [FIX-G] Card not ready: stop arecord but keep disk mounted ───────────
    # The audio interface may briefly disconnect (driver reset, USB glitch)
    # while the storage is perfectly healthy.  Unmounting and remounting the
    # recording disk for every audio event wastes I/O and risks remount races.
    if [ "$card_ready" -eq 0 ]; then
        if [ -n "$recorder" ]; then
            kill_recorder "$recorder"
            recorder=""
        fi
        continue
    fi

    # ── Mount disk if present and not yet mounted ─────────────────────────────
    if [ -n "$disk" ] && [ "$disk_mounted" -eq 0 ]; then
        mkdir -p "$MNT"
        # [FIX-B] Resolve UUID → current /dev/sdX path.
        # blkid -t UUID=... -l -o device returns the device node that currently
        # carries this UUID, regardless of kernel enumeration order.
        if [ -n "$disk_uuid" ]; then
            resolved=$(blkid -t "UUID=${disk_uuid}" -l -o device 2>/dev/null)
            [ -n "$resolved" ] && disk="$resolved"
        fi
        mount "$disk" "$MNT" 2>/dev/null || continue
        disk_mounted=1
        active_mnt="$MNT"
    fi

    # Recording already in progress — nothing to do this cycle.
    [ -n "$recorder" ] && continue

    # ── Disk space check ──────────────────────────────────────────────────────
    # [FIX-I] Use awk instead of set -- to avoid clobbering $@ which is
    # needed later for building the arecord argument list.
    # Require at least 100 MB free before starting a new recording.
    avail_kb=$(df -k "$active_mnt" 2>/dev/null | tail -n 1 | awk '{print $4}')
    avail_kb="${avail_kb:-0}"
    if [ "$(( avail_kb / 1024 ))" -le 100 ]; then
        sleep 5
        continue
    fi

    # ── Hardware parameter detection ──────────────────────────────────────────
    # [FIX-W] Add -d 1 /dev/null to prevent pipe-fill deadlock.
    # Without an explicit output file, arecord writes raw PCM frames to stdout
    # (the $() pipe).  The pipe buffer fills (~64 KB), arecord blocks on
    # write(), and this subshell hangs indefinitely.  Fix: -d 1 limits
    # recording to 1 second so arecord exits cleanly; /dev/null discards the
    # audio data; 2>&1 captures the hw-param text from stderr into the variable.
    arecord_out=$(arecord -D "hw:${card_num},${dev_num}" \
        --dump-hw-params -d 1 /dev/null 2>&1 || true)

    # Max channels: upper bound of range [min max], fallback to single value.
    # [FIX-F] Default 2 if not detected.
    max_ch=$(printf '%s\n' "$arecord_out" \
        | sed -n 's/^CHANNELS:.*\[\([0-9]*\) \([0-9]*\)\].*/\2/p')
    [ -z "$max_ch" ] && \
        max_ch=$(printf '%s\n' "$arecord_out" \
            | sed -n 's/^CHANNELS:[[:space:]]*\[*\([0-9][0-9]*\).*/\1/p')
    max_ch="${max_ch:-2}"

    # Format: last listed format token.
    # [FIX-F] Default S16_LE if not detected.
    fmt_raw=$(printf '%s\n' "$arecord_out" \
        | sed -n 's/^FORMAT:[[:space:]]*//p' | head -n 1)
    bitfmt="${fmt_raw##* }"
    bitfmt="${bitfmt:-S16_LE}"

    # Max sample rate: upper bound of range, capped at 48000.
    # [FIX-F] Default 48000; guard against non-numeric to prevent arithmetic crash.
    max_rate=$(printf '%s\n' "$arecord_out" \
        | sed -n 's/^RATE:.*[\[(]\([0-9]*\) \([0-9]*\)[])].*/ \2/p')
    [ -z "$max_rate" ] && \
        max_rate=$(printf '%s\n' "$arecord_out" \
            | sed -n 's/^RATE:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
    max_rate="${max_rate:-48000}"
    case "$max_rate" in *[!0-9]*) max_rate=48000 ;; esac  # strip non-numeric
    [ "$max_rate" -gt 48000 ] && max_rate=48000

    # [FIX-E] Buffer time only — --buffer-time and --buffer-size are mutually
    # exclusive in arecord.  v4.5 extracted both and passed both; arecord
    # rejected the command on devices where both were non-empty.
    # We use buffer-time (preferred); buffer-size is never passed.
    buf_time=$(printf '%s\n' "$arecord_out" \
        | sed -n 's/^BUFFER_TIME:.*[\[(]\([0-9]*\) \([0-9]*\)[])].*/ \2/p')

    # ── Auto-persist detected card/device to UCI ──────────────────────────────
    # Only writes if UCI values are absent.  Double-check inside narrow window
    # to reduce probability of clobbering a concurrent LuCI set_config save.
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
    # Build command with set -- so each argument is properly quoted.
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
#
# autorecorder procd init script — hALSAmrec v4.8
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
    # [FIX-J] Respawn: restart the supervisor if it exits unexpectedly.
    # Parameters: interval=3600 s (reset crash counter after 1 h),
    #             limit=5 (give up after 5 crashes in the interval),
    #             delay=5 s (cooldown before each restart).
    # Without this, procd does NOT restart the service on unexpected exit.
    procd_set_param respawn  3600 5 5
    procd_close_instance
}

# reload_service sends SIGHUP via procd, which interrupts the wait() call in
# the recorder loop so it re-evaluates hardware state without stopping an
# in-progress recording.
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
# Filter to add|remove|change only — skip bind/unbind and other kernel events.
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
# USB audio interfaces generate usb hotplug events but NOT block events.
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
#
# Methods: status, start, stop, probe, disk_status, get_config, set_config
#
# Changes from v4.5:
#   [FIX-K] start/stop: Replace sleep 2 with 4-iteration 1 s retry loop.
#   [FIX-L] probe: Capture arecord exit code; return probe_warnings token.
#   [FIX-M] probe: Expanded output: ALSA list, hw params, storage, block devs.
#   [FIX-N] disk_status: Guard df extraction with awk defaults.
#   [FIX-T] is_running: PID file + /proc scan replaces unreliable pgrep -f.
#   [FIX-U] status: pid field always numeric; sourced from PID file only.
# Changes from v4.7:
#   [FIX-W] probe: Add -d 1 /dev/null to arecord --dump-hw-params to prevent
#            pipe-fill deadlock that caused rpcd watchdog kill → empty output.
#   [FIX-X] json_str: Add \r (carriage return) to the tr/sed escape pipeline.
#   [FIX-Y] is_running: Add ubus service list as primary detection method,
#            immune to procd cmdline-representation differences across versions.
#   [FIX-Z] disk_status/get_config: Escape mount path through json_str() to
#            prevent malformed JSON when the path contains " or \.

RECORDER=/usr/sbin/recorder
INIT=/etc/init.d/autorecorder
MNT_DEFAULT=/tmp/mnt
PIDFILE=/var/run/autorecorder.pid

# [FIX-T][FIX-Y] is_running: three-tier detection strategy.
#
#   Tier 1 (primary): ubus service list — queries procd's authoritative
#     registry.  Immune to cmdline-representation differences (some procd
#     versions exec shebang scripts via /proc/self/fd/N rather than a named
#     path, so /proc/PID/cmdline may not contain the script path at all).
#
#   Tier 2 (secondary): PID file + /proc liveness + cmdline cross-check.
#     Covers the brief startup window before procd has registered the service
#     AND serves as fallback when ubus is temporarily unavailable.
#
#   Tier 3 (tertiary): full /proc scan.
#     Covers the race between service start and the first PID-file write.
is_running() {
    local pid _state
    # Tier 1: procd service registry via ubus (most reliable)
    _state=$(ubus call service list '{"name":"autorecorder"}' 2>/dev/null \
        | jsonfilter -e '@["autorecorder"]["instances"]["instance1"]["running"]' \
        2>/dev/null)
    [ "$_state" = "true" ] && return 0

    # Tier 2: PID file written by recorder on startup
    pid=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
        # Guard against PID reuse: verify cmdline contains our script path.
        # Works when procd places the script path as a /bin/sh argument.
        tr '\000' '\n' < "/proc/$pid/cmdline" 2>/dev/null \
            | grep -qF "$RECORDER" && return 0
    fi

    # Tier 3: full /proc scan (covers startup race before PID file exists)
    for _cl in /proc/[0-9]*/cmdline; do
        tr '\000' '\n' < "$_cl" 2>/dev/null \
            | grep -qF "$RECORDER" && return 0
    done
    return 1
}

# [FIX-U] get_recorder_pid: always returns a numeric PID or nothing.
# Sourcing from the PID file (not a second pgrep call) eliminates the race
# that produced {"running":true,"pid":} — invalid JSON that rpcd rejected.
get_recorder_pid() {
    local pid
    pid=$(cat "$PIDFILE" 2>/dev/null) || return
    [ -n "$pid" ] && [ -d "/proc/$pid" ] && printf '%s' "$pid"
}

uci_get() { uci -q get "autorecorder.config.$1" 2>/dev/null; }

# is_mounted: busybox-safe /proc/mounts check (mountpoint(1) is util-linux).
is_mounted() {
    awk -v m="$1" '$2 == m { found=1 } END { exit !found }' /proc/mounts 2>/dev/null
}

# [FIX-X] json_str: escape a string for embedding in a JSON double-quoted value.
# Handles: \ → \\, " → \", LF → \n, TAB → \t, CR → \r.
#
# Uses tr intermediaries to avoid BusyBox sed portability issues with
# control-character matching in s/// patterns:
#   SOH (0x01) ← placeholder for LF
#   STX (0x02) ← placeholder for TAB
#   ETX (0x03) ← placeholder for CR   [FIX-X: added]
# These three bytes never appear in arecord, df, or /proc/partitions output.
#
# Pipeline:
#   sed pass 1 : escape backslashes and double-quotes (text-safe characters)
#   tr         : replace LF/TAB/CR with SOH/STX/ETX (single-byte, no newlines)
#   sed pass 2 : replace SOH/STX/ETX with their JSON escape sequences
json_str() {
    printf '%s' "$1" \
        | sed 's/\\/\\\\/g; s/"/\\"/g' \
        | tr '\n\t\r' '\001\002\003' \
        | sed 's/\001/\\n/g; s/\002/\\t/g; s/\003/\\r/g'
}

case "$1" in
    list)
        printf '{"status":{},"start":{},"stop":{},"probe":{},"disk_status":{},"get_config":{},"set_config":{"card":"","device":"","mount":""}}\n'
        ;;

    call)
        case "$2" in

            status)
                # [FIX-U] pid always sourced from PID file via get_recorder_pid.
                # Previously a second pgrep call raced with process exit, yielding
                # pid="" → {"running":true,"pid":} — invalid JSON silently dropped
                # by rpcd.  get_recorder_pid() returns a numeric PID or nothing;
                # the ${pid:-0} guard ensures the field is always a valid integer.
                if is_running; then
                    pid=$(get_recorder_pid)
                    printf '{"running":true,"pid":%s}\n' "${pid:-0}"
                else
                    printf '{"running":false,"pid":0}\n'
                fi
                ;;

            start)
                if is_running; then
                    printf '{"result":"already_running"}\n'
                else
                    "$INIT" start >/dev/null 2>&1
                    # [FIX-K] Retry loop: poll is_running() for up to 4 s.
                    # Fixed sleep 2 was a race on loaded routers where procd
                    # takes longer than 2 s to spawn the supervisor process.
                    i=0
                    while [ $i -lt 4 ]; do
                        sleep 1
                        is_running && break
                        i=$((i + 1))
                    done
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
                    # [FIX-K] Same retry logic for stop.
                    i=0
                    while [ $i -lt 4 ]; do
                        sleep 1
                        ! is_running && break
                        i=$((i + 1))
                    done
                    if ! is_running; then
                        printf '{"result":"stopped"}\n'
                    else
                        printf '{"result":"failed"}\n'
                    fi
                fi
                ;;

            probe)
                # [FIX-L][FIX-M] Expanded probe with actionable diagnostics.
                # Returns four sections: ALSA card list, hw-param dump for the
                # configured device, storage status, and block-device snapshot.
                if is_running; then
                    printf '{"error":"recorder_running","output":""}\n'
                else
                    card=$(uci_get card); card="${card:-0}"
                    dev=$(uci_get device);  dev="${dev:-0}"
                    mnt=$(uci_get mount);   mnt="${mnt:-$MNT_DEFAULT}"

                    # Section 1: ALSA capture device list
                    card_list=$(arecord -l 2>&1 || printf '(arecord -l failed)')

                    # Section 2: HW-param dump for configured card/device.
                    # [FIX-W] Add -d 1 /dev/null to prevent pipe-fill deadlock.
                    # Without an explicit output file, arecord writes raw PCM
                    # frames to stdout (the $() pipe).  The pipe buffer fills
                    # (~64 KB), arecord blocks on write(), rpcd's watchdog kills
                    # the plugin, and this call returns empty → JS shows
                    # "(no output)".  Fix: -d 1 limits recording to 1 second so
                    # arecord exits cleanly; /dev/null discards the audio data;
                    # 2>&1 captures the hw-param text from stderr.
                    hw_params=$(arecord -D "hw:${card},${dev}" \
                        --dump-hw-params -d 1 /dev/null 2>&1 || true)
                    hw_rc=$?

                    # Section 3: Storage status at configured mount point
                    if is_mounted "$mnt"; then
                        df_line=$(df -k "$mnt" 2>/dev/null | tail -n 1)
                        disk_info="Mounted at ${mnt}
${df_line}"
                    else
                        disk_info="NOT mounted at ${mnt}"
                    fi

                    # Section 4: /proc/partitions snapshot
                    part_info=$(cat /proc/partitions 2>/dev/null)

                    combined="=== ALSA CAPTURE DEVICES ===
${card_list}

=== HW PARAMS (hw:${card},${dev}) ===
${hw_params}

=== STORAGE (${mnt}) ===
${disk_info}

=== BLOCK DEVICES (/proc/partitions) ===
${part_info}"

                    out=$(json_str "$combined")

                    # [FIX-L] Return probe_warnings when arecord exits non-zero
                    # so the UI can prefix the output with a warning label.
                    if [ "$hw_rc" -ne 0 ]; then
                        printf '{"error":"probe_warnings","output":"%s"}\n' "$out"
                    else
                        printf '{"error":"","output":"%s"}\n' "$out"
                    fi
                fi
                ;;

            disk_status)
                mnt=$(uci_get mount); mnt="${mnt:-$MNT_DEFAULT}"
                if is_mounted "$mnt"; then
                    # [FIX-N] Guard df field extraction: awk provides 0 defaults
                    # if df returns empty output, preventing malformed JSON.
                    df_line=$(df -k "$mnt" 2>/dev/null | tail -n 1)
                    total_kb=$(printf '%s\n' "$df_line" | awk '{print ($2+0)}')
                    used_kb=$(printf '%s\n'  "$df_line" | awk '{print ($3+0)}')
                    avail_kb=$(printf '%s\n' "$df_line" | awk '{print ($4+0)}')
                    # [FIX-Z] Pass mount path through json_str() to escape any
                    # characters that would break the JSON string literal.
                    printf '{"mounted":true,"total_kb":%s,"used_kb":%s,"avail_kb":%s,"mount":"%s"}\n' \
                        "$total_kb" "$used_kb" "$avail_kb" "$(json_str "$mnt")"
                else
                    # [FIX-Z] Same escaping for the not-mounted path.
                    printf '{"mounted":false,"total_kb":0,"used_kb":0,"avail_kb":0,"mount":"%s"}\n' \
                        "$(json_str "$mnt")"
                fi
                ;;

            get_config)
                card=$(uci_get card)
                device=$(uci_get device)
                mount=$(uci_get mount)
                # [FIX-Z] Pass all three fields through json_str() so that
                # special characters in any value cannot break the JSON.
                printf '{"card":"%s","device":"%s","mount":"%s"}\n' \
                    "$(json_str "${card:-}")" \
                    "$(json_str "${device:-}")" \
                    "$(json_str "${mount:-$MNT_DEFAULT}")"
                ;;

            set_config)
                read -r input
                card=$(printf '%s' "$input"       | jsonfilter -e '@.card'   2>/dev/null)
                device=$(printf '%s' "$input"     | jsonfilter -e '@.device' 2>/dev/null)
                mount_path=$(printf '%s' "$input" | jsonfilter -e '@.mount'  2>/dev/null)

                # Validate mount path: must be absolute if non-empty.
                # Empty = delete option (revert to /tmp/mnt default).
                if [ -n "$mount_path" ]; then
                    case "$mount_path" in
                        /*) ;;
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
        // Individual .catch() on each call so a single transient RPC failure
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

        // ── [FIX-O] Single toggle button: green START / red STOP ─────────────
        // The button label and colour always reflect the REAL backend state
        // (fetched in load() above); _updateToggle() keeps it live thereafter.
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
                     'max-height:360px;overflow-y:auto'
        });

        // ── Page layout ───────────────────────────────────────────────────────
        var page = E('div', { 'class': 'cbi-map' }, [

            E('h2', _('ALSA Recorder')),

            // Section: service status + toggle
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
                // [FIX-O] Single toggle button replaces separate Start/Stop
                E('div', { 'style': 'margin-top:1em;display:flex;gap:6px;flex-wrap:wrap' }, [
                    btnToggle
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
                    _('Dump ALSA hardware parameters, storage status, and block-device ' +
                      'snapshot for the configured card/device (falls back to hw:0,0). ' +
                      'The recorder must be stopped first.')),
                btnProbe,
                probeOutput
            ])
        ]);

        // ── Poll status + disk every 5 s ──────────────────────────────────────
        // [FIX-P] Poll also calls _updateToggle so the button colour/label
        // tracks the live backend state without a page reload.
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
                // [FIX-P] Live toggle button update from poll
                self._updateToggle(!!(results[0] && results[0].running));
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

    // ── [FIX-Q] Button busy state — updated for toggle button ID ─────────────
    // Removed defunct ar-btn-start / ar-btn-stop; added ar-btn-toggle.
    // null-guard (if el) ensures this is safe if any element is temporarily
    // absent from the DOM.
    _setBusy: function(busy) {
        ['ar-btn-toggle', 'ar-btn-probe',
         'ar-btn-savecfg', 'ar-btn-clearcfg'].forEach(function(id) {
            var el = document.getElementById(id);
            if (el) el.disabled = busy;
        });
    },

    // ── [FIX-O][FIX-P] Toggle button appearance updater ──────────────────────
    // Called from _refreshStatus (after actions) and from the poll callback.
    // Skips update if button is currently disabled (action in progress) to
    // prevent a poll-cycle race from re-enabling the button prematurely.
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

    // ── Status + toggle refresh helper ───────────────────────────────────────
    // Called immediately after every start/stop action ([FIX-4] from v4.5).
    // Now also refreshes the toggle button via _updateToggle [FIX-P].
    _refreshStatus: function() {
        var self = this;
        return callStatus().catch(function() {
            return { running: false, pid: 0 };
        }).then(function(status) {
            var sc = document.getElementById('ar-status-cell');
            if (sc) dom.content(sc, self._statusBadge(status));
            // [FIX-P] Sync toggle button to refreshed status
            self._updateToggle(!!(status && status.running));
        });
    },

    // ── [FIX-O] Single toggle action ─────────────────────────────────────────
    // Determines intent from the current button label (STOP = service running,
    // START = service stopped) to avoid a separate running-state RPC call.
    // Double-click safe: _setBusy(true) disables the button synchronously
    // before any async operation begins.
    _doToggle: function() {
        var self = this;
        var btn  = document.getElementById('ar-btn-toggle');
        // Guard: reject if button missing or already disabled (in-flight action).
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
            // Immediate badge + toggle refresh regardless of action outcome.
            return self._refreshStatus();
        }).then(function() {
            self._setBusy(false);
        });
    },

    // ── [FIX-R] Probe action ──────────────────────────────────────────────────
    // Distinguishes three response states:
    //   recorder_running  → blocked by active service
    //   probe_warnings    → arecord exited non-zero (e.g. card absent)
    //   ""                → clean success
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

# ── [FIX-V] Explicitly grant luci-app-autorecorder to the rpcd root login ────
# In OpenWrt 21.x/22.x, "list read '*'" in /etc/config/rpcd is NOT a glob —
# rpcd looks for an ACL group literally named "*", which doesn't exist.
# The luci-app-autorecorder group is therefore never applied to LuCI sessions
# → every ubus call through the HTTP proxy is rejected with "Access denied",
# making status/get_config/probe all silently return their JS catch() defaults.
#
# This step finds the root login section (index-agnostic) and adds the grant
# idempotently: del_list first to avoid duplicates, then add_list.
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
sleep 2

# ── [FIX-AA] Verify plugin registration with a definitive pass/fail check ────
# Give rpcd a moment to parse all ACL files and register plugins, then
# confirm the autorecorder ubus object is visible before proceeding.
if ubus list autorecorder >/dev/null 2>&1; then
    OK "rpcd plugin registered — 'ubus list autorecorder' succeeded"
else
    WARN "autorecorder not listed by ubus after rpcd restart"
    WARN "Possible causes:"
    WARN "  - rpcd still initialising (wait 5 s and retry: ubus list autorecorder)"
    WARN "  - Plugin syntax error: sh -n /usr/libexec/rpcd/autorecorder"
    WARN "  - Plugin not executable: ls -la /usr/libexec/rpcd/autorecorder"
    WARN "  - rpcd not running: pgrep rpcd || /etc/init.d/rpcd restart"
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
printf "  ${BOLD}v4.8 forensic fixes:${RESET}\n"
printf "    [W] arecord --dump-hw-params: -d 1 /dev/null prevents pipe-fill\n"
printf "        deadlock that caused rpcd watchdog kill -> probe '(no output)'\n"
printf "    [X] json_str: carriage-return (\\r) added to tr/sed escape pipeline\n"
printf "    [Y] is_running: ubus service list as primary detection tier;\n"
printf "        immune to procd cmdline-representation differences\n"
printf "    [Z] disk_status/get_config: mount path escaped via json_str()\n"
printf "\n"
printf "  ${BOLD}v4.7 LuCI fixes retained:${RESET}\n"
printf "    [S] PID file /var/run/autorecorder.pid (recorder -> rpcd handshake)\n"
printf "    [T] is_running() uses PID file + /proc scan (pgrep -f removed)\n"
printf "    [U] status JSON always valid — pid field always numeric\n"
printf "    [V] luci-app-autorecorder explicitly granted to rpcd root session\n"
printf "\n"
printf "  ${BOLD}All v4.6 fixes retained:${RESET}\n"
printf "    [A] Disk stays mounted for supervisor lifetime\n"
printf "    [B] UUID-based device resolution (USB reconnect resilience)\n"
printf "    [J] procd respawn enabled\n"
printf "    [O] Single START/STOP toggle button\n"
printf "    [M] Probe returns ALSA + storage + block device diagnostics\n"
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

# ── [FIX-AA] Mandatory logout/login warning ───────────────────────────────────
# rpcd restart destroys ALL active in-memory sessions.  The browser-side
# session cookie (held by any open LuCI tab) is now invalid.  In older LuCI
# (OpenWrt 21.x/22.x), ubus PERMISSION_DENIED resolves to {} rather than
# rejecting the JS Promise, so rpc.declare silently returns its expect-schema
# defaults.  ALL three failure symptoms persist until the user logs out and
# back in to create a session that carries the luci-app-autorecorder grant.
printf "${RED}${BOLD}+----------------------------------------------------------+${RESET}\n"
printf "${RED}${BOLD}|   ACTION REQUIRED — do this NOW before opening LuCI     |${RESET}\n"
printf "${RED}${BOLD}|                                                          |${RESET}\n"
printf "${RED}${BOLD}|   1. Open LuCI in your browser                          |${RESET}\n"
printf "${RED}${BOLD}|   2. LOG OUT  (top-right menu -> Logout)                |${RESET}\n"
printf "${RED}${BOLD}|   3. LOG IN   again with your credentials               |${RESET}\n"
printf "${RED}${BOLD}|                                                          |${RESET}\n"
printf "${RED}${BOLD}|   Without this step the page will ALWAYS show:          |${RESET}\n"
printf "${RED}${BOLD}|     Recorder: Stopped   (even while recording)          |${RESET}\n"
printf "${RED}${BOLD}|     Storage:  Not mounted (even when mounted)           |${RESET}\n"
printf "${RED}${BOLD}|     Probe:    (no output)                               |${RESET}\n"
printf "${RED}${BOLD}|                                                          |${RESET}\n"
printf "${RED}${BOLD}|   Why: rpcd restart invalidated your session token.     |${RESET}\n"
printf "${RED}${BOLD}|   A new login creates a session with the ACL grant.     |${RESET}\n"
printf "${RED}${BOLD}+----------------------------------------------------------+${RESET}\n"
printf "\n"
