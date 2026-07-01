#!/bin/sh
#
# install_luci_vumeters_alsa.sh — OpenWrt 24.x ALSA VU meter installer.
#
# Usage:
#   sh install_luci_vumeters_alsa.sh
#   sh install_luci_vumeters_alsa.sh --device plughw:1,0 --channels 16
#   sh install_luci_vumeters_alsa.sh --max-cols 8 --poll-ms 150
#
# After installation: LuCI -> Status -> VU Meters
# If "Channels: 0" appears, use the in-page config panel or re-run with
# explicit --device/--channels.

set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin; export PATH

DEV=auto CH=auto RATE=auto POLL=200 FRAMES=4096 COLS=16 ENABLED=1

UCI=luci_vumeters
SECT=settings
CONF_FILE=/etc/config/${UCI}
VIEW=/www/luci-static/resources/view/vumeters/vumeters.js
MENU=/usr/share/luci/menu.d/luci-app-vumeters.json
ACL=/usr/share/rpcd/acl.d/luci-app-vumeters.json
CAP=/usr/sbin/luci-vumeters-capture
LVL=/usr/libexec/luci-vumeters-levels
INIT=/etc/init.d/luci_vumeters

usage() { cat <<EOF
Usage: sh $0 [options]
  --device DEV        ALSA capture device (default: auto → first detected)
  --channels N|auto   Channel count (default: auto, from hw-params)
  --rate N|auto       Sample rate Hz (default: auto, from hw-params, <=48000)
  --poll-ms N         Browser poll ms, 50-5000 (default: $POLL)
  --frames N          ALSA frames/update, 256-65536 (default: $FRAMES)
  --max-cols N        Max meters per row, 1-16 (default: $COLS)
  --disable           Install without starting the service
EOF
}

vr() { # validate: name value min max
	case ${2:-} in ''|*[!0-9]*) echo "Invalid $1: ${2:-}" >&2; exit 1;; esac
	[ "$2" -ge "$3" ] && [ "$2" -le "$4" ] || { echo "Invalid $1 $2: ${3}-${4}" >&2; exit 1; }
}
# auto-or-validate: $2 is the VALUE being checked against "auto", not $1
# (which is the field name) - a $1/$2 mix-up here previously made every
# "auto" default get rejected as invalid, aborting the installer before
# it did anything.
va() { [ "${2:-}" = auto ] || vr "$@"; }

while [ "$#" -gt 0 ]; do
	case $1 in
		--device)    [ "$#" -ge 2 ] || { usage >&2; exit 1; }; DEV=$2;    shift 2;;
		--channels)  [ "$#" -ge 2 ] || { usage >&2; exit 1; }; CH=$2;     shift 2;;
		--rate)      [ "$#" -ge 2 ] || { usage >&2; exit 1; }; RATE=$2;   shift 2;;
		--poll-ms)   [ "$#" -ge 2 ] || { usage >&2; exit 1; }; POLL=$2;   shift 2;;
		--frames)    [ "$#" -ge 2 ] || { usage >&2; exit 1; }; FRAMES=$2; shift 2;;
		--max-cols|--max-columns)
		             [ "$#" -ge 2 ] || { usage >&2; exit 1; }; COLS=$2;   shift 2;;
		--disable)   ENABLED=0; shift;;
		-h|--help)   usage; exit 0;;
		*)           echo "Unknown: $1" >&2; usage >&2; exit 1;;
	esac
done

va channels  "$CH"     1     256
va rate      "$RATE"   8000  384000
vr poll-ms   "$POLL"   50    5000
vr frames    "$FRAMES" 256   65536
vr max-cols  "$COLS"   1     16

[ "$(id -u)" = 0 ] || { echo "Run as root." >&2; exit 1; }
[ -d /usr/share/luci/menu.d ] && [ -d /www/luci-static/resources ] \
	|| { echo "LuCI not found. Run: opkg install luci" >&2; exit 1; }
command -v uci >/dev/null 2>&1 || { echo "uci not found." >&2; exit 1; }
command -v arecord >/dev/null 2>&1 \
	|| echo "Warning: arecord not found — install alsa-utils." >&2

bak() { [ -f "$1" ] && cp -p "$1" "$1.bak.$(date +%Y%m%d%H%M%S 2>/dev/null||echo bak)" || true; }

umask 022
mkdir -p "$(dirname "$VIEW")" "$(dirname "$MENU")" "$(dirname "$ACL")" \
         "$(dirname "$LVL")"  "$(dirname "$CAP")"  "$(dirname "$INIT")"
for f in "$VIEW" "$MENU" "$ACL" "$CAP" "$LVL" "$INIT"; do bak "$f"; done

