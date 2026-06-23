#!/bin/sh
#
# install_luci_vumeters_alsa.sh
#
# OpenWrt 24.x / LuCI-compatible installer.
#
# Installs a live ALSA capture VU meter page in LuCI.  One meter per input
# channel is shown; the grid is built automatically once the capture daemon
# publishes the channel count via /tmp/luci-vumeters/levels.json.
#
# No Python or C helpers are required.  The capture daemon is a plain shell
# script using arecord, od, and awk.
#
# Usage:
#   sh install_luci_vumeters_alsa.sh
#   sh install_luci_vumeters_alsa.sh --device plughw:1,0 --channels auto --rate auto
#   sh install_luci_vumeters_alsa.sh --device plughw:1,0 --channels 48 --rate 48000
#   sh install_luci_vumeters_alsa.sh --max-cols 8 --poll-ms 100
#
# After installation:
#   LuCI -> Status -> VU Meters

set -eu

CAPTURE_DEVICE="auto"
CHANNELS="auto"
SAMPLE_RATE="auto"
POLL_MS="200"
FRAMES_PER_UPDATE="4096"
MAX_COLUMNS="16"
ENABLED="1"

UCI_CONF="luci_vumeters"
UCI_SECTION="settings"
UCI_CONF_FILE="/etc/config/${UCI_CONF}"

VIEW_DIR="/www/luci-static/resources/view/vumeters"
VIEW_FILE="${VIEW_DIR}/vumeters.js"
MENU_FILE="/usr/share/luci/menu.d/luci-app-vumeters.json"
ACL_FILE="/usr/share/rpcd/acl.d/luci-app-vumeters.json"
CAPTURE_SCRIPT="/usr/sbin/luci-vumeters-capture"
LEVELS_SCRIPT="/usr/libexec/luci-vumeters-levels"
INIT_FILE="/etc/init.d/luci_vumeters"

usage() {
	cat <<EOF_USAGE
Usage: sh $0 [options]

Options:
  --device DEV       ALSA capture device. Default: auto
                     auto selects the capture interface with most channels.
                     Examples: plughw:1,0  hw:1,0  default
  --channels N|auto  Capture channel count. Default: auto
  --rate N|auto      Capture sample rate. Default: auto (prefers 48000 Hz)
  --poll-ms N        Browser polling interval in ms, 50-5000. Default: ${POLL_MS}
  --frames N         ALSA frames per level update, 256-65536. Default: ${FRAMES_PER_UPDATE}
  --max-cols N       Maximum VU meters per row, 1-16. Default: ${MAX_COLUMNS}
  --disable          Install but do not enable/start the capture service.
  -h, --help         Show this help
EOF_USAGE
}

is_uint() {
	case "$1" in
		''|*[!0-9]*) return 1 ;;
		*) return 0 ;;
	esac
}

check_uint_range() {
	name="$1"; value="$2"; min="$3"; max="$4"
	if ! is_uint "$value"; then
		echo "Invalid ${name}: ${value}" >&2; exit 1
	fi
	if [ "$value" -lt "$min" ] || [ "$value" -gt "$max" ]; then
		echo "Invalid ${name}: ${value}; expected ${min}-${max}" >&2; exit 1
	fi
}

check_auto_or_uint_range() {
	name="$1"; value="$2"; min="$3"; max="$4"
	[ "$value" = "auto" ] && return 0
	check_uint_range "$name" "$value" "$min" "$max"
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--device)
			[ "$#" -ge 2 ] || { usage >&2; exit 1; }
			CAPTURE_DEVICE="$2"; shift 2 ;;
		--channels)
			[ "$#" -ge 2 ] || { usage >&2; exit 1; }
			CHANNELS="$2"; shift 2 ;;
		--rate)
			[ "$#" -ge 2 ] || { usage >&2; exit 1; }
			SAMPLE_RATE="$2"; shift 2 ;;
		--poll-ms)
			[ "$#" -ge 2 ] || { usage >&2; exit 1; }
			POLL_MS="$2"; shift 2 ;;
		--frames)
			[ "$#" -ge 2 ] || { usage >&2; exit 1; }
			FRAMES_PER_UPDATE="$2"; shift 2 ;;
		--max-cols|--max-columns)
			[ "$#" -ge 2 ] || { usage >&2; exit 1; }
			MAX_COLUMNS="$2"; shift 2 ;;
		--disable)
			ENABLED="0"; shift ;;
		-h|--help)
			usage; exit 0 ;;
		*)
			echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
	esac
done

check_auto_or_uint_range "channels"  "$CHANNELS"          1     256
check_auto_or_uint_range "rate"      "$SAMPLE_RATE"       8000  384000
check_uint_range          "poll-ms"  "$POLL_MS"           50    5000
check_uint_range          "frames"   "$FRAMES_PER_UPDATE" 256   65536
check_uint_range          "max-cols" "$MAX_COLUMNS"       1     16

if [ "$(id -u)" != "0" ]; then
	echo "Run this script as root on the OpenWrt router." >&2; exit 1
fi

if [ ! -d "/usr/share/luci/menu.d" ] || [ ! -d "/www/luci-static/resources" ]; then
	echo "LuCI paths not found. Install LuCI first: opkg update && opkg install luci" >&2; exit 1
fi

if ! command -v uci >/dev/null 2>&1; then
	echo "uci not found; this does not look like an OpenWrt system." >&2; exit 1
fi

if ! command -v arecord >/dev/null 2>&1; then
	echo "Warning: arecord not found. The page will install, but capture needs alsa-utils." >&2
fi

backup_if_exists() {
	file="$1"
	if [ -f "$file" ]; then
		ts="$(date +%Y%m%d%H%M%S 2>/dev/null || echo backup)"
		cp -p "$file" "${file}.bak.${ts}"
	fi
}

umask 022

