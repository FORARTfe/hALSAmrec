#!/bin/sh
#
# install_luci_vumeters_alsa.sh
#
# OpenWrt 24.x / LuCI ALSA VU meter installer.
#
# Usage:
#   sh install_luci_vumeters_alsa.sh
#   sh install_luci_vumeters_alsa.sh --device plughw:1,0 --channels 16
#   sh install_luci_vumeters_alsa.sh --max-cols 8 --poll-ms 150
#
# After installation:
#   LuCI -> Status -> VU Meters
#
# If the page shows "Channels: 0", use the configuration panel that appears
# in-page, or re-run with explicit --device / --channels arguments.

set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

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
                     auto = first ALSA capture device detected.
                     Examples: plughw:1,0  hw:1,0
  --channels N|auto  Capture channel count. Default: auto (from hw-params)
  --rate N|auto      Sample rate in Hz. Default: auto (from hw-params, <=48000)
  --poll-ms N        Browser poll interval ms, 50-5000. Default: ${POLL_MS}
  --frames N         ALSA frames per level update, 256-65536. Default: ${FRAMES_PER_UPDATE}
  --max-cols N       Max meters per row, 1-16. Default: ${MAX_COLUMNS}
  --disable          Install but do not start the capture service.
  -h, --help         Show this help
EOF_USAGE
}

valid_uint_range() {
	name="$1"; value="$2"; min="$3"; max="$4"
	case "$value" in ''|*[!0-9]*) echo "Invalid ${name}: ${value}" >&2; exit 1 ;; esac
	if [ "$value" -lt "$min" ] || [ "$value" -gt "$max" ]; then
		echo "Invalid ${name}: ${value}; expected ${min}-${max}" >&2; exit 1
	fi
}

valid_auto_or_uint_range() {
	[ "$2" = "auto" ] && return 0
	valid_uint_range "$@"
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--device)   [ "$#" -ge 2 ] || { usage >&2; exit 1; }; CAPTURE_DEVICE="$2"; shift 2 ;;
		--channels) [ "$#" -ge 2 ] || { usage >&2; exit 1; }; CHANNELS="$2";        shift 2 ;;
		--rate)     [ "$#" -ge 2 ] || { usage >&2; exit 1; }; SAMPLE_RATE="$2";     shift 2 ;;
		--poll-ms)  [ "$#" -ge 2 ] || { usage >&2; exit 1; }; POLL_MS="$2";         shift 2 ;;
		--frames)   [ "$#" -ge 2 ] || { usage >&2; exit 1; }; FRAMES_PER_UPDATE="$2"; shift 2 ;;
		--max-cols|--max-columns)
		            [ "$#" -ge 2 ] || { usage >&2; exit 1; }; MAX_COLUMNS="$2";     shift 2 ;;
		--disable)  ENABLED="0"; shift ;;
		-h|--help)  usage; exit 0 ;;
		*)          echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
	esac
done

valid_auto_or_uint_range "channels"  "$CHANNELS"          1     256
valid_auto_or_uint_range "rate"      "$SAMPLE_RATE"       8000  384000
valid_uint_range          "poll-ms"  "$POLL_MS"           50    5000
valid_uint_range          "frames"   "$FRAMES_PER_UPDATE" 256   65536
valid_uint_range          "max-cols" "$MAX_COLUMNS"       1     16

[ "$(id -u)" = "0" ] || { echo "Run as root." >&2; exit 1; }

[ -d "/usr/share/luci/menu.d" ] && [ -d "/www/luci-static/resources" ] || {
	echo "LuCI not found. Install: opkg update && opkg install luci" >&2; exit 1; }

command -v uci >/dev/null 2>&1 || { echo "uci not found." >&2; exit 1; }

command -v arecord >/dev/null 2>&1 || \
	echo "Warning: arecord not found. Install alsa-utils for live capture." >&2

backup_if_exists() {
	[ -f "$1" ] || return 0
	ts="$(date +%Y%m%d%H%M%S 2>/dev/null || echo bak)"
	cp -p "$1" "${1}.bak.${ts}"
}

umask 022
mkdir -p "$VIEW_DIR" "$(dirname "$MENU_FILE")" "$(dirname "$ACL_FILE")" \
         "$(dirname "$LEVELS_SCRIPT")" "$(dirname "$CAPTURE_SCRIPT")" \
         "$(dirname "$INIT_FILE")"

for f in "$VIEW_FILE" "$MENU_FILE" "$ACL_FILE" \
         "$CAPTURE_SCRIPT" "$LEVELS_SCRIPT" "$INIT_FILE"; do
	backup_if_exists "$f"
done

# Create the UCI config file before rpcd ever tries to load it.
# A missing /etc/config/<name> makes rpcd return ubus code 4 which crashes
# the entire LuCI view before render() runs.
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
	cat > "$UCI_CONF_FILE" <<EOF_FALLBACK
config settings '${UCI_SECTION}'
	option capture_device '${CAPTURE_DEVICE}'
	option channels '${CHANNELS}'
	option sample_rate '${SAMPLE_RATE}'
	option poll_ms '${POLL_MS}'
	option frames_per_update '${FRAMES_PER_UPDATE}'
	option max_columns '${MAX_COLUMNS}'
	option enabled '${ENABLED}'
EOF_FALLBACK
fi

# ---- menu.d ------------------------------------------------------------------