# Ensure the UCI config file exists before rpcd tries to uci-load it.
# A missing /etc/config/<name> causes rpcd to return ubus code 4 which
# crashes the entire LuCI view before render() can run.
[ -f "$CONF_FILE" ] || : > "$CONF_FILE"
uci -q revert "$UCI" 2>/dev/null || true
uci -q batch <<EOF_UCI
set ${UCI}.${SECT}=settings
set ${UCI}.${SECT}.capture_device='${DEV}'
set ${UCI}.${SECT}.channels='${CH}'
set ${UCI}.${SECT}.sample_rate='${RATE}'
set ${UCI}.${SECT}.poll_ms='${POLL}'
set ${UCI}.${SECT}.frames_per_update='${FRAMES}'
set ${UCI}.${SECT}.max_columns='${COLS}'
set ${UCI}.${SECT}.enabled='${ENABLED}'
commit ${UCI}
EOF_UCI
uci -q get "${UCI}.${SECT}" >/dev/null 2>&1 || {
	echo "Warning: uci commit failed; writing ${CONF_FILE} directly." >&2
	cat > "$CONF_FILE" <<EOF_CF
config settings '${SECT}'
	option capture_device '${DEV}'
	option channels '${CH}'
	option sample_rate '${RATE}'
	option poll_ms '${POLL}'
	option frames_per_update '${FRAMES}'
	option max_columns '${COLS}'
	option enabled '${ENABLED}'
EOF_CF
}

# ---- menu.d ------------------------------------------------------------------
cat > "$MENU" <<'EOF_MENU'
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
cat > "$ACL" <<'EOF_ACL'
{
	"luci-app-vumeters": {
		"description": "LuCI ALSA VU meters",
		"read": {
			"uci": [ "luci_vumeters" ],
			"ubus": { "file": [ "exec" ] },
			"file": {
				"/usr/libexec/luci-vumeters-levels": [ "exec" ],
				"/etc/init.d/luci_vumeters":         [ "exec" ]
			}
		},
		"write": { "uci": [ "luci_vumeters" ] }
	}
}
EOF_ACL

# ---- Levels helper -----------------------------------------------------------
# Executed by fs.exec() on every browser poll. Must never block.
cat > "$LVL" <<'EOF_LVL'
#!/bin/sh
S=/tmp/luci-vumeters/levels.json
[ -s "$S" ] && exec cat "$S"
[ -x /usr/sbin/luci-vumeters-capture ] \
	&& /usr/sbin/luci-vumeters-capture detect 2>/dev/null && exit 0
printf '%s\n' '{"ok":false,"timestamp":0,"device":"","channels":0,"rate":0,"values":[],"message":"capture service not running"}'
EOF_LVL

# ---- Capture daemon ----------------------------------------------------------
#
# Key design (informed by the hALSAmrec codebase in this project):
#
#  arecord --dump-hw-params (probe on hw:, capture on plughw:)
#    The only reliable way to get actual channel count and supported
#    formats without starting a full capture session.  hALSAmrec uses
#    exactly this approach.  The naive /proc/asound/cardN/streamN files
#    require CONFIG_SND_VERBOSE_PROCFS, which is typically disabled on
#    embedded kernels — that is why previous versions returned channels=0
#    and got stuck at "Waiting for ALSA input levels...".
#    Probing on hw: gives raw hardware limits; capturing on plughw: lets
#    ALSA's plug layer convert any native format (S24_3LE, S32_LE …) to
#    S16_LE transparently, avoiding "Invalid argument" failures on modern
#    USB interfaces that do not natively support S16_LE.
#
#  Single-pass awk in probe_hw_params
#    One awk invocation extracts CHANNELS, RATE, BUFFER_TIME and
#    BUFFER_SIZE from the dump in a single read, replacing the four
#    separate awk/subshell calls in earlier versions.
#
#  od -An -v -tu2 pipeline
#    One unsigned 16-bit word per S16_LE sample on any LE host (all ARM/
#    x86 OpenWrt targets).  abs = s>32767 ? 65536-s : s.
#    ~2× fewer awk field iterations than the old -tu1 byte-pair approach.
#
#  Modulo frame counter
#    ++sidx % (ch*frames) == 0 replaces frames_seen + c==ch checks,
#    eliminating one variable and one comparison per sample.
#
#  Buffer params from dump
#    Passed to arecord when valid, matching hALSAmrec behaviour for
#    capture stability on devices with strict buffer requirements.
#
#  arecord -l awk pattern
#    match()-based, copied from hALSAmrec, handles locale/spacing
#    variations that break simple sed patterns.

cat > "$CAP" <<'EOF_CAP'
#!/bin/sh
PATH=/usr/sbin:/usr/bin:/sbin:/bin; export PATH