mkdir -p "$VIEW_DIR" \
         "$(dirname "$MENU_FILE")" \
         "$(dirname "$ACL_FILE")" \
         "$(dirname "$LEVELS_SCRIPT")" \
         "$(dirname "$CAPTURE_SCRIPT")" \
         "$(dirname "$INIT_FILE")"

backup_if_exists "$VIEW_FILE"
backup_if_exists "$MENU_FILE"
backup_if_exists "$ACL_FILE"
backup_if_exists "$CAPTURE_SCRIPT"
backup_if_exists "$LEVELS_SCRIPT"
backup_if_exists "$INIT_FILE"

# Ensure the config file exists before rpcd ever tries to uci-load it.
# rpcd ubus code 4 ("Resource not found") fires if /etc/config/<name>
# is absent, which crashes the entire LuCI view before render() runs.
[ -f "$UCI_CONF_FILE" ] || : > "$UCI_CONF_FILE"
uci -q revert "$UCI_CONF" 2>/dev/null || true

uci -q batch <<EOF_UCI
set ${UCI_CONF}.${UCI_SECTION}=settings
set ${UCI_CONF}.${UCI_SECTION}.capture_device='${CAPTURE_DEVICE}'
set ${UCI_CONF}.${UCI_SECTION}.channels='${CHANNELS}'
set ${UCI_CONF}.${UCI_SECTION}.sample_rate='${SAMPLE_RATE}'
set ${UCI_CONF}.${UCI_SECTION}.poll_ms='${POLL_MS}'
set ${UCI_CONF}.${UCI_SECTION}.frames_per_update='${FRAMES_PER_UPDATE}'
set ${UCI_CONF}.${UCI_SECTION}.max_columns='${MAX_COLUMNS}'
set ${UCI_CONF}.${UCI_SECTION}.enabled='${ENABLED}'
commit ${UCI_CONF}
EOF_UCI

if ! uci -q get "${UCI_CONF}.${UCI_SECTION}" >/dev/null 2>&1; then
	echo "Warning: uci commit did not persist; writing ${UCI_CONF_FILE} directly." >&2
	cat > "$UCI_CONF_FILE" <<EOF_UCI_FALLBACK
config settings '${UCI_SECTION}'
	option capture_device '${CAPTURE_DEVICE}'
	option channels '${CHANNELS}'
	option sample_rate '${SAMPLE_RATE}'
	option poll_ms '${POLL_MS}'
	option frames_per_update '${FRAMES_PER_UPDATE}'
	option max_columns '${MAX_COLUMNS}'
	option enabled '${ENABLED}'
EOF_UCI_FALLBACK
fi

# ---- menu.d ------------------------------------------------------------------

cat > "$MENU_FILE" <<'EOF_MENU'
{
	"admin/status/vumeters": {
		"title": "VU Meters",
		"order": 98,
		"action": {
			"type": "view",
			"path": "vumeters/vumeters"
		},
		"depends": {
			"acl": [ "luci-app-vumeters" ]
		}
	}
}
EOF_MENU

# ---- ACL ---------------------------------------------------------------------

cat > "$ACL_FILE" <<'EOF_ACL'
{
	"luci-app-vumeters": {
		"description": "Grant access to the LuCI ALSA VU meters page",
		"read": {
			"uci": [ "luci_vumeters" ],
			"ubus": {
				"file": [ "exec" ]
			},
			"file": {
				"/usr/libexec/luci-vumeters-levels": [ "exec" ]
			}
		},
		"write": {
			"uci": [ "luci_vumeters" ]
		}
	}
}
EOF_ACL

# ---- Levels helper -----------------------------------------------------------
# Called by the LuCI view via fs.exec().  It just serves the state file that
# the capture daemon maintains.  No blocking I/O; designed to return quickly.

cat > "$LEVELS_SCRIPT" <<'EOF_LEVELS'
#!/bin/sh

STATE_FILE="/tmp/luci-vumeters/levels.json"
CAPTURE_SCRIPT="/usr/sbin/luci-vumeters-capture"

# Fast path: daemon is running and has published at least one update.
if [ -s "$STATE_FILE" ]; then
	cat "$STATE_FILE"
	exit 0
fi

# Slow path: daemon hasn't written anything yet (first boot, no device).
# Run a quick auto-detect so the browser can at least size the grid.
if [ -x "$CAPTURE_SCRIPT" ]; then
	"$CAPTURE_SCRIPT" detect 2>/dev/null && exit 0
fi

printf '%s\n' '{"ok":false,"timestamp":0,"device":"","channels":0,"rate":0,"values":[],"message":"no ALSA VU meter state available"}'
exit 0
EOF_LEVELS

# ---- Capture daemon ----------------------------------------------------------
# Runs as a procd service.  Detects or uses the configured ALSA device, then
# pipes arecord -> od -> awk in a tight loop, writing a JSON state file on
# every N-frame boundary.
#
# Key design decisions vs a naive implementation:
#   od -tu2     Outputs raw PCM as unsigned 16-bit decimal (one value per
#               sample).  On little-endian hardware this matches S16_LE
#               directly, halving awk field reads vs the old -tu1 / byte-pair
#               approach and eliminating the have_lo state machine entirely.
#   atomic mv   awk writes to a .tmp file then mv(1) renames it atomically,
#               so the levels helper never reads a partial JSON object.
#   mv "A B"    All paths are under /tmp/luci-vumeters/ with no spaces, so
#               the unquoted system("mv " ...) call is safe.

cat > "$CAPTURE_SCRIPT" <<'EOF_CAPTURE'
#!/bin/sh

CONF="luci_vumeters"
SECTION="settings"
STATE_DIR="/tmp/luci-vumeters"
STATE_FILE="${STATE_DIR}/levels.json"
ERR_FILE="${STATE_DIR}/capture.err"
DEFAULT_RATE="48000"
DEFAULT_FRAMES="4096"
MAX_CHANNELS="256"
FORMAT="S16_LE"