cat > "$MENU_FILE" <<'EOF_MENU'
{
	"admin/status/vumeters": {
		"title": "VU Meters",
		"order": 98,
		"action": { "type": "view", "path": "vumeters/vumeters" },
		"depends": { "acl": [ "luci-app-vumeters" ] }
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
			"ubus": { "file": [ "exec" ] },
			"file": {
				"/usr/libexec/luci-vumeters-levels":  [ "exec" ],
				"/etc/init.d/luci_vumeters":          [ "exec" ]
			}
		},
		"write": { "uci": [ "luci_vumeters" ] }
	}
}
EOF_ACL

# ---- Levels helper -----------------------------------------------------------
# Called by the LuCI view via fs.exec() on every poll cycle.
# Must never block; just serves the state file or triggers a fast probe.

cat > "$LEVELS_SCRIPT" <<'EOF_LEVELS'
#!/bin/sh
STATE_FILE="/tmp/luci-vumeters/levels.json"
CAPTURE_SCRIPT="/usr/sbin/luci-vumeters-capture"

if [ -s "$STATE_FILE" ]; then
	cat "$STATE_FILE"; exit 0
fi

if [ -x "$CAPTURE_SCRIPT" ]; then
	"$CAPTURE_SCRIPT" detect 2>/dev/null && exit 0
fi

printf '%s\n' '{"ok":false,"timestamp":0,"device":"","channels":0,"rate":0,"values":[],"message":"capture service not running"}'
EOF_LEVELS

# ---- Capture daemon ----------------------------------------------------------
#
# Key design decisions (informed by the hALSAmrec recorder codebase):
#
#  arecord --dump-hw-params
#    The ONLY reliable way to get actual channel count, supported formats and
#    buffer parameters from the hardware without starting a full capture.
#    hALSAmrec uses this same approach.  The naive alternative (probing
#    /proc/asound/cardN/streamN) requires CONFIG_SND_VERBOSE_PROCFS which is
#    commonly disabled on embedded kernels — that is why previous VU meter
#    versions returned channels=0 and got stuck at "Waiting…".
#
#  plughw: for capture, hw: for probing
#    The dump must be done on hw: to get the real hardware parameters.
#    Actual capture uses plughw: so ALSA's plug layer converts any native
#    hardware format (S24_3LE, S32_LE, S24_LE …) to S16_LE automatically.
#    This avoids "Invalid argument" errors when the device does not support
#    S16_LE natively, which is the case for most modern USB audio interfaces
#    including the R16.
#
#  arecord -l awk pattern
#    Copied from hALSAmrec: uses match() instead of sed so it handles
#    locale-specific spacing and label variations in arecord output.
#
#  od -An -v -tu2
#    One unsigned 16-bit word per sample.  On any LE host (all ARM/x86
#    OpenWrt targets) this is the correct S16_LE representation.
#    Abs value: s > 32767 → s = 65536 - s.  ~2× faster than -tu1 +
#    byte-pair awk because it halves field iterations and eliminates
#    the have_lo state machine.
#
#  --buffer-time / --buffer-size
#    Passed through from the dump when valid, matching hALSAmrec behaviour.
#    On some devices omitting these causes underruns and pipeline stalls.

cat > "$CAPTURE_SCRIPT" <<'EOF_CAPTURE'
#!/bin/sh
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

CONF="luci_vumeters"
SECTION="settings"
STATE_DIR="/tmp/luci-vumeters"
STATE_FILE="${STATE_DIR}/levels.json"
ERR_FILE="${STATE_DIR}/capture.err"
FORMAT="S16_LE"
DEFAULT_RATE="48000"
DEFAULT_FRAMES="4096"

mkdir -p "$STATE_DIR"

valid_uint() { case "$1" in ''|*[!0-9]*) return 1;; esac; }

uci_get() {
	val="$(uci -q get "${CONF}.${SECTION}.${1}" 2>/dev/null || true)"
	printf '%s\n' "${val:-$2}"
}

json_escape() {
	printf '%s' "$1" | tr '\000-\037\\' '   \\' | sed 's/"/\\"/g'
}

zero_values() {
	i=1; printf '['
	while [ "$i" -le "$1" ]; do
		[ "$i" -gt 1 ] && printf ','
		printf '0'; i=$((i+1))
	done
	printf ']'
}

emit_json() {
	# $1=outfile|- $2=ok $3=ch $4=rate $5=values $6=device $7=message
	valid_uint "$3" || set -- "$1" "$2" "0"  "$4" "$5" "$6" "$7"
	valid_uint "$4" || set -- "$1" "$2" "$3" "0"  "$5" "$6" "$7"
	case "$5" in \[*\]) ;; *) set -- "$1" "$2" "$3" "$4" "[]" "$6" "$7" ;; esac
	now="$(date +%s 2>/dev/null || echo 0)"
	line="$(printf '{"ok":%s,"timestamp":%s,"device":"%s","channels":%s,"rate":%s,"values":%s,"message":"%s"}\n' \
		"$2" "$now" "$(json_escape "$6")" "$3" "$4" "$5" "$(json_escape "$7")")"
	if [ "$1" = "-" ]; then
		printf '%s\n' "$line"
	else
		tmp="${1}.$$"; printf '%s\n' "$line" > "$tmp"; mv "$tmp" "$1"
	fi
}

# ---- Device detection -------------------------------------------------------