UCI=luci_vumeters; SECT=settings
STATE=/tmp/luci-vumeters/levels.json
ERR=/tmp/luci-vumeters/capture.err
FMT=S16_LE; DFRATE=48000; DFFRAMES=4096

mkdir -p /tmp/luci-vumeters

vint() { case ${1:-} in ''|*[!0-9]*) return 1;; esac; }
# uget: read a UCI value with a fallback default.  ${v:-$2} does the
# fallback natively - no awk fork needed for what is just a default-value
# lookup, saving one process spawn on every call (resolve() alone makes
# several of these per capture-session start).
uget() { v=$(uci -q get "$UCI.$SECT.$1" 2>/dev/null||true); printf '%s\n' "${v:-$2}"; }
jesc() { printf '%s' "$1" | tr '\000-\037\\' '   \\' | sed 's/"/\\"/g'; }
zval() { awk -v n="$1" 'BEGIN{printf "[";for(i=1;i<=n;i++){if(i>1)printf",";printf"0"};print"]"}'; }

emit() {
	# $1=file|- $2=ok $3=ch $4=rate $5=values $6=device $7=message
	case ${3:-} in ''|*[!0-9]*) _c=0;; *) _c=$3;; esac
	case ${4:-} in ''|*[!0-9]*) _r=0;; *) _r=$4;; esac
	case ${5:-} in \[*\]) _v=$5;; *) _v=[];; esac
	_t=$(date +%s 2>/dev/null||printf 0)
	_l=$(printf '{"ok":%s,"timestamp":%s,"device":"%s","channels":%s,"rate":%s,"values":%s,"message":"%s"}\n' \
		"${2:-false}" "$_t" "$(jesc "${6:-}")" "$_c" "$_r" "$_v" "$(jesc "${7:-}")")
	[ "$1" = - ] && { printf '%s\n' "$_l"; return; }
	printf '%s\n' "$_l" > "$1.$$" && mv "$1.$$" "$1"
}

# ---- Device detection -------------------------------------------------------

# Find the first ALSA capture device. Tries /proc/asound/pcm first
# (non-blocking, no external tools), then falls back to arecord -l with
# the locale-robust match()-based awk from hALSAmrec.
# Outputs "card:dev" or returns 1.
find_dev() {
	if [ -r /proc/asound/pcm ]; then
		while IFS= read -r ln; do
			case $ln in *capture*) ;; *) continue;; esac
			c=$(printf '%s' "$ln"|sed -n 's/^ *\([0-9][0-9]*\)-.*/\1/p')
			d=$(printf '%s' "$ln"|sed -n 's/^ *[0-9][0-9]*-\([0-9][0-9]*\):.*/\1/p')
			[ -n "$c" ] && [ -n "$d" ] && printf '%d:%d\n' "$c" "$d" 2>/dev/null && return 0
		done < /proc/asound/pcm
	fi
	command -v arecord >/dev/null 2>&1 || return 1
	# match()-based awk: handles locale-specific spacing in arecord -l output
	arecord -l 2>/dev/null | awk '
		/^[[:space:]]*card[[:space:]]+[0-9]+:/ {
			if(match($0,/card[[:space:]]+[0-9]+/)) {
				c=substr($0,RSTART,RLENGTH); sub(/.* /,"",c) }
			if(match($0,/device[[:space:]]+[0-9]+/)) {
				d=substr($0,RSTART,RLENGTH); sub(/.* /,"",d) }
			if(c!=""&&d!="") { print c":"d; exit }
		}' || true
}

# Probe hardware parameters via arecord --dump-hw-params.
# Must use hw: (not plughw:) to get real hardware limits.
# The dump goes to stderr; 2>&1 redirects it into the pipe (same pattern
# used by hALSAmrec). A single awk pass extracts all four fields.
# Outputs "channels:rate:buf_time:buf_size" or nothing on failure.
probe() {
	command -v arecord >/dev/null 2>&1 || return 1
	arecord -D "hw:$1,$2" --dump-hw-params 2>&1 | awk '
		function lastnum(s,  n,a,i) {
			gsub(/[^0-9]+/," ",s); n=split(s,a)
			for(i=n;i>=1;i--) if(a[i]+0>0) return a[i]+0
			return 0
		}
		/^CHANNELS:/    { ch=lastnum($0); found=1 }
		/^RATE:/        { rate=lastnum($0) }
		/^BUFFER_TIME:/ { bt=lastnum($0) }
		/^BUFFER_SIZE:/ { bs=lastnum($0) }
		END {
			if(!found) exit
			if(rate<=0||rate>48000) rate=48000
			printf "%s:%s:%s:%s\n",(ch>0?ch:2),rate,(bt>0?bt:""),(bs>0?bs:"")
		}
	' 2>/dev/null || true
}