mkdir -p "$STATE_DIR"

is_uint() {
	case "$1" in
		''|*[!0-9]*) return 1 ;;
		*) return 0 ;;
	esac
}

uci_get() {
	key="$1"; def="$2"
	val="$(uci -q get "${CONF}.${SECTION}.${key}" 2>/dev/null || true)"
	[ -n "$val" ] && printf '%s\n' "$val" || printf '%s\n' "$def"
}

# Escape a string for use as a JSON value.  Device names and messages do not
# normally contain control characters, so replacing them with spaces plus
# escaping backslash and double-quote covers all realistic inputs.
json_escape() {
	printf '%s' "$1" | tr '\000-\037\\' '   \\' | sed 's/"/\\"/g'
}

zero_values() {
	n="$1"; i=1
	printf '['
	while [ "$i" -le "$n" ]; do
		[ "$i" -gt 1 ] && printf ','
		printf '0'
		i=$((i + 1))
	done
	printf ']'
}

emit_json() {
	outfile="$1"; ok="$2"; channels="$3"; rate="$4"
	values="$5"; device="$6"; message="$7"

	is_uint "$channels" || channels="0"
	is_uint "$rate"     || rate="0"
	case "$values" in \[*\]) ;; *) values="[]" ;; esac

	now="$(date +%s 2>/dev/null || echo 0)"
	dev_json="$(json_escape "$device")"
	msg_json="$(json_escape "$message")"

	line="$(printf '{"ok":%s,"timestamp":%s,"device":"%s","channels":%s,"rate":%s,"values":%s,"message":"%s"}\n' \
		"$ok" "$now" "$dev_json" "$channels" "$rate" "$values" "$msg_json")"

	if [ "$outfile" = "-" ]; then
		printf '%s\n' "$line"
	else
		tmp="${outfile}.$$"
		printf '%s\n' "$line" > "$tmp"
		mv "$tmp" "$outfile"
	fi
}

# Parse channel count and preferred rate from /proc/asound/cardN/streamM.
stream_caps() {
	awk '
		BEGIN { cap=0; ch=0; first_rate=0; preferred_rate=0 }
		/^[[:space:]]*Capture:/  { cap=1; next }
		/^[[:space:]]*Playback:/ { cap=0; next }
		cap && /^[[:space:]]*Channels:/ {
			line=$0; gsub(/[^0-9]+/," ",line)
			n=split(line,a," ")
			for(i=1;i<=n;i++) { v=a[i]+0; if(v>ch) ch=v }
		}
		cap && /^[[:space:]]*Rates:/ {
			line=$0; gsub(/[^0-9]+/," ",line)
			n=split(line,a," ")
			for(i=1;i<=n;i++) {
				r=a[i]+0; if(r<=0) continue
				if(first_rate==0) first_rate=r
				if(r==48000) preferred_rate=48000
			}
		}
		END {
			rate = preferred_rate ? preferred_rate : first_rate
			if(rate==0) rate=48000
			if(ch>0) print ch " " rate
		}
	' "$1"
}

caps_for_card_dev() {
	card="$1"; dev="$2"
	stream_file="/proc/asound/card${card}/stream${dev}"

	if [ -r "$stream_file" ]; then
		stream_caps "$stream_file"
		return 0
	fi

	best_ch="0"; best_rate="$DEFAULT_RATE"
	for f in "/proc/asound/card${card}"/stream*; do
		[ -r "$f" ] || continue
		caps="$(stream_caps "$f" 2>/dev/null || true)"
		[ -n "$caps" ] || continue
		set -- $caps
		[ "$1" -gt "$best_ch" ] && { best_ch="$1"; best_rate="$2"; }
	done
	[ "$best_ch" -gt 0 ] && printf '%s %s\n' "$best_ch" "$best_rate"
}

parse_card_dev_from_device() {
	printf '%s\n' "$1" | sed -n \
		's/^[^:]*hw:\([0-9][0-9]*\),\([0-9][0-9]*\).*$/\1 \2/p'
}

detect_usb_capture() {
	best_card=""; best_dev=""; best_ch="0"; best_rate="$DEFAULT_RATE"

	for f in /proc/asound/card[0-9]*/stream[0-9]*; do
		[ -r "$f" ] || continue
		card="$(printf '%s' "$f" | sed -n 's#.*/card\([0-9]*\)/stream.*#\1#p')"
		dev="$(printf '%s'  "$f" | sed -n 's#.*/stream\([0-9]*\)$#\1#p')"
		[ -n "$card" ] && [ -n "$dev" ] || continue
		caps="$(stream_caps "$f" 2>/dev/null || true)"
		[ -n "$caps" ] || continue
		set -- $caps
		if [ "$1" -gt "$best_ch" ]; then
			best_card="$card"; best_dev="$dev"; best_ch="$1"; best_rate="$2"
		fi
	done

	[ "$best_ch" -gt 0 ] || return 1
	printf 'plughw:%s,%s|%s|%s|USB capture card %s device %s\n' \
		"$best_card" "$best_dev" "$best_ch" "$best_rate" "$best_card" "$best_dev"
}

detect_arecord_capture() {
	line="$(arecord -l 2>/dev/null | \
		sed -n 's/^card \([0-9]*\):.* device \([0-9]*\):.*/\1 \2/p' | sed -n '1p')"
	[ -n "$line" ] || return 1
	set -- $line
	card="$1"; dev="$2"
	caps="$(caps_for_card_dev "$card" "$dev" 2>/dev/null || true)"
	if [ -n "$caps" ]; then
		set -- $caps; ch="$1"; rate="$2"
	else
		ch="2"; rate="$DEFAULT_RATE"
	fi
	printf 'plughw:%s,%s|%s|%s|ALSA capture card %s device %s\n' \
		"$card" "$dev" "$ch" "$rate" "$card" "$dev"
}