# Find the first ALSA capture device; outputs "card:dev".
# /proc/asound/pcm is tried first (non-blocking, no external tools).
# Falls back to arecord -l with the locale-robust awk pattern from hALSAmrec.
find_audio_device() {
	if [ -r /proc/asound/pcm ]; then
		while IFS= read -r line; do
			case "$line" in *capture*) ;; *) continue ;; esac
			card="$(printf '%s' "$line" | sed -n 's/^ *\([0-9][0-9]*\)-.*/\1/p')"
			dev="$(printf '%s'  "$line" | sed -n 's/^ *[0-9][0-9]*-\([0-9][0-9]*\):.*/\1/p')"
			[ -n "$card" ] && [ -n "$dev" ] || continue
			printf '%d:%d\n' "$card" "$dev" 2>/dev/null && return 0 || true
		done < /proc/asound/pcm
	fi

	command -v arecord >/dev/null 2>&1 || return 1

	# Same match()-based awk as hALSAmrec: handles locale spacing variations.
	arecord -l 2>/dev/null | awk '
		/^[[:space:]]*card[[:space:]]+[0-9]+:/ {
			card=""; dev=""
			if (match($0, /card[[:space:]]+[0-9]+/)) {
				card = substr($0, RSTART, RLENGTH)
				sub(/.* /, "", card)
			}
			if (match($0, /device[[:space:]]+[0-9]+/)) {
				dev = substr($0, RSTART, RLENGTH)
				sub(/.* /, "", dev)
			}
			if (card != "" && dev != "") { print card ":" dev; exit }
		}' || true
}

# Probe actual hardware parameters via arecord --dump-hw-params.
# Must be run on hw: (not plughw:) to get real hardware limits.
# Outputs "channels:rate:buf_time:buf_size" or returns 1 on failure.
#
# The dump goes to stderr in arecord; 2>&1 redirects it to stdout
# so it can be captured in a variable — same trick used in hALSAmrec.
probe_hw_params() {
	card_num="$1"; dev_num="$2"
	command -v arecord >/dev/null 2>&1 || return 1

	dump="$(arecord -D "hw:${card_num},${dev_num}" --dump-hw-params 2>&1 || true)"
	[ -n "$dump" ] || return 1

	# Last number on each line = the maximum value (e.g. CHANNELS: [1 16] → 16)
	ch="$(printf '%s\n' "$dump" | awk '
		/^CHANNELS:/    { gsub(/[^0-9]+/," ",$0); n=split($0,a," ")
		                  for(i=n;i>=1;i--) if(a[i]!="") {print a[i];exit} }')"
	rate="$(printf '%s\n' "$dump" | awk '
		/^RATE:/        { gsub(/[^0-9]+/," ",$0); n=split($0,a," ")
		                  for(i=n;i>=1;i--) if(a[i]!="") {print a[i];exit} }')"
	buf_time="$(printf '%s\n' "$dump" | awk '
		/^BUFFER_TIME:/ { gsub(/[^0-9]+/," ",$0); n=split($0,a," ")
		                  for(i=n;i>=1;i--) if(a[i]!="") {print a[i];exit} }')"
	buf_size="$(printf '%s\n' "$dump" | awk '
		/^BUFFER_SIZE:/ { gsub(/[^0-9]+/," ",$0); n=split($0,a," ")
		                  for(i=n;i>=1;i--) if(a[i]!="") {print a[i];exit} }')"

	valid_uint "$ch"       || ch="2"
	valid_uint "$rate"     || rate="$DEFAULT_RATE"
	[ "$rate" -gt 48000 ]  && rate="48000"

	printf '%s:%s:%s:%s\n' "$ch" "$rate" "${buf_time:-}" "${buf_size:-}"
}