# Resolve final capture params: detection + probe + UCI overrides.
# Outputs 7 colon-separated fields: card dev channels rate bt bs name
resolve() {
	cdev=$(uget capture_device auto)
	if [ "$cdev" = auto ]; then
		adev=$(find_dev 2>/dev/null||true)
		[ -n "$adev" ] || { echo "no ALSA capture device found" >&2; return 1; }
		cn=${adev%%:*}; dn=${adev##*:}
	else
		cn=$(printf '%s' "$cdev"|sed -n 's/^[^:]*:\([0-9]*\),.*/\1/p')
		dn=$(printf '%s' "$cdev"|sed -n 's/^[^:]*:[0-9]*,\([0-9]*\).*/\1/p')
		[ -n "$cn" ] && [ -n "$dn" ] \
			|| { echo "cannot parse card/dev from: $cdev" >&2; return 1; }
	fi

	hw=$(probe "$cn" "$dn" 2>/dev/null||true)
	if [ -n "$hw" ]; then
		old=$IFS; IFS=:; set -- $hw; IFS=$old
		ch=$1; rate=$2; bt=${3:-}; bs=${4:-}
	else
		ch=2; rate=$DFRATE; bt=; bs=
	fi

	# UCI overrides
	uch=$(uget channels auto)
	[ "$uch" != auto ] && vint "$uch" && [ "$uch" -ge 1 ] && ch=$uch
	urt=$(uget sample_rate auto)
	[ "$urt" != auto ] && vint "$urt" && rate=$urt && [ "$rate" -gt 48000 ] && rate=48000

	name=$(awk -v c="$cn" '
		/^ *[0-9]+ \[/ {
			id=$1+0; n=$0; gsub(/.*\[/,"",n); gsub(/\].*/,"",n)
			gsub(/^[[:space:]]+|[[:space:]]+$/,"",n)
			if(id==c+0){print n;exit}
		}' /proc/asound/cards 2>/dev/null||true)
	[ -n "$name" ] || name="card${cn}"

	printf '%s:%s:%s:%s:%s:%s:%s\n' "$cn" "$dn" "$ch" "$rate" "${bt:-}" "${bs:-}" "$name"
}

# ---- Subcommand: detect ------------------------------------------------------
detect() {
	p=$(resolve 2>/dev/null||true)
	if [ -n "$p" ]; then
		old=$IFS; IFS=:; set -- $p; IFS=$old
		cn=$1; dn=$2; ch=$3; rate=$4; name=${7:-card${1}}
		emit - false "$ch" "$rate" "$(zval "$ch")" "plughw:${cn},${dn}" \
			"${name} (${ch}ch @ ${rate}Hz); daemon starting"
	else
		emit - false 0 0 '[]' '' 'no ALSA capture device found'
	fi
}

# ---- Subcommand: run ---------------------------------------------------------
run() {
	while :; do
		miss=
		for t in arecord od awk; do command -v "$t" >/dev/null 2>&1||miss=$t; done
		if [ -n "$miss" ]; then
			emit "$STATE" false 0 0 '[]' '' "$miss not found; install alsa-utils"
			sleep 10; continue
		fi

		p=$(resolve 2>"$ERR"||true)
		if [ -z "$p" ]; then
			err=$(cat "$ERR" 2>/dev/null); [ -n "$err" ]||err="device detection failed"
			emit "$STATE" false 0 0 '[]' '' "$err"; sleep 5; continue
		fi

		old=$IFS; IFS=:; set -- $p; IFS=$old
		cn=$1; dn=$2; ch=$3; rate=$4; bt=${5:-}; bs=${6:-}; name=${7:-card${1}}

		frames=$(uget frames_per_update "$DFFRAMES")
		{ vint "$frames"&&[ "$frames" -ge 256 ]&&[ "$frames" -le 65536 ]; }||frames=$DFFRAMES

		emit "$STATE" true "$ch" "$rate" "$(zval "$ch")" \
			"plughw:${cn},${dn}" "${name} (${ch}ch @ ${rate}Hz); capturing"

		dev=$(jesc "plughw:${cn},${dn}")
		msg=$(jesc "${name} (${ch}ch @ ${rate}Hz)")
		tmp=${STATE}.tmp
		rm -f "$ERR"

		# Build arecord args; pass buffer params when available for
		# capture stability on devices with strict timing requirements.
		set -- -q -D "plughw:${cn},${dn}" -t raw -f "$FMT" -c "$ch" -r "$rate"
		case $bt in ''|*[!0-9]*) ;; *) set -- "$@" "--buffer-time=$bt";; esac
		case $bs in ''|*[!0-9]*) ;; *) set -- "$@" "--buffer-size=$bs";; esac

		arecord "$@" - 2>"$ERR" | od -An -v -tu2 | \
		awk -v ch="$ch" -v frames="$frames" \
		    -v out="$STATE" -v tmp="$tmp" \
		    -v dev="$dev"   -v msg="$msg" -v rate="$rate" '
		BEGIN {
			for(i=1;i<=ch;i++) pk[i]=0
			sidx=0; cf=ch*frames; seq=0
		}
		{
			for(i=1;i<=NF;i++) {
				s=$i+0; if(s>32767) s=65536-s
				c=sidx%ch+1; if(s>pk[c]) pk[c]=s
				if(++sidx%cf==0) {
					seq++
					printf("{\"ok\":true,\"timestamp\":%d,\"sequence\":%d," \
					       "\"device\":\"%s\",\"channels\":%d,\"rate\":%d," \
					       "\"values\":[",systime(),seq,dev,ch,rate) > tmp
					for(j=1;j<=ch;j++) {
						v=int((pk[j]*100+16383)/32767)
						if(v>100) v=100
						if(j>1) printf(",") > tmp
						printf("%d",v) > tmp; pk[j]=0
					}
					printf("],\"message\":\"%s\"}\n",msg) > tmp
					close(tmp); system("mv " tmp " " out)
				}
			}
		}'

		err=$(cat "$ERR" 2>/dev/null)||true; [ -n "$err" ]||err="capture pipeline stopped"
		emit "$STATE" false "$ch" "$rate" "$(zval "$ch")" "plughw:${cn},${dn}" "$err"
		sleep 2
	done
}