resolve_capture() {
	configured_device="$(uci_get capture_device   auto)"
	configured_channels="$(uci_get channels       auto)"
	configured_rate="$(uci_get    sample_rate      auto)"

	device=""; channels=""; rate=""; message=""

	if [ "$configured_device" = "auto" ]; then
		det="$(detect_usb_capture 2>/dev/null || true)"
		[ -n "$det" ] || det="$(detect_arecord_capture 2>/dev/null || true)"
		if [ -z "$det" ]; then
			echo "no ALSA capture device found" >&2; return 1
		fi
		old_ifs="$IFS"; IFS='|'; set -- $det; IFS="$old_ifs"
		device="$1"; channels="$2"; rate="$3"; message="$4"
	else
		device="$configured_device"
		message="configured ALSA capture device ${configured_device}"
		card_dev="$(parse_card_dev_from_device "$configured_device")"
		if [ -n "$card_dev" ]; then
			set -- $card_dev
			caps="$(caps_for_card_dev "$1" "$2" 2>/dev/null || true)"
			if [ -n "$caps" ]; then
				set -- $caps; channels="$1"; rate="$2"
			fi
		fi
	fi

	if [ "$configured_channels" != "auto" ]; then
		is_uint "$configured_channels" && \
		[ "$configured_channels" -ge 1 ] && \
		[ "$configured_channels" -le "$MAX_CHANNELS" ] || {
			echo "invalid configured channel count: ${configured_channels}" >&2; return 1
		}
		channels="$configured_channels"
	fi

	if [ -z "$channels" ]; then
		echo "channel count not detected; set luci_vumeters.settings.channels" >&2; return 1
	fi

	is_uint "$channels" && [ "$channels" -ge 1 ] && [ "$channels" -le "$MAX_CHANNELS" ] || {
		echo "invalid detected channel count: ${channels}" >&2; return 1
	}

	if [ "$configured_rate" != "auto" ]; then
		is_uint "$configured_rate" && \
		[ "$configured_rate" -ge 8000 ] && \
		[ "$configured_rate" -le 384000 ] || {
			echo "invalid configured sample rate: ${configured_rate}" >&2; return 1
		}
		rate="$configured_rate"
	fi

	[ -n "$rate" ] && is_uint "$rate" || rate="$DEFAULT_RATE"
	printf '%s|%s|%s|%s\n' "$device" "$channels" "$rate" "$message"
}

detect_json() {
	det_file="${STATE_DIR}/detect.$$"
	err_file="${STATE_DIR}/detect_err.$$"
	if resolve_capture > "$det_file" 2> "$err_file"; then
		old_ifs="$IFS"; IFS='|'; set -- $(cat "$det_file"); IFS="$old_ifs"
		device="$1"; channels="$2"; rate="$3"
		message="$4; capture daemon has not published samples yet"
		emit_json - false "$channels" "$rate" "$(zero_values "$channels")" "$device" "$message"
	else
		err="$(cat "$err_file" 2>/dev/null || true)"
		[ -n "$err" ] || err="capture detection failed"
		emit_json - false 0 0 "[]" "" "$err"
	fi
	rm -f "$det_file" "$err_file"
}

run_capture() {
	while :; do
		# Check required tools once per retry cycle.
		missing=""
		for tool in arecord od awk; do
			command -v "$tool" >/dev/null 2>&1 || missing="$tool"
		done
		if [ -n "$missing" ]; then
			emit_json "$STATE_FILE" false 0 0 "[]" "" \
				"${missing} not found; install alsa-utils"
			sleep 10
			continue
		fi

		resolve_file="${STATE_DIR}/resolved.$$"
		if ! resolve_capture > "$resolve_file" 2> "$ERR_FILE"; then
			err="$(cat "$ERR_FILE" 2>/dev/null || true)"
			[ -n "$err" ] || err="capture configuration failed"
			emit_json "$STATE_FILE" false 0 0 "[]" "" "$err"
			rm -f "$resolve_file"
			sleep 5
			continue
		fi

		old_ifs="$IFS"; IFS='|'; set -- $(cat "$resolve_file"); IFS="$old_ifs"
		rm -f "$resolve_file"
		device="$1"; channels="$2"; rate="$3"; message="$4"

		frames="$(uci_get frames_per_update "$DEFAULT_FRAMES")"
		{ is_uint "$frames" && [ "$frames" -ge 256 ] && [ "$frames" -le 65536 ]; } \
			|| frames="$DEFAULT_FRAMES"

		emit_json "$STATE_FILE" true "$channels" "$rate" \
			"$(zero_values "$channels")" "$device" "${message}; capture starting"

		dev_json="$(json_escape "$device")"
		msg_json="$(json_escape "$message")"
		tmp_file="${STATE_FILE}.tmp"
		rm -f "$ERR_FILE"

		# Pipeline:  arecord -> od -> awk
		#
		# od -An -v -tu2
		#   Outputs one unsigned decimal 16-bit word per sample.  On any
		#   little-endian machine (all ARM/x86 OpenWrt targets) this gives the
		#   correct S16_LE value directly.  Absolute value for peak detection:
		#   if word > 32767 then abs = 65536 - word.
		#
		#   Compared to the -tu1 / byte-pair approach this halves awk field
		#   reads and removes the have_lo state machine, cutting per-sample
		#   CPU cost roughly in half on low-power SBCs.
		#
		# The awk script emits JSON to a .tmp file then calls mv(1) for an
		# atomic rename; the levels helper therefore always reads a complete
		# JSON object or nothing at all.
		arecord -q \
			-D "$device" -t raw -f "$FORMAT" \
			-c "$channels" -r "$rate" - 2> "$ERR_FILE" | \
		od -An -v -tu2 | \
		awk \
			-v ch="$channels"   \
			-v frames="$frames" \
			-v out="$STATE_FILE" \
			-v tmp="$tmp_file"  \
			-v dev="$dev_json"  \
			-v msg="$msg_json"  \
			-v rate="$rate"     \
		'
		BEGIN {
			for (i = 1; i <= ch; i++) peak[i] = 0
			sample_index = 0
			frames_seen  = 0
			sequence     = 0
		}
		{
			for (i = 1; i <= NF; i++) {
				s = $i + 0
				# Unsigned 16-bit -> absolute value (two-complement mirror)
				if (s > 32767) s = 65536 - s

				c = (sample_index % ch) + 1
				if (s > peak[c]) peak[c] = s
				sample_index++

				if (c == ch) {
					frames_seen++
					if (frames_seen >= frames) {
						sequence++
						printf("{\"ok\":true,\"timestamp\":%d,\"sequence\":%d," \
						       "\"device\":\"%s\",\"channels\":%d,\"rate\":%d," \
						       "\"values\":[",
						       systime(), sequence, dev, ch, rate) > tmp
						for (j = 1; j <= ch; j++) {
							pct = int((peak[j] * 100 + 16383) / 32767)
							if (pct > 100) pct = 100
							if (j > 1) printf(",") > tmp
							printf("%d", pct) > tmp
							peak[j] = 0
						}
						printf("],\"message\":\"%s\"}\n", msg) > tmp
						close(tmp)
						system("mv " tmp " " out)
						frames_seen = 0
					}
				}
			}
		}
		'

		err="$(cat "$ERR_FILE" 2>/dev/null || true)"
		[ -n "$err" ] || err="capture pipeline stopped"
		emit_json "$STATE_FILE" false "$channels" "$rate" \
			"$(zero_values "$channels")" "$device" "$err"
		sleep 2
	done
}