# Resolve final capture parameters combining detection, probing and UCI overrides.
# Outputs 7 colon-separated fields: card dev channels rate buf_time buf_size name
resolve_capture() {
	conf_dev="$(uci_get capture_device auto)"
	conf_ch="$(uci_get  channels       auto)"
	conf_rate="$(uci_get sample_rate   auto)"

	if [ "$conf_dev" = "auto" ]; then
		audio_dev="$(find_audio_device 2>/dev/null || true)"
		if [ -z "$audio_dev" ]; then
			echo "no ALSA capture device found in /proc/asound or via arecord -l" >&2
			return 1
		fi
		card_num="${audio_dev%%:*}"
		dev_num="${audio_dev##*:}"
	else
		# Accept plughw:C,D or hw:C,D or C,D
		card_num="$(printf '%s' "$conf_dev" | sed -n 's/^[^:]*:\([0-9][0-9]*\),.*/\1/p')"
		dev_num="$(printf '%s'  "$conf_dev" | sed -n 's/^[^:]*:[0-9][0-9]*,\([0-9][0-9]*\).*/\1/p')"
		if [ -z "$card_num" ] || [ -z "$dev_num" ]; then
			echo "cannot parse card/dev from: $conf_dev" >&2; return 1
		fi
	fi

	hw_params="$(probe_hw_params "$card_num" "$dev_num" 2>/dev/null || true)"
	if [ -n "$hw_params" ]; then
		old_ifs="$IFS"; IFS=':'; set -- $hw_params; IFS="$old_ifs"
		channels="$1"; rate="$2"; buf_time="${3:-}"; buf_size="${4:-}"
	else
		# Probe failed (device busy, or --dump-hw-params not supported).
		# Use safe defaults; arecord will report the real error at capture time.
		channels="2"; rate="$DEFAULT_RATE"; buf_time=""; buf_size=""
	fi

	# UCI overrides
	if [ "$conf_ch" != "auto" ] && valid_uint "$conf_ch" && [ "$conf_ch" -ge 1 ]; then
		channels="$conf_ch"
	fi
	if [ "$conf_rate" != "auto" ] && valid_uint "$conf_rate" && [ "$conf_rate" -ge 8000 ]; then
		rate="$conf_rate"
		[ "$rate" -gt 48000 ] && rate="48000"
	fi

	name="$(awk -v c="$card_num" '
		/^ *[0-9]+ \[/ {
			id=$1+0; n=$0
			gsub(/.*\[/,"",n); gsub(/\].*/,"",n)
			gsub(/^[[:space:]]+|[[:space:]]+$/,"",n)
			if(id==c+0) { print n; exit }
		}' /proc/asound/cards 2>/dev/null || true)"
	[ -n "$name" ] || name="card${card_num}"

	printf '%s:%s:%s:%s:%s:%s:%s\n' \
		"$card_num" "$dev_num" "$channels" "$rate" \
		"${buf_time:-}" "${buf_size:-}" "$name"
}

# ---- Subcommand: detect ------------------------------------------------------
# Called by the levels helper when no state file exists yet.
# Probes hardware (non-blocking) so the browser can size the grid before
# the daemon produces real PCM data.

detect_json() {
	params="$(resolve_capture 2>/dev/null || true)"
	if [ -n "$params" ]; then
		old_ifs="$IFS"; IFS=':'; set -- $params; IFS="$old_ifs"
		card_num="$1"; dev_num="$2"; channels="$3"; rate="$4"; name="${7:-}"
		device="plughw:${card_num},${dev_num}"
		msg="${name} (${channels}ch @ ${rate}Hz); capture daemon starting"
		emit_json - false "$channels" "$rate" \
			"$(zero_values "$channels")" "$device" "$msg"
	else
		emit_json - false 0 0 "[]" "" "no ALSA capture device found"
	fi
}

# ---- Subcommand: run ---------------------------------------------------------

do_arecord() {
	# Capture always uses plughw: so the ALSA plug layer converts any native
	# hardware format (S24_3LE, S32_LE …) to S16_LE transparently.
	# Buffer params passed through from --dump-hw-params when valid, matching
	# hALSAmrec behaviour (improves stability on some devices/drivers).
	if valid_uint "$buf_time" && valid_uint "$buf_size"; then
		arecord -q \
			-D "plughw:${card_num},${dev_num}" \
			-t raw -f "$FORMAT" -c "$channels" -r "$rate" \
			--buffer-time="$buf_time" --buffer-size="$buf_size" \
			- 2>"$ERR_FILE"
	else
		arecord -q \
			-D "plughw:${card_num},${dev_num}" \
			-t raw -f "$FORMAT" -c "$channels" -r "$rate" \
			- 2>"$ERR_FILE"
	fi
}

run_capture() {
	while :; do
		missing=""
		for tool in arecord od awk; do
			command -v "$tool" >/dev/null 2>&1 || missing="$tool"
		done
		if [ -n "$missing" ]; then
			emit_json "$STATE_FILE" false 0 0 "[]" "" \
				"${missing} not found; install alsa-utils"
			sleep 10; continue
		fi

		params="$(resolve_capture 2>"$ERR_FILE" || true)"
		if [ -z "$params" ]; then
			err="$(cat "$ERR_FILE" 2>/dev/null)"; [ -n "$err" ] || err="device detection failed"
			emit_json "$STATE_FILE" false 0 0 "[]" "" "$err"
			sleep 5; continue
		fi

		old_ifs="$IFS"; IFS=':'; set -- $params; IFS="$old_ifs"
		card_num="$1"; dev_num="$2"; channels="$3"; rate="$4"
		buf_time="${5:-}"; buf_size="${6:-}"; card_name="${7:-card${1}}"

		frames="$(uci_get frames_per_update "$DEFAULT_FRAMES")"
		{ valid_uint "$frames" && [ "$frames" -ge 256 ] && \
		  [ "$frames" -le 65536 ]; } || frames="$DEFAULT_FRAMES"

		dev_esc="$(json_escape "plughw:${card_num},${dev_num}")"
		msg_esc="$(json_escape "${card_name} (${channels}ch @ ${rate}Hz)")"
		tmp_file="${STATE_FILE}.tmp"
		rm -f "$ERR_FILE"

		emit_json "$STATE_FILE" true "$channels" "$rate" \
			"$(zero_values "$channels")" \
			"plughw:${card_num},${dev_num}" \
			"${card_name} (${channels}ch @ ${rate}Hz); capturing"

		# od -tu2: one unsigned 16-bit word per S16_LE sample on any LE host.
		# Abs value in awk: s > 32767 → s = 65536 - s (two's complement mirror).
		# ~2× fewer awk field reads than the old -tu1 byte-pair approach.
		do_arecord | od -An -v -tu2 | \
		awk -v ch="$channels" -v frames="$frames" \
		    -v out="$STATE_FILE" -v tmp="$tmp_file" \
		    -v dev="$dev_esc"   -v msg="$msg_esc" -v rate="$rate" '
		BEGIN {
			for (i=1;i<=ch;i++) peak[i]=0
			sidx=0; fseen=0; seq=0
		}
		{
			for (i=1;i<=NF;i++) {
				s=$i+0
				if (s>32767) s=65536-s
				c=(sidx%ch)+1
				if (s>peak[c]) peak[c]=s
				sidx++
				if (c==ch) {
					fseen++
					if (fseen>=frames) {
						seq++
						printf("{\"ok\":true,\"timestamp\":%d,\"sequence\":%d," \
						       "\"device\":\"%s\",\"channels\":%d,\"rate\":%d," \
						       "\"values\":[",
						       systime(),seq,dev,ch,rate) > tmp
						for (j=1;j<=ch;j++) {
							pct=int((peak[j]*100+16383)/32767)
							if (pct>100) pct=100
							if (j>1) printf(",") > tmp
							printf("%d",pct) > tmp
							peak[j]=0
						}
						printf("],\"message\":\"%s\"}\n",msg) > tmp
						close(tmp)
						system("mv " tmp " " out)
						fseen=0
					}
				}
			}
		}'

		err="$(cat "$ERR_FILE" 2>/dev/null)"; [ -n "$err" ] || err="capture pipeline stopped"
		emit_json "$STATE_FILE" false "$channels" "$rate" \
			"$(zero_values "$channels")" "plughw:${card_num},${dev_num}" "$err"
		sleep 2
	done
}

case "${1:-run}" in
	run)    run_capture ;;
	detect) detect_json ;;
	*)      echo "Usage: $0 [run|detect]" >&2; exit 1 ;;