case ${1:-run} in
	run)    run;;
	detect) detect;;
	*)      echo "Usage: $0 [run|detect]" >&2; exit 1;;
esac
EOF_CAP

# ---- Init script -------------------------------------------------------------
cat > "$INIT" <<'EOF_INIT'
#!/bin/sh /etc/rc.common
START=99; STOP=10; USE_PROCD=1
PROG=/usr/sbin/luci-vumeters-capture

start_service() {
	[ "$(uci -q get luci_vumeters.settings.enabled 2>/dev/null||echo 1)" = 0 ] && return 0
	procd_open_instance
	procd_set_param command "$PROG" run
	procd_set_param stderr 1
	procd_set_param respawn 5 5 0  # threshold delay max_fail(0=unlimited)
	procd_close_instance
}
reload_service() { stop; start; }
EOF_INIT

# ---- LuCI view ---------------------------------------------------------------
cat > "$VIEW" <<'EOF_VIEW'
'use strict';
'require view';
'require uci';
'require fs';

var CONF = 'luci_vumeters', SECT = 'settings';
var LEVELS = '/usr/libexec/luci-vumeters-levels';
var INITD  = '/etc/init.d/luci_vumeters';
var MAXCH  = 256;

// Rendering constants
var MIN_BOX      = 4;    // minimum LED segment height in px
var GLOW_MAX     = 32;   // disable peak glow above this channel count
var FPS_SM       = 60;   // fps for small grids (<=BIG_THRESH channels)
var FPS_BIG      = 30;   // fps for large grids
var BIG_THRESH   = 12;
var EASE         = 3;    // easing divisor
var EPSILON      = 0.5;  // snap-to-target threshold
var GAP          = 0.2;  // LED gap as fraction of LED height
var G_ON  = [ 'rgba(53,255,30,.9)',  'rgba(255,215,5,.9)',  'rgba(255,47,30,.9)'  ];
var G_OFF = [ 'rgba(13,64,8,.9)',    'rgba(64,53,0,.9)',    'rgba(64,12,8,.9)'    ];
// zone index:  0=green                1=yellow               2=red
var BG = 'rgb(32,32,32)';

function clamp(v, lo, hi, fb) {
	var n = parseInt(v, 10);
	if (isNaN(n)) n = (fb !== undefined ? fb : lo);
	return n < lo ? lo : n > hi ? hi : n;
}