case "${1:-run}" in
	run)     run_capture ;;
	detect)  detect_json ;;
	*)       echo "Usage: $0 [run|detect]" >&2; exit 1 ;;
esac
EOF_CAPTURE

# ---- Init script -------------------------------------------------------------

cat > "$INIT_FILE" <<'EOF_INIT'
#!/bin/sh /etc/rc.common

START=99
STOP=10
USE_PROCD=1

PROG="/usr/sbin/luci-vumeters-capture"
CONF="luci_vumeters"
SECTION="settings"

start_service() {
	enabled="$(uci -q get "${CONF}.${SECTION}.enabled" 2>/dev/null || echo 1)"
	[ "$enabled" = "0" ] && return 0

	procd_open_instance
	procd_set_param command "$PROG" run
	# threshold=5s  delay=5s  max_fail=0 (unlimited retries)
	# A short threshold is intentional: the device may be unplugged at any
	# time, which kills arecord quickly.  We want procd to restart promptly
	# and without giving up after N attempts.
	procd_set_param respawn 5 5 0
	procd_set_param stderr 1
	procd_close_instance
}

reload_service() {
	stop
	start
}
EOF_INIT

# ---- LuCI view ---------------------------------------------------------------

cat > "$VIEW_FILE" <<'EOF_VIEW'
'use strict';
'require view';
'require uci';
'require fs';

var CONF           = 'luci_vumeters';
var SECTION        = 'settings';
var LEVELS_HELPER  = '/usr/libexec/luci-vumeters-levels';

var MAX_COLUMNS_DEFAULT = 16;
var MAX_CHANNELS        = 256;

// ---- Performance constants --------------------------------------------------
// See comments in the shared rendering engine (vumeters3.sh) for rationale.

var MIN_BOX_PX               = 4;
var PEAK_GLOW_MAX_CHANNELS   = 32;
var FPS_SMALL_GRID           = 60;
var FPS_BIG_GRID             = 30;
var BIG_GRID_CHANNEL_THRESHOLD = 12;
var EASE_DIVISOR             = 3;
var SETTLE_EPSILON           = 0.5;

var COLOR_GREEN_ON   = 'rgba(53,255,30,0.9)';
var COLOR_GREEN_OFF  = 'rgba(13,64,8,0.9)';
var COLOR_YELLOW_ON  = 'rgba(255,215,5,0.9)';
var COLOR_YELLOW_OFF = 'rgba(64,53,0,0.9)';
var COLOR_RED_ON     = 'rgba(255,47,30,0.9)';
var COLOR_RED_OFF    = 'rgba(64,12,8,0.9)';
var BG_COLOR         = 'rgb(32,32,32)';
var BOX_GAP_FRACTION = 0.2;

function clampInt(value, min, max, fallback) {
	var n = parseInt(value, 10);
	if (isNaN(n)) n = fallback;
	if (n < min)  n = min;
	if (n > max)  n = max;
	return n;
}

function clampMeterValue(value) {
	var n = parseInt(value, 10);
	if (isNaN(n)) n = 0;
	if (n < 0)    n = 0;
	if (n > 100)  n = 100;
	return n;
}