esac
EOF_CAPTURE

# ---- Init script -------------------------------------------------------------

cat > "$INIT_FILE" <<'EOF_INIT'
#!/bin/sh /etc/rc.common

START=99
STOP=10
USE_PROCD=1
PROG="/usr/sbin/luci-vumeters-capture"

start_service() {
	enabled="$(uci -q get luci_vumeters.settings.enabled 2>/dev/null || echo 1)"
	[ "$enabled" = "0" ] && return 0
	procd_open_instance
	procd_set_param command "$PROG" run
	procd_set_param stderr 1
	# threshold=5s delay=5s max_fail=0 (unlimited retries).
	# Short threshold because device unplug kills arecord immediately.
	procd_set_param respawn 5 5 0
	procd_close_instance
}

reload_service() { stop; start; }
EOF_INIT

# ---- LuCI view ---------------------------------------------------------------

cat > "$VIEW_FILE" <<'EOF_VIEW'
'use strict';
'require view';
'require uci';
'require fs';

var CONF          = 'luci_vumeters';
var SECTION       = 'settings';
var LEVELS_HELPER = '/usr/libexec/luci-vumeters-levels';
var INIT_SCRIPT   = '/etc/init.d/luci_vumeters';
var MAX_CHANNELS  = 256;

// ---- Rendering engine constants --------------------------------------------
var MIN_BOX_PX                 = 4;
var PEAK_GLOW_MAX_CHANNELS     = 32;
var FPS_SMALL_GRID             = 60;
var FPS_BIG_GRID               = 30;
var BIG_GRID_CHANNEL_THRESHOLD = 12;
var EASE_DIVISOR               = 3;
var SETTLE_EPSILON             = 0.5;
var COLOR_GREEN_ON  = 'rgba(53,255,30,0.9)';
var COLOR_GREEN_OFF = 'rgba(13,64,8,0.9)';
var COLOR_YELLOW_ON  = 'rgba(255,215,5,0.9)';
var COLOR_YELLOW_OFF = 'rgba(64,53,0,0.9)';
var COLOR_RED_ON  = 'rgba(255,47,30,0.9)';
var COLOR_RED_OFF = 'rgba(64,12,8,0.9)';
var BG_COLOR         = 'rgb(32,32,32)';
var BOX_GAP_FRACTION = 0.2;

function clampInt(v, lo, hi, fb) {
	var n = parseInt(v, 10);
	if (isNaN(n)) n = fb;
	return n < lo ? lo : n > hi ? hi : n;
}

function clampPct(v) {
	var n = parseInt(v, 10);
	return isNaN(n) ? 0 : n < 0 ? 0 : n > 100 ? 100 : n;
}

function injectStyle() {
	if (document.getElementById('vum-style')) return;
	document.head.appendChild(E('style', { 'id': 'vum-style', 'type': 'text/css' }, [
		'#vum-root{width:100%;min-height:calc(100vh - 155px)}' +
		'#vum-summary{display:flex;gap:.75em;align-items:center;flex-wrap:wrap;' +
			'margin:0 0 .45em 0;font-size:.9em}' +
		'#vum-summary code{white-space:nowrap}' +
		'#vum-status{margin:0 0 .45em 0;min-height:1.4em}' +

		// Config panel: shown when ok=false so the user can set device /
		// channels without re-running the installer.
		'#vum-config{display:none;margin:0 0 .7em 0;padding:.6em .75em;' +
			'border:1px solid rgba(127,127,127,.3);border-radius:4px}' +
		'#vum-config .hint{margin:0 0 .45em 0;font-size:.88em;opacity:.8}' +
		'#vum-config .row{display:flex;gap:.6em;align-items:flex-end;flex-wrap:wrap}' +
		'#vum-config label{display:flex;flex-direction:column;gap:.2em;font-size:.88em}' +
		'#vum-config input[type="text"]{width:12em}' +

		'#vum-grid-wrap{width:100%;height:calc(100vh - 265px);' +
			'min-height:240px;overflow:auto}' +
		'#vum-grid{display:grid;min-height:100%;gap:4px}' +
		'.vum-cell{border:1px solid rgba(127,127,127,.35);padding:5px;' +
			'min-width:52px;min-height:100px;' +
			'display:flex;flex-direction:column;align-items:stretch}' +

		// flex:1 1 0 + min-height:0 lets the canvas fill the grid-row height.
		// Pixel dimensions are set in startMeters() from offsetWidth/offsetHeight
		// so buildGeometry() always receives the true display size.
		'.vum-canvas{display:block;width:100%;flex:1 1 0;min-height:0;' +
			'background:rgb(32,32,32);border-radius:3px}' +
		'.vum-cap{margin-top:.3em;line-height:1.2;font-size:.82em;' +
			'text-align:center;white-space:nowrap}' +
		'.vum-placeholder{padding:2em;text-align:center;' +
			'border:1px dashed rgba(127,127,127,.4)}'
	]));
}