function injectStyle() {
	if (document.getElementById('vum-s')) return;
	document.head.appendChild(E('style', { id: 'vum-s', type: 'text/css' }, [
		'#vum-root{width:100%;min-height:calc(100vh - 155px)}' +
		'#vum-meta{display:flex;gap:.7em;align-items:center;flex-wrap:wrap;margin:0 0 .4em;font-size:.9em}' +
		'#vum-meta code{white-space:nowrap}' +
		'#vum-st{margin:0 0 .4em;min-height:1.4em}' +
		// Config panel: shown when ok=false so users can override
		// device/channels without re-running the installer.
		'#vum-cfg{display:none;margin:0 0 .65em;padding:.55em .7em;' +
			'border:1px solid rgba(127,127,127,.3);border-radius:4px}' +
		'#vum-cfg .h{margin:0 0 .4em;font-size:.88em;opacity:.8}' +
		'#vum-cfg .r{display:flex;gap:.55em;align-items:flex-end;flex-wrap:wrap}' +
		'#vum-cfg label{display:flex;flex-direction:column;gap:.2em;font-size:.88em}' +
		'#vum-cfg input{width:12em}' +
		'#vum-wrap{width:100%;height:calc(100vh - 258px);min-height:230px;overflow:auto}' +
		'#vum-grid{display:grid;min-height:100%;gap:4px}' +
		'.vc{border:1px solid rgba(127,127,127,.35);padding:5px;min-width:50px;' +
			'min-height:96px;display:flex;flex-direction:column;align-items:stretch}' +
		// flex:1 1 0 + min-height:0 lets the canvas fill the grid-row height.
		// Dimensions are set in startMeters() from offsetWidth/offsetHeight so
		// buildGeom() always receives the true post-layout display size.
		'.vk{display:block;width:100%;flex:1 1 0;min-height:0;background:' + BG + ';border-radius:3px}' +
		'.vn{margin-top:.3em;line-height:1.2;font-size:.82em;text-align:center;white-space:nowrap}' +
		'.vp{padding:2em;text-align:center;border:1px dashed rgba(127,127,127,.4)}'
	]));
}

// ---- Rendering engine -------------------------------------------------------

function buildGeom(w, h) {
	var n = 16;
	while (n > 6 && h / (n + (n+1)*GAP) < MIN_BOX) n--;

	var red = Math.max(1, Math.round(n*3/16));
	var yel = Math.max(1, Math.round(n*4/16));
	if (red+yel > n-1) yel = Math.max(1, n-red-1);

	var bh = h / (n + (n+1)*GAP), gap = bh*GAP;
	var bw = w - gap*2, gx = (w-bw)/2;

	var id = [], bx = [], by = [], con = [], cof = [];
	for (var i = 0; i < n; i++) {
		var v = Math.abs(i-(n-1))+1;
		id[i]=v; bx[i]=gx; by[i]=gap+i*(bh+gap);
		var zi = v>n-red ? 2 : v>n-red-yel ? 1 : 0;
		con[i]=G_ON[zi]; cof[i]=G_OFF[zi];
	}
	return { w:w, h:h, n:n, bh:bh, bw:bw, id:id, bx:bx, by:by, on:con, off:cof };
}

function drawMeter(g, st, glow) {
	var ctx = st.ctx, maxOn = Math.ceil(st.v/100*g.n), pi=-1, pid=-1;
	ctx.fillStyle = BG; ctx.fillRect(0, 0, g.w, g.h);
	for (var i = 0; i < g.n; i++) {
		var on = g.id[i] <= maxOn;
		ctx.fillStyle = on ? g.on[i] : g.off[i];
		ctx.fillRect(g.bx[i], g.by[i], g.bw, g.bh);
		if (on && g.id[i] > pid) { pid=g.id[i]; pi=i; }
	}
	if (glow && pi >= 0) {
		ctx.save(); ctx.shadowBlur=10; ctx.shadowColor=g.on[pi];
		ctx.fillStyle=g.on[pi]; ctx.fillRect(g.bx[pi],g.by[pi],g.bw,g.bh);
		ctx.restore();
	}
}

// ---- View -------------------------------------------------------------------