function injectStyle() {
	if (document.getElementById('vumeters-style'))
		return;

	document.head.appendChild(E('style', {
		'id': 'vumeters-style',
		'type': 'text/css'
	}, [
		'#vumeters-root {' +
			'width: 100%;' +
			'min-height: calc(100vh - 155px);' +
		'}' +

		'#vumeters-summary {' +
			'display: flex;' +
			'gap: .75em;' +
			'align-items: center;' +
			'flex-wrap: wrap;' +
			'margin: 0 0 .6em 0;' +
			'font-size: .9em;' +
		'}' +

		'#vumeters-summary code {' +
			'white-space: nowrap;' +
		'}' +

		'#vumeters-status {' +
			'margin: 0 0 .6em 0;' +
			'min-height: 1.4em;' +
		'}' +

		// The wrap has a fixed viewport-relative height so the grid can
		// fill it with 1fr rows.  overflow:auto allows scrolling when a
		// large number of channels forces cells below the min-height.
		'#vumeters-grid-wrap {' +
			'width: 100%;' +
			'height: calc(100vh - 250px);' +
			'min-height: 280px;' +
			'overflow: auto;' +
		'}' +

		// min-height:100% makes the grid fill the wrap even for small
		// channel counts; it can grow beyond 100% (and scroll) for many.
		'#vumeters-grid {' +
			'display: grid;' +
			'min-height: 100%;' +
			'gap: 4px;' +
		'}' +

		'.vumeter-cell {' +
			'border: 1px solid rgba(127,127,127,.35);' +
			'padding: 5px;' +
			'min-width: 52px;' +
			'min-height: 110px;' +
			'display: flex;' +
			'flex-direction: column;' +
			'align-items: stretch;' +
		'}' +

		// No fixed height here.  flex:1 1 0 lets the canvas grow to fill
		// whatever height the grid row gives the cell after subtracting
		// padding and the caption.  The canvas pixel dimensions are then
		// set to match offsetWidth/offsetHeight in startMeters() so that
		// buildGeometry() always works with the actual display size.
		'.vumeter-canvas {' +
			'display: block;' +
			'width: 100%;' +
			'flex: 1 1 0;' +
			'min-height: 0;' +
			'background: rgb(32,32,32);' +
			'border-radius: 3px;' +
		'}' +

		'.vumeter-caption {' +
			'margin-top: .3em;' +
			'line-height: 1.2;' +
			'font-size: .82em;' +
			'text-align: center;' +
			'white-space: nowrap;' +
		'}' +

		'.vumeters-placeholder {' +
			'padding: 2em;' +
			'text-align: center;' +
			'border: 1px dashed rgba(127,127,127,.45);' +
		'}'
	]));
}

// ---- Shared rendering engine ------------------------------------------------
// Geometry and per-segment colors are computed once per grid build and shared
// across all channels (all canvases in one grid have the same dimensions).

function pickBoxCount(heightPx) {
	var boxCount = 16;
	while (boxCount > 6) {
		var bh = heightPx / (boxCount + (boxCount + 1) * BOX_GAP_FRACTION);
		if (bh >= MIN_BOX_PX) break;
		boxCount--;
	}
	return boxCount;
}

function deriveZoneCounts(boxCount) {
	var red    = Math.max(1, Math.round(boxCount * 3 / 16));
	var yellow = Math.max(1, Math.round(boxCount * 4 / 16));
	if (red + yellow > boxCount - 1)
		yellow = Math.max(1, boxCount - red - 1);
	return { red: red, yellow: yellow, green: boxCount - red - yellow };
}

function buildGeometry(widthPx, heightPx) {
	var boxCount  = pickBoxCount(heightPx);
	var zones     = deriveZoneCounts(boxCount);
	var boxHeight = heightPx / (boxCount + (boxCount + 1) * BOX_GAP_FRACTION);
	var boxGapY   = boxHeight * BOX_GAP_FRACTION;
	var boxWidth  = widthPx - boxGapY * 2;
	var boxGapX   = (widthPx - boxWidth) / 2;

	var boxX     = new Array(boxCount);
	var boxY     = new Array(boxCount);
	var colorOn  = new Array(boxCount);
	var colorOff = new Array(boxCount);
	var boxId    = new Array(boxCount);

	for (var i = 0; i < boxCount; i++) {
		var id   = Math.abs(i - (boxCount - 1)) + 1;
		boxId[i] = id;
		boxX[i]  = boxGapX;
		boxY[i]  = boxGapY + i * (boxHeight + boxGapY);
		if (id > boxCount - zones.red) {
			colorOn[i] = COLOR_RED_ON;   colorOff[i] = COLOR_RED_OFF;
		} else if (id > boxCount - zones.red - zones.yellow) {
			colorOn[i] = COLOR_YELLOW_ON; colorOff[i] = COLOR_YELLOW_OFF;
		} else {
			colorOn[i] = COLOR_GREEN_ON;  colorOff[i] = COLOR_GREEN_OFF;
		}
	}

	return {
		width: widthPx, height: heightPx,
		boxCount: boxCount, boxWidth: boxWidth, boxHeight: boxHeight,
		boxId: boxId, boxX: boxX, boxY: boxY, colorOn: colorOn, colorOff: colorOff
	};
}

function drawMeter(geom, state, glowEnabled) {
	var ctx       = state.ctx;
	var boxCount  = geom.boxCount;
	var boxId     = geom.boxId;
	var colorOn   = geom.colorOn;
	var colorOff  = geom.colorOff;
	var boxWidth  = geom.boxWidth;
	var boxHeight = geom.boxHeight;

	ctx.fillStyle = BG_COLOR;
	ctx.fillRect(0, 0, geom.width, geom.height);

	var maxOn     = Math.ceil((state.curVal / 100) * boxCount);
	var peakIndex = -1;
	var peakId    = -1;

	for (var i = 0; i < boxCount; i++) {
		var on = geom.boxId[i] <= maxOn;
		ctx.fillStyle = on ? colorOn[i] : colorOff[i];
		ctx.fillRect(geom.boxX[i], geom.boxY[i], boxWidth, boxHeight);
		if (on && boxId[i] > peakId) { peakId = boxId[i]; peakIndex = i; }
	}

	// One glow per meter on the peak LED only; skipped on large grids
	// (PEAK_GLOW_MAX_CHANNELS) because shadowBlur is the most expensive
	// canvas operation and cost scales with total channel count.
	if (glowEnabled && peakIndex >= 0) {
		ctx.save();
		ctx.shadowBlur  = 10;
		ctx.shadowColor = colorOn[peakIndex];
		ctx.fillStyle   = colorOn[peakIndex];
		ctx.fillRect(geom.boxX[peakIndex], geom.boxY[peakIndex], boxWidth, boxHeight);
		ctx.restore();
	}
}

// ---- View entry point -------------------------------------------------------