// ---- Shared rendering engine ------------------------------------------------

function pickBoxCount(h) {
	var n = 16;
	while (n > 6 && h / (n + (n+1)*BOX_GAP_FRACTION) < MIN_BOX_PX) n--;
	return n;
}

function buildGeometry(w, h) {
	var n   = pickBoxCount(h);
	var red = Math.max(1, Math.round(n*3/16));
	var yel = Math.max(1, Math.round(n*4/16));
	if (red+yel > n-1) yel = Math.max(1, n-red-1);

	var bh  = h / (n + (n+1)*BOX_GAP_FRACTION);
	var gap = bh * BOX_GAP_FRACTION;
	var bw  = w - gap*2;
	var gx  = (w - bw) / 2;

	var bId = [], bX = [], bY = [], cOn = [], cOff = [];
	for (var i = 0; i < n; i++) {
		var id = Math.abs(i-(n-1))+1;
		bId[i]=id; bX[i]=gx; bY[i]=gap+i*(bh+gap);
		if      (id > n-red)         { cOn[i]=COLOR_RED_ON;    cOff[i]=COLOR_RED_OFF;    }
		else if (id > n-red-yel)     { cOn[i]=COLOR_YELLOW_ON; cOff[i]=COLOR_YELLOW_OFF; }
		else                         { cOn[i]=COLOR_GREEN_ON;  cOff[i]=COLOR_GREEN_OFF;  }
	}
	return { w:w, h:h, n:n, bh:bh, bw:bw, bId:bId, bX:bX, bY:bY, cOn:cOn, cOff:cOff };
}

function drawMeter(g, st, glow) {
	var ctx = st.ctx;
	ctx.fillStyle = BG_COLOR;
	ctx.fillRect(0, 0, g.w, g.h);

	var maxOn = Math.ceil((st.curVal/100)*g.n);
	var pi=-1, pid=-1;
	for (var i=0; i<g.n; i++) {
		var on = g.bId[i] <= maxOn;
		ctx.fillStyle = on ? g.cOn[i] : g.cOff[i];
		ctx.fillRect(g.bX[i], g.bY[i], g.bw, g.bh);
		if (on && g.bId[i]>pid) { pid=g.bId[i]; pi=i; }
	}
	if (glow && pi>=0) {
		ctx.save();
		ctx.shadowBlur=10; ctx.shadowColor=g.cOn[pi];
		ctx.fillStyle=g.cOn[pi];
		ctx.fillRect(g.bX[pi], g.bY[pi], g.bw, g.bh);
		ctx.restore();
	}
}

// ---- View -------------------------------------------------------------------