return view.extend({
	handleSaveApply: null, handleSave: null, handleReset: null,

	load: function() {
		return uci.load(CONF).catch(function(e) {
			console.warn('vumeters: uci load:', e); return null;
		});
	},

	render: function() {
		injectStyle();

		var sts=[], geom=null, glow=true, budget=1000/FPS_SM;
		var raf=null, pollT=null, lastT=0, gRoot=null, rendCh=0;

		var pollMs  = clamp(uci.get(CONF,SECT,'poll_ms'),    50,  5000, 200);
		var maxCols = clamp(uci.get(CONF,SECT,'max_columns'),  1,   16,  16);

		// Status bar
		var mDev  = E('code',{},[ '-' ]);
		var mCh   = E('code',{},[ '0' ]);
		var mRate = E('code',{},[ '-' ]);
		var mPoll = E('code',{},[ String(pollMs)+' ms' ]);

		var status = E('div', { id:'vum-st', 'class':'alert-message notice' },
			[ _('Waiting for ALSA input levels\u2026') ]);

		// Config panel (shown on ok=false)
		var devI = E('input', {
			type:'text', 'class':'cbi-input-text',
			value: uci.get(CONF,SECT,'capture_device')||'auto',
			placeholder:'auto  or  plughw:1,0'
		});
		var chI = E('input', {
			type:'text', 'class':'cbi-input-text',
			value: uci.get(CONF,SECT,'channels')||'auto',
			placeholder:'auto  or  16'
		});
		var applyBtn = E('button', { 'class':'btn cbi-button cbi-button-save' },
			[ _('Apply \u0026 restart') ]);

		var cfg = E('div', { id:'vum-cfg' }, [
			E('div', { 'class':'h' }, [
				_('Detection failed or capture stopped \u2014 override device / channels:')
			]),
			E('div', { 'class':'r' }, [
				E('label',{},[E('span',{},[_('ALSA device')]),devI]),
				E('label',{},[E('span',{},[_('Channels')]),  chI ]),
				applyBtn
			])
		]);

		var grid = E('div', { id:'vum-grid' });

		// ---- Engine ---------------------------------------------------------

		function stopAll() {
			if (raf)   { window.cancelAnimationFrame(raf); raf=null; }
			if (pollT) { window.clearTimeout(pollT); pollT=null; }
			sts=[];
		}

		function setCh(ch, val) { var s=sts[ch-1]; if(s) s.t=clamp(val,0,100); }

		function setAll(vals) {
			if (!vals) return;
			for (var i=0; i<vals.length; i++) setCh(i+1, vals[i]);
		}

		// Shared rAF loop; no jitter (real ALSA data drives the meters).
		function tick(now) {
			raf = window.requestAnimationFrame(tick);
			if (document.hidden || now-lastT < budget) return;
			lastT = now;
			if (!document.body.contains(gRoot)) { stopAll(); return; }
			for (var i=0; i<sts.length; i++) {
				var s=sts[i], chg=false;
				if (s.v !== s.t) {
					s.v += (s.t-s.v)/EASE;
					if (Math.abs(s.t-s.v) < EPSILON) s.v=s.t;
					chg=true;
				}
				// Idle channels already painted blank are skipped to keep
				// large grids cheap when audio is quiet.
				if (chg||!s.idle) {
					drawMeter(geom, s, glow);
					s.idle = (s.v===0 && s.t===0);
				}
			}
		}

		function startMeters(cvs, root) {
			if (raf) { window.cancelAnimationFrame(raf); raf=null; }
			gRoot=root; sts=[];
			if (!cvs.length) return;

			// Read actual rendered dimensions after layout (setTimeout(0)
			// guarantees the browser has completed a layout pass first).
			var w = cvs[0].offsetWidth  || cvs[0].width;
			var h = cvs[0].offsetHeight || cvs[0].height;
			for (var i=0; i<cvs.length; i++) { cvs[i].width=w; cvs[i].height=h; }
			geom = buildGeom(w, h);

			var tot = cvs.length;
			glow   = tot <= GLOW_MAX;
			budget = 1000 / (tot > BIG_THRESH ? FPS_BIG : FPS_SM);
			sts    = new Array(tot);

			for (var j=0; j<cvs.length; j++) {
				var ctx = cvs[j].getContext('2d');
				ctx.fillStyle=BG; ctx.fillRect(0,0,geom.w,geom.h);
				sts[j] = { ctx:ctx, v:0, t:0, idle:true };
			}

			window.setVuChannelValue  = setCh;
			window.setVuChannelValues = setAll;
			lastT=0; raf=window.requestAnimationFrame(tick);
		}

		function renderGrid(nch, root) {
			var ch  = clamp(nch, 0, MAXCH, 0);
			var col = ch>0 ? Math.min(maxCols,ch) : 1;
			var row = ch>0 ? Math.ceil(ch/col) : 1;
			rendCh  = ch;

			// 1fr rows distribute available height evenly.
			grid.style.gridTemplateColumns = 'repeat('+col+',minmax(0,1fr))';
			grid.style.gridTemplateRows    = 'repeat('+row+',1fr)';

			while (grid.firstChild) grid.removeChild(grid.firstChild);

			if (!ch) {
				grid.appendChild(E('div',{ 'class':'vp' },[_('No capture channels detected yet.')]));
				if (raf) { window.cancelAnimationFrame(raf); raf=null; }
				sts=[]; return;
			}

			var cvs=[];
			for (var c=1; c<=ch; c++) {
				var cv=E('canvas',{ 'class':'vk',width:'64',height:'64' });
				cvs.push(cv);
				grid.appendChild(E('div',{ 'class':'vc' },[
					cv, E('div',{ 'class':'vn' },[ 'IN '+c ])
				]));
			}
			window.setTimeout(function(){ startMeters(cvs,root); }, 0);
		}

		// ---- Poll -----------------------------------------------------------

		function updateMeta(d) {
			mDev.textContent  = d.device||'-';
			mCh.textContent   = String(clamp(d.channels,0,MAXCH,0));
			mRate.textContent = d.rate ? String(d.rate)+' Hz' : '-';
			if (d.ok) {
				status.className='alert-message notice';
				status.textContent=d.message||_('Capturing ALSA input levels.');
				cfg.style.display='none';
			} else {
				status.className='alert-message warning';
				status.textContent=d.message||_('Waiting for ALSA input levels.');
				cfg.style.display='';
				if (d.device && devI.value==='auto') devI.value=d.device;
				if (d.channels && String(d.channels)!=='0' && chI.value==='auto')
					chI.value=String(d.channels);
			}
		}

		function onErr(e) {
			status.className='alert-message error';
			status.textContent=_('VU meter error: ')+e;
			cfg.style.display='';
		}

		function schedule(root) {
			if (!document.body.contains(root)) { stopAll(); return; }
			pollT = window.setTimeout(function(){ poll(root); }, pollMs);
		}

		function poll(root) {
			if (!document.body.contains(root)) { stopAll(); return; }
			fs.exec(LEVELS,[]).then(function(res) {
				try {
					var txt=(res&&res.stdout)?res.stdout.trim():'';
					var d=JSON.parse(txt||'{}');
					if (!d||typeof d!=='object') throw new Error('bad reply');
					if (typeof d.channels!=='number')
						d.channels=parseInt(d.channels||0,10)||0;
					if (d.channels!==rendCh) renderGrid(d.channels,root);
					if (Array.isArray(d.values)) setAll(d.values);
					updateMeta(d);
				} catch(e) { onErr(e); }
				schedule(root);
			}, function(e) { onErr(e); schedule(root); });
		}

		// ---- Config panel ---------------------------------------------------

		applyBtn.addEventListener('click', function() {
			var dev=devI.value.trim()||'auto', ch=chI.value.trim()||'auto';
			applyBtn.disabled=true;
			status.className='alert-message notice';
			status.textContent=_('Saving\u2026');
			if (!uci.get(CONF,SECT)) uci.add(CONF,'settings',SECT);
			uci.set(CONF,SECT,'capture_device',dev);
			uci.set(CONF,SECT,'channels',ch);
			uci.save()
				.then(function(){ return uci.apply(10); })
				.then(function(){ status.textContent=_('Saved \u2014 restarting\u2026'); return fs.exec(INITD,['restart']); })
				.then(function(){
					status.className='alert-message notice';
					status.textContent=_('Service restarted \u2014 waiting for levels\u2026');
					cfg.style.display='none'; applyBtn.disabled=false;
					if (pollT){ window.clearTimeout(pollT); pollT=null; }
					window.setTimeout(function(){ poll(root); },2000);
				}, function(e){
					status.className='alert-message error';
					status.textContent=_('Apply failed: ')+e;
					applyBtn.disabled=false;
				});
		});

		// ---- Root DOM -------------------------------------------------------

		var root = E('div', { id:'vum-root', 'class':'cbi-map' }, [
			E('h2',{},[_('VU Meters')]),
			E('div',{ 'class':'cbi-map-descr' },[
				_('Live ALSA capture input levels. One meter per channel.')
			]),
			E('div',{ id:'vum-meta' },[
				E('span',{},[_('Device'),  ': ',mDev ]),
				E('span',{},[_('Channels'),': ',mCh  ]),
				E('span',{},[_('Rate'),    ': ',mRate]),
				E('span',{},[_('Poll'),    ': ',mPoll])
			]),
			status, cfg,
			E('div',{ id:'vum-wrap' },[ grid ])
		]);

		renderGrid(0, root);
		poll(root);
		return root;
	}
});
EOF_VIEW