return view.extend({
	handleSaveApply: null,
	handleSave:      null,
	handleReset:     null,

	load: function() {
		return uci.load(CONF).catch(function(err) {
			console.warn('vumeters: could not load uci config "' + CONF + '":', err);
			return null;
		});
	},

	render: function() {
		injectStyle();

		var channelStates    = [];
		var geom             = null;
		var glowEnabled      = true;
		var frameBudgetMs    = 1000 / FPS_SMALL_GRID;
		var rafHandle        = null;
		var pollTimer        = null;
		var lastFrameTime    = 0;
		var gridRoot         = null;
		var renderedChannels = 0;

		var pollMs     = clampInt(uci.get(CONF, SECTION, 'poll_ms'),     50, 5000,  200);
		var maxColumns = clampInt(uci.get(CONF, SECTION, 'max_columns'),  1,   16,   16);

		var summaryDevice   = E('code', {}, [ '-' ]);
		var summaryChannels = E('code', {}, [ '0' ]);
		var summaryRate     = E('code', {}, [ '-' ]);
		var summaryPoll     = E('code', {}, [ String(pollMs) + ' ms' ]);

		var status = E('div', { 'id': 'vumeters-status', 'class': 'alert-message notice' }, [
			_('Waiting for ALSA input levels...')
		]);

		var grid = E('div', { 'id': 'vumeters-grid' });

		function stopTimers() {
			if (rafHandle !== null) {
				window.cancelAnimationFrame(rafHandle);
				rafHandle = null;
			}
			if (pollTimer !== null) {
				window.clearTimeout(pollTimer);
				pollTimer = null;
			}
			channelStates = [];
		}

		function setChannelValue(channel, value) {
			var state = channelStates[channel - 1];
			if (state)
				state.target = clampMeterValue(value);
		}

		function setAllChannelValues(values) {
			if (!values) return;
			for (var i = 0; i < values.length; i++)
				setChannelValue(i + 1, values[i]);
		}

		// Single shared RAF loop for all channels.
		// No jitter: values come from real ALSA capture data.
		function tick(now) {
			rafHandle = window.requestAnimationFrame(tick);

			if (document.hidden)
				return;

			if (now - lastFrameTime < frameBudgetMs)
				return;

			lastFrameTime = now;

			if (!document.body.contains(gridRoot)) {
				stopTimers();
				return;
			}

			for (var i = 0; i < channelStates.length; i++) {
				var st     = channelStates[i];
				var target = st.target;
				var cur    = st.curVal;
				var changed = false;

				if (cur !== target) {
					cur += (target - cur) / EASE_DIVISOR;
					if (Math.abs(target - cur) < SETTLE_EPSILON)
						cur = target;
					changed = true;
				}

				st.curVal = cur;

				// Idle channels that are already drawn blank are skipped
				// entirely, keeping large grids cheap when audio is quiet.
				if (changed || !st.drawnIdle) {
					drawMeter(geom, st, glowEnabled);
					st.drawnIdle = (cur === 0 && target === 0);
				}
			}
		}

		function startMeters(canvases, root) {
			if (rafHandle !== null) {
				window.cancelAnimationFrame(rafHandle);
				rafHandle = null;
			}

			gridRoot      = root;
			channelStates = [];

			if (canvases.length === 0)
				return;

			// Read the actual rendered canvas dimensions.
			//
			// This call is inside a setTimeout(0) so browser layout has
			// already run; offsetWidth/offsetHeight reflect the real
			// CSS-computed size.  Setting canvas.width/height to these
			// values ensures the canvas pixel buffer matches the display
			// size exactly, so buildGeometry() works with correct numbers
			// instead of the placeholder 64×64 set during DOM construction.
			var w = canvases[0].offsetWidth  || canvases[0].width;
			var h = canvases[0].offsetHeight || canvases[0].height;

			for (var i = 0; i < canvases.length; i++) {
				canvases[i].width  = w;
				canvases[i].height = h;
			}

			geom = buildGeometry(w, h);

			var totalChannels = canvases.length;
			glowEnabled   = totalChannels <= PEAK_GLOW_MAX_CHANNELS;
			frameBudgetMs = 1000 / (totalChannels > BIG_GRID_CHANNEL_THRESHOLD
				? FPS_BIG_GRID : FPS_SMALL_GRID);

			channelStates = new Array(totalChannels);

			for (var j = 0; j < canvases.length; j++) {
				var ctx = canvases[j].getContext('2d');
				ctx.fillStyle = BG_COLOR;
				ctx.fillRect(0, 0, geom.width, geom.height);
				channelStates[j] = { ctx: ctx, curVal: 0, target: 0, drawnIdle: true };
			}

			window.setVuChannelValue  = setChannelValue;
			window.setVuChannelValues = setAllChannelValues;

			lastFrameTime = 0;
			rafHandle = window.requestAnimationFrame(tick);
		}

		function renderGrid(channelCount, root) {
			var canvases = [];
			var channels = clampInt(channelCount, 0, MAX_CHANNELS, 0);
			var cols     = channels > 0 ? Math.min(maxColumns, channels) : 1;
			var rows     = channels > 0 ? Math.ceil(channels / cols) : 1;

			renderedChannels = channels;

			// Distribute columns and rows evenly across the available space.
			// 1fr rows require the grid itself to have a height; that comes
			// from min-height:100% on #vumeters-grid and the fixed height on
			// #vumeters-grid-wrap.
			grid.style.gridTemplateColumns = 'repeat(' + cols + ', minmax(0, 1fr))';
			grid.style.gridTemplateRows    = 'repeat(' + rows + ', 1fr)';

			while (grid.firstChild)
				grid.removeChild(grid.firstChild);

			if (channels === 0) {
				grid.appendChild(E('div', { 'class': 'vumeters-placeholder' }, [
					_('No ALSA capture channels detected yet.')
				]));
				// Cancel any running RAF loop; nothing to draw.
				if (rafHandle !== null) {
					window.cancelAnimationFrame(rafHandle);
					rafHandle = null;
				}
				channelStates = [];
				return;
			}

			for (var channel = 1; channel <= channels; channel++) {
				// Placeholder 64×64 canvas; real dimensions are read from
				// offsetWidth/offsetHeight in startMeters() after layout.
				var canvas = E('canvas', {
					'class': 'vumeter-canvas',
					'width':  '64',
					'height': '64',
					'data-channel': String(channel)
				});

				canvases.push(canvas);

				grid.appendChild(E('div', { 'class': 'vumeter-cell' }, [
					canvas,
					E('div', { 'class': 'vumeter-caption' }, [ 'IN ' + channel ])
				]));
			}

			// setTimeout(0): yield to the browser so it performs a layout
			// pass before startMeters() reads offsetWidth/offsetHeight.
			window.setTimeout(function() {
				startMeters(canvases, root);
			}, 0);
		}

		function updateMetadata(data) {
			summaryDevice.textContent   = data.device || '-';
			summaryChannels.textContent = String(clampInt(data.channels, 0, MAX_CHANNELS, 0));
			summaryRate.textContent     = data.rate ? String(data.rate) + ' Hz' : '-';
			summaryPoll.textContent     = String(pollMs) + ' ms';

			if (data.ok) {
				status.className   = 'alert-message notice';
				status.textContent = data.message || _('Capturing ALSA input levels.');
			} else {
				status.className   = 'alert-message warning';
				status.textContent = data.message || _('Waiting for ALSA input levels.');
			}
		}

		function handleLevelsReply(res, root) {
			var text = (res && res.stdout) ? res.stdout.trim() : '';
			var data;

			try {
				data = JSON.parse(text || '{}');
			} catch (e) {
				throw new Error('JSON parse failed (' + e.message + '): ' + text.slice(0, 120));
			}

			if (!data || typeof data !== 'object')
				throw new Error('unexpected reply from ' + LEVELS_HELPER);

			if (typeof data.channels !== 'number')
				data.channels = parseInt(data.channels || 0, 10) || 0;

			var channels = clampInt(data.channels, 0, MAX_CHANNELS, 0);

			if (channels !== renderedChannels)
				renderGrid(channels, root);

			if (Array.isArray(data.values))
				setAllChannelValues(data.values);

			updateMetadata(data);
		}

		function schedulePoll(root) {
			if (!document.body.contains(root)) {
				stopTimers();
				return;
			}
			pollTimer = window.setTimeout(function() { pollLevels(root); }, pollMs);
		}

		function pollLevels(root) {
			if (!document.body.contains(root)) {
				stopTimers();
				return;
			}

			fs.exec(LEVELS_HELPER, []).then(function(res) {
				// Wrap in try/catch: an uncaught throw here would propagate
				// out of the .then() handler and silently abort the poll
				// chain, freezing the page with no error message.
				try {
					handleLevelsReply(res, root);
				} catch (e) {
					status.className   = 'alert-message error';
					status.textContent = _('Error processing level data: ') + e;
				}
				schedulePoll(root);
			}, function(err) {
				status.className   = 'alert-message error';
				status.textContent = _('Cannot read ALSA VU meter state: ') + err;
				schedulePoll(root);
			});
		}

		var root = E('div', { 'id': 'vumeters-root', 'class': 'cbi-map' }, [
			E('h2', {}, [ _('VU Meters') ]),
			E('div', { 'class': 'cbi-map-descr' }, [
				_('Live ALSA capture input levels. One meter per detected channel.')
			]),
			E('div', { 'id': 'vumeters-summary' }, [
				E('span', {}, [ _('Device'),   ': ', summaryDevice ]),
				E('span', {}, [ _('Channels'), ': ', summaryChannels ]),
				E('span', {}, [ _('Rate'),     ': ', summaryRate ]),
				E('span', {}, [ _('Poll'),     ': ', summaryPoll ])
			]),
			status,
			E('div', { 'id': 'vumeters-grid-wrap' }, [ grid ])
		]);

		renderGrid(0, root);
		pollLevels(root);

		return root;
	}
});
EOF_VIEW