return view.extend({
	handleSaveApply: null,
	handleSave:      null,
	handleReset:     null,

	load: function() {
		return uci.load(CONF).catch(function(e) {
			console.warn('vumeters: uci load failed:', e); return null;
		});
	},

	render: function() {
		injectStyle();

		var states=[], geom=null, glow=true, budget=1000/FPS_SMALL_GRID;
		var raf=null, pollT=null, lastT=0, gridRoot=null, renderedCh=0;

		var pollMs  = clampInt(uci.get(CONF,SECTION,'poll_ms'),    50,5000,200);
		var maxCols = clampInt(uci.get(CONF,SECTION,'max_columns'), 1,  16, 16);

		var sDev  = E('code',{},[ '-' ]);
		var sCh   = E('code',{},[ '0' ]);
		var sRate = E('code',{},[ '-' ]);
		var sPoll = E('code',{},[ String(pollMs)+' ms' ]);

		var status = E('div',{ 'id':'vum-status','class':'alert-message notice' },
			[ _('Waiting for ALSA input levels\u2026') ]);

		// Config panel — visible only when capture is not ok
		var devInp = E('input',{
			'type':'text',
			'value': uci.get(CONF,SECTION,'capture_device') || 'auto',
			'placeholder':'auto  or  plughw:1,0',
			'class':'cbi-input-text'
		});
		var chInp = E('input',{
			'type':'text',
			'value': uci.get(CONF,SECTION,'channels') || 'auto',
			'placeholder':'auto  or  16',
			'class':'cbi-input-text'
		});
		var applyBtn = E('button',{ 'class':'btn cbi-button cbi-button-save' },
			[ _('Apply \u0026 restart') ]);

		var cfgPanel = E('div',{ 'id':'vum-config' },[
			E('div',{ 'class':'hint' },[
				_('Detection failed or capture stopped — set device / channel count:')
			]),
			E('div',{ 'class':'row' },[
				E('label',{},[ E('span',{},[ _('ALSA device') ]), devInp ]),
				E('label',{},[ E('span',{},[ _('Channels')    ]), chInp  ]),
				applyBtn
			])
		]);

		var grid = E('div',{ 'id':'vum-grid' });

		// ---- Engine ---------------------------------------------------------

		function stopAll() {
			if (raf)   { window.cancelAnimationFrame(raf); raf=null; }
			if (pollT) { window.clearTimeout(pollT); pollT=null; }
			states=[];
		}

		function setChannel(ch, val) {
			var st = states[ch-1];
			if (st) st.target = clampPct(val);
		}

		function setAllChannels(vals) {
			if (!vals) return;
			for (var i=0; i<vals.length; i++) setChannel(i+1, vals[i]);
		}

		// One shared rAF loop for all channels — no jitter (real ALSA data).
		function tick(now) {
			raf = window.requestAnimationFrame(tick);
			if (document.hidden || now-lastT < budget) return;
			lastT = now;
			if (!document.body.contains(gridRoot)) { stopAll(); return; }

			for (var i=0; i<states.length; i++) {
				var st=states[i], changed=false;
				if (st.curVal !== st.target) {
					st.curVal += (st.target-st.curVal)/EASE_DIVISOR;
					if (Math.abs(st.target-st.curVal)<SETTLE_EPSILON)
						st.curVal=st.target;
					changed=true;
				}
				if (changed || !st.idle) {
					drawMeter(geom, st, glow);
					st.idle = (st.curVal===0 && st.target===0);
				}
			}
		}

		function startMeters(canvases, root) {
			if (raf) { window.cancelAnimationFrame(raf); raf=null; }
			gridRoot=root; states=[];
			if (!canvases.length) return;

			// Read actual rendered dimensions post-layout (setTimeout(0) guarantees
			// the browser has completed a layout pass before we get here).
			var w = canvases[0].offsetWidth  || canvases[0].width;
			var h = canvases[0].offsetHeight || canvases[0].height;
			for (var i=0; i<canvases.length; i++) {
				canvases[i].width=w; canvases[i].height=h;
			}
			geom = buildGeometry(w, h);

			var tot = canvases.length;
			glow   = tot <= PEAK_GLOW_MAX_CHANNELS;
			budget = 1000/(tot>BIG_GRID_CHANNEL_THRESHOLD ? FPS_BIG_GRID : FPS_SMALL_GRID);
			states = new Array(tot);

			for (var j=0; j<canvases.length; j++) {
				var ctx=canvases[j].getContext('2d');
				ctx.fillStyle=BG_COLOR; ctx.fillRect(0,0,geom.w,geom.h);
				states[j]={ ctx:ctx, curVal:0, target:0, idle:true };
			}

			window.setVuChannelValue  = setChannel;
			window.setVuChannelValues = setAllChannels;
			lastT=0; raf=window.requestAnimationFrame(tick);
		}

		function renderGrid(ch, root) {
			var canvases=[];
			var channels = clampInt(ch, 0, MAX_CHANNELS, 0);
			var cols     = channels>0 ? Math.min(maxCols,channels) : 1;
			var rows     = channels>0 ? Math.ceil(channels/cols) : 1;
			renderedCh   = channels;

			// 1fr rows fill grid-wrap height evenly.
			grid.style.gridTemplateColumns='repeat('+cols+', minmax(0,1fr))';
			grid.style.gridTemplateRows   ='repeat('+rows+', 1fr)';

			while (grid.firstChild) grid.removeChild(grid.firstChild);

			if (!channels) {
				grid.appendChild(E('div',{ 'class':'vum-placeholder' },[
					_('No capture channels detected yet.')
				]));
				if (raf) { window.cancelAnimationFrame(raf); raf=null; }
				states=[];
				return;
			}

			for (var c=1; c<=channels; c++) {
				var cv=E('canvas',{ 'class':'vum-canvas','width':'64','height':'64' });
				canvases.push(cv);
				grid.appendChild(E('div',{ 'class':'vum-cell' },[
					cv, E('div',{ 'class':'vum-cap' },[ 'IN '+c ])
				]));
			}
			window.setTimeout(function(){ startMeters(canvases, root); }, 0);
		}

		// ---- Poll loop ------------------------------------------------------

		function updateMeta(data) {
			sDev.textContent  = data.device   || '-';
			sCh.textContent   = String(clampInt(data.channels,0,MAX_CHANNELS,0));
			sRate.textContent = data.rate ? String(data.rate)+' Hz' : '-';
			sPoll.textContent = String(pollMs)+' ms';

			if (data.ok) {
				status.className='alert-message notice';
				status.textContent=data.message || _('Capturing ALSA input levels.');
				cfgPanel.style.display='none';
			} else {
				status.className='alert-message warning';
				status.textContent=data.message || _('Waiting for ALSA input levels.');
				cfgPanel.style.display='';
				// Pre-fill config panel from what the daemon detected
				if (data.device && devInp.value==='auto')
					devInp.value=data.device;
				if (data.channels && String(data.channels)!=='0' && chInp.value==='auto')
					chInp.value=String(data.channels);
			}
		}

		function handleReply(res, root) {
			var txt=(res && res.stdout) ? res.stdout.trim() : '';
			var data;
			try { data=JSON.parse(txt||'{}'); }
			catch(e) {
				throw new Error('JSON parse error: '+e.message+
				                ' — raw: '+txt.slice(0,80));
			}
			if (!data||typeof data!=='object')
				throw new Error('unexpected reply from '+LEVELS_HELPER);
			if (typeof data.channels!=='number')
				data.channels=parseInt(data.channels||0,10)||0;
			if (data.channels!==renderedCh) renderGrid(data.channels, root);
			if (Array.isArray(data.values)) setAllChannels(data.values);
			updateMeta(data);
		}

		function schedulePoll(root) {
			if (!document.body.contains(root)) { stopAll(); return; }
			pollT=window.setTimeout(function(){ poll(root); }, pollMs);
		}

		function poll(root) {
			if (!document.body.contains(root)) { stopAll(); return; }
			fs.exec(LEVELS_HELPER,[]).then(function(res){
				// try/catch prevents an uncaught throw from silently killing
				// the poll chain, which was the cause of the permanent
				// "Waiting…" state with no error message in earlier versions.
				try { handleReply(res,root); }
				catch(e) {
					status.className='alert-message error';
					status.textContent=_('Error reading levels: ')+e;
					cfgPanel.style.display='';
				}
				schedulePoll(root);
			},function(err){
				status.className='alert-message error';
				status.textContent=_('Cannot exec levels helper: ')+err;
				cfgPanel.style.display='';
				schedulePoll(root);
			});
		}

		// ---- Config panel handler -------------------------------------------

		applyBtn.addEventListener('click', function() {
			var dev = devInp.value.trim() || 'auto';
			var ch  = chInp.value.trim()  || 'auto';
			applyBtn.disabled=true;
			status.className='alert-message notice';
			status.textContent=_('Saving configuration\u2026');

			if (!uci.get(CONF,SECTION)) uci.add(CONF,'settings',SECTION);
			uci.set(CONF,SECTION,'capture_device',dev);
			uci.set(CONF,SECTION,'channels',ch);

			uci.save().then(function(){ return uci.apply(10); })
			.then(function(){
				status.textContent=_('Saved — restarting capture service\u2026');
				return fs.exec(INIT_SCRIPT,['restart']);
			}).then(function(){
				status.className='alert-message notice';
				status.textContent=_('Service restarted — waiting for levels\u2026');
				cfgPanel.style.display='none';
				applyBtn.disabled=false;
				if (pollT) { window.clearTimeout(pollT); pollT=null; }
				window.setTimeout(function(){ poll(root); }, 2000);
			},function(err){
				status.className='alert-message error';
				status.textContent=_('Apply failed: ')+err;
				applyBtn.disabled=false;
			});
		});

		// ---- Root DOM -------------------------------------------------------

		var root=E('div',{ 'id':'vum-root','class':'cbi-map' },[
			E('h2',{},[_('VU Meters')]),
			E('div',{ 'class':'cbi-map-descr' },[
				_('Live ALSA capture input levels. One meter per channel.')
			]),
			E('div',{ 'id':'vum-summary' },[
				E('span',{},[_('Device'),  ': ',sDev  ]),
				E('span',{},[_('Channels'),': ',sCh   ]),
				E('span',{},[_('Rate'),    ': ',sRate ]),
				E('span',{},[_('Poll'),    ': ',sPoll ])
			]),
			status,
			cfgPanel,
			E('div',{ 'id':'vum-grid-wrap' },[ grid ])
		]);

		renderGrid(0, root);
		poll(root);
		return root;
	}
});
EOF_VIEW