# ---- Permissions and services -----------------------------------------------
chmod 0755 "$CAP" "$LVL" "$INIT"
chmod 0644 "$VIEW" "$MENU" "$ACL"

rm -f /tmp/luci-indexcache 2>/dev/null||true
rm -f /tmp/luci-modulecache/* 2>/dev/null||true
[ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd restart >/dev/null 2>&1||true

if [ -x "$INIT" ]; then
	if [ "$ENABLED" = 1 ]; then
		"$INIT" enable  >/dev/null 2>&1||true
		"$INIT" restart >/dev/null 2>&1||true
	else
		"$INIT" disable >/dev/null 2>&1||true
		"$INIT" stop    >/dev/null 2>&1||true
	fi
fi
[ -x /etc/init.d/uhttpd ] && {
	/etc/init.d/uhttpd reload  >/dev/null 2>&1|| \
	/etc/init.d/uhttpd restart >/dev/null 2>&1||true; }

printf '\n[*] Installed LuCI ALSA VU Meters — LuCI -> Status -> VU Meters\n'
printf '    Device: %s  Channels: %s  Rate: %s  Cols: %s\n\n' \
	"$DEV" "$CH" "$RATE" "$COLS"
printf '    To test detection on the router:\n'
printf '      /usr/sbin/luci-vumeters-capture detect\n\n'
printf '    If Channels shows 0, use the in-page config panel or re-run with:\n'
printf '      sh %s --device plughw:1,0 --channels 16\n\n' "$0"