# ---- Permissions -------------------------------------------------------------

chmod 0755 "$CAPTURE_SCRIPT" "$LEVELS_SCRIPT" "$INIT_FILE"
chmod 0644 "$VIEW_FILE" "$MENU_FILE" "$ACL_FILE"

# ---- Cache and service management -------------------------------------------

rm -f /tmp/luci-indexcache 2>/dev/null || true
rm -f /tmp/luci-modulecache/* 2>/dev/null || true

if [ -x /etc/init.d/rpcd ]; then
	/etc/init.d/rpcd restart >/dev/null 2>&1 || true
fi

if [ -x "$INIT_FILE" ]; then
	if [ "$ENABLED" = "1" ]; then
		"$INIT_FILE" enable  >/dev/null 2>&1 || true
		"$INIT_FILE" restart >/dev/null 2>&1 || true
	else
		"$INIT_FILE" disable >/dev/null 2>&1 || true
		"$INIT_FILE" stop    >/dev/null 2>&1 || true
	fi
fi

if [ -x /etc/init.d/uhttpd ]; then
	/etc/init.d/uhttpd reload   >/dev/null 2>&1 || \
	/etc/init.d/uhttpd restart  >/dev/null 2>&1 || true
fi

echo "Installed LuCI ALSA VU Meters."
echo "Open: LuCI -> Status -> VU Meters"
echo "Capture device: ${CAPTURE_DEVICE}  channels: ${CHANNELS}  rate: ${SAMPLE_RATE}  max-cols: ${MAX_COLUMNS}"
if [ "$ENABLED" = "1" ]; then
	echo "Capture service: enabled (/etc/init.d/luci_vumeters)"
else
	echo "Capture service: installed but disabled (--disable was passed)"
fi
INSTALLER_EOF