# ---- Permissions and services -----------------------------------------------

chmod 0755 "$CAPTURE_SCRIPT" "$LEVELS_SCRIPT" "$INIT_FILE"
chmod 0644 "$VIEW_FILE" "$MENU_FILE" "$ACL_FILE"

rm -f /tmp/luci-indexcache 2>/dev/null || true
rm -f /tmp/luci-modulecache/* 2>/dev/null || true

[ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd restart >/dev/null 2>&1 || true

if [ -x "$INIT_FILE" ]; then
	if [ "$ENABLED" = "1" ]; then
		"$INIT_FILE" enable  >/dev/null 2>&1 || true
		"$INIT_FILE" restart >/dev/null 2>&1 || true
	else
		"$INIT_FILE" disable >/dev/null 2>&1 || true
		"$INIT_FILE" stop    >/dev/null 2>&1 || true
	fi
fi

[ -x /etc/init.d/uhttpd ] && {
	/etc/init.d/uhttpd reload  >/dev/null 2>&1 || \
	/etc/init.d/uhttpd restart >/dev/null 2>&1 || true; }

echo ""
echo "[*] Installed LuCI ALSA VU Meters."
echo "    LuCI -> Status -> VU Meters"
echo ""
echo "    Device:   ${CAPTURE_DEVICE}"
echo "    Channels: ${CHANNELS}"
echo "    Rate:     ${SAMPLE_RATE}"
echo "    Max cols: ${MAX_COLUMNS}"
echo ""
echo "    To verify detection on the router:"
echo "      /usr/sbin/luci-vumeters-capture detect"
echo ""
echo "    If Channels shows 0, the page has a config panel, or run:"
echo "      sh $0 --device plughw:1,0 --channels 16"