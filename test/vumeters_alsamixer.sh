#!/bin/sh
#
# install_luci_vumeters_amixer_only.sh
#
# OpenWrt / LuCI installer for an amixer-only VU meter page.
#
# It intentionally avoids arecord, od, raw PCM parsing and a background capture
# daemon.  LuCI polls /usr/libexec/luci-vumeters-levels; that helper runs
# amixer and turns the percentage fields returned by one simple mixer control
# into JSON values.
#
# This is accurate as a live VU meter only when the chosen ALSA mixer control
# exposes live per-channel meter/level percentages.  Many common controls named
# Capture, Mic, Line or Master expose gain/mute settings, not the instantaneous
# audio signal.
#
# Usage:
#   sh install_luci_vumeters_amixer_only.sh
#   sh install_luci_vumeters_amixer_only.sh --card 1 --control Capture
#   sh install_luci_vumeters_amixer_only.sh --device hw:1,0 --control Capture
#   sh install_luci_vumeters_amixer_only.sh --card auto --control auto
#   sh install_luci_vumeters_amixer_only.sh --poll-ms 500 --max-cols 8

set -eu

AMIXER_CARD="auto"
AMIXER_CONTROL="auto"
POLL_MS="500"
MAX_COLUMNS="16"
ENABLED="1"

UCI_CONF="luci_vumeters"
UCI_SECTION="settings"
UCI_CONF_FILE="/etc/config/${UCI_CONF}"

VIEW_DIR="/www/luci-static/resources/view/vumeters"
VIEW_FILE="${VIEW_DIR}/vumeters.js"
MENU_FILE="/usr/share/luci/menu.d/luci-app-vumeters.json"
ACL_FILE="/usr/share/rpcd/acl.d/luci-app-vumeters.json"
LEVELS_SCRIPT="/usr/libexec/luci-vumeters-levels"
WRAPPER_SCRIPT="/usr/sbin/luci-vumeters-capture"
OLD_INIT_FILE="/etc/init.d/luci_vumeters"

usage() {
	cat <<EOF_USAGE
Usage: sh $0 [options]

Options:
  --card CARD|auto       ALSA card passed to amixer -c. Default: ${AMIXER_CARD}
  --device DEV           Compatibility alias: auto, N, hw:N,D or plughw:N,D
  --control NAME|auto    Simple mixer control for amixer sget. Default: ${AMIXER_CONTROL}
                         Examples: Capture, Mic, Line, Master, auto
  --poll-ms N            Polling interval in ms, 100-5000. Default: ${POLL_MS}
  --max-cols N           Maximum VU meters per row, 1-16. Default: ${MAX_COLUMNS}
  --disable              Install but return a disabled state from the helper.
  -h, --help             Show this help
EOF_USAGE
}

is_uint() {
	case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac
}

check_uint_range() {
	name="$1"; value="$2"; min="$3"; max="$4"
	is_uint "$value" || { echo "Invalid ${name}: ${value}" >&2; exit 1; }
	[ "$value" -ge "$min" ] && [ "$value" -le "$max" ] || {
		echo "Invalid ${name}: ${value}; expected ${min}-${max}" >&2
		exit 1
	}
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--card|--amixer-card)
			[ "$#" -ge 2 ] || { usage >&2; exit 1; }
			AMIXER_CARD="$2"; shift 2 ;;
		--device)
			[ "$#" -ge 2 ] || { usage >&2; exit 1; }
			case "$2" in
				auto) AMIXER_CARD="auto" ;;
				[0-9]*)
					case "$2" in *[!0-9]*) echo "Invalid --device card: $2" >&2; exit 1 ;; esac
					AMIXER_CARD="$2" ;;
				*hw:[0-9]*,[0-9]*)
					AMIXER_CARD="$(printf '%s\n' "$2" | sed -n 's/^[^:]*hw:\([0-9][0-9]*\),[0-9][0-9]*.*$/\1/p')"
					[ -n "$AMIXER_CARD" ] || { echo "Invalid --device value: $2" >&2; exit 1; } ;;
				*) echo "Invalid --device value: $2; use auto, N, hw:N,D or plughw:N,D" >&2; exit 1 ;;
			esac
			shift 2 ;;
		--control|--amixer-control)
			[ "$#" -ge 2 ] || { usage >&2; exit 1; }
			AMIXER_CONTROL="$2"; shift 2 ;;
		--poll-ms)
			[ "$#" -ge 2 ] || { usage >&2; exit 1; }
			POLL_MS="$2"; shift 2 ;;
		--max-cols|--max-columns)
			[ "$#" -ge 2 ] || { usage >&2; exit 1; }
			MAX_COLUMNS="$2"; shift 2 ;;
		--disable)
			ENABLED="0"; shift ;;
		-h|--help)
			usage; exit 0 ;;
		*)
			echo "Unknown argument: $1" >&2
			usage >&2
			exit 1 ;;
	esac
done

check_uint_range "poll-ms" "$POLL_MS" 100 5000
check_uint_range "max-cols" "$MAX_COLUMNS" 1 16

if [ "$(id -u)" != "0" ]; then
	echo "Run this script as root on the OpenWrt router." >&2
	exit 1
fi

if [ ! -d "/usr/share/luci/menu.d" ] || [ ! -d "/www/luci-static/resources" ]; then
	echo "LuCI paths not found. Install LuCI first." >&2
	exit 1
fi

command -v uci >/dev/null 2>&1 || { echo "uci not found; this does not look like OpenWrt." >&2; exit 1; }
command -v amixer >/dev/null 2>&1 || echo "Warning: amixer not found. Install the package that provides amixer." >&2

backup_if_exists() {
	file="$1"
	if [ -f "$file" ]; then
		ts="$(date +%Y%m%d%H%M%S 2>/dev/null || echo backup)"
		cp -p "$file" "${file}.bak.${ts}"
	fi
}

umask 022
mkdir -p "$VIEW_DIR" "$(dirname "$MENU_FILE")" "$(dirname "$ACL_FILE")" \
	"$(dirname "$LEVELS_SCRIPT")" "$(dirname "$WRAPPER_SCRIPT")"

backup_if_exists "$VIEW_FILE"
backup_if_exists "$MENU_FILE"
backup_if_exists "$ACL_FILE"
backup_if_exists "$LEVELS_SCRIPT"
backup_if_exists "$WRAPPER_SCRIPT"
backup_if_exists "$OLD_INIT_FILE"

if [ -x "$OLD_INIT_FILE" ]; then
	"$OLD_INIT_FILE" stop >/dev/null 2>&1 || true
	"$OLD_INIT_FILE" disable >/dev/null 2>&1 || true
fi
rm -f "$OLD_INIT_FILE"

[ -f "$UCI_CONF_FILE" ] || : > "$UCI_CONF_FILE"
uci -q revert "$UCI_CONF" 2>/dev/null || true
uci -q set "${UCI_CONF}.${UCI_SECTION}=settings"
uci -q set "${UCI_CONF}.${UCI_SECTION}.source=amixer"
uci -q set "${UCI_CONF}.${UCI_SECTION}.amixer_card=${AMIXER_CARD}"
uci -q set "${UCI_CONF}.${UCI_SECTION}.amixer_control=${AMIXER_CONTROL}"
uci -q set "${UCI_CONF}.${UCI_SECTION}.poll_ms=${POLL_MS}"
uci -q set "${UCI_CONF}.${UCI_SECTION}.max_columns=${MAX_COLUMNS}"
uci -q set "${UCI_CONF}.${UCI_SECTION}.enabled=${ENABLED}"
uci -q commit "$UCI_CONF"

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

cat > "$ACL_FILE" <<'EOF_ACL'
{
	"luci-app-vumeters": {
		"description": "Grant access to the LuCI amixer VU meters page",
		"read": {
			"uci": [ "luci_vumeters" ],
			"ubus": { "file": [ "exec" ] },
			"file": { "/usr/libexec/luci-vumeters-levels": [ "exec" ] }
		},
		"write": { "uci": [ "luci_vumeters" ] }
	}
}
EOF_ACL

cat > "$LEVELS_SCRIPT" <<'EOF_LEVELS'
#!/bin/sh

CONF="luci_vumeters"
SECTION="settings"
MAX_CHANNELS="256"

is_uint() {
	case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac
}

uci_get() {
	key="$1"; def="$2"
	val="$(uci -q get "${CONF}.${SECTION}.${key}" 2>/dev/null || true)"
	[ -n "$val" ] && printf '%s\n' "$val" || printf '%s\n' "$def"
}

json_escape() {
	printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/[[:cntrl:]]/ /g'
}

emit_json() {
	ok="$1"; card="$2"; control="$3"; channels="$4"; values="$5"; message="$6"
	is_uint "$channels" || channels="0"
	case "$values" in \[*\]) ;; *) values="[]" ;; esac
	now="$(date +%s 2>/dev/null || echo 0)"
	card_json="$(json_escape "$card")"
	control_json="$(json_escape "$control")"
	msg_json="$(json_escape "$message")"
	printf '{"ok":%s,"timestamp":%s,"source":"amixer","card":"%s","control":"%s","channels":%s,"values":%s,"message":"%s"}\n' \
		"$ok" "$now" "$card_json" "$control_json" "$channels" "$values" "$msg_json"
}

list_cards() {
	if [ -r /proc/asound/cards ]; then
		awk '/^[[:space:]]*[0-9]+[[:space:]]+\[/ { print $1 }' /proc/asound/cards
	else
		printf '%s\n' 0
	fi
}

controls_for_card() {
	amixer -c "$1" scontrols 2>/dev/null | sed -n "s/^Simple mixer control '\([^']*\)'.*/\1/p"
}

extract_values() {
	awk '
		BEGIN { n = 0; out = "[" }
		/%/ {
			for (i = 1; i <= NF; i++) {
				f = $i
				if (f ~ /%/) {
					gsub(/[^0-9]/, "", f)
					if (f != "") {
						v = f + 0
						if ($0 ~ /\[off\]/) v = 0
						if (v > 100) v = 100
						n++
						if (n > 1) out = out ","
						out = out v
						break
					}
				}
			}
		}
		END { if (n < 1) exit 1; out = out "]"; printf "%d|%s\n", n, out }
	'
}

control_values() {
	card="$1"; control="$2"
	amixer -c "$card" sget "$control" 2>/dev/null | extract_values
}

control_works() {
	control_values "$1" "$2" >/dev/null 2>&1
}

best_control_for_card() {
	card="$1"
	controls="$(controls_for_card "$card")"
	[ -n "$controls" ] || return 1

	for pat in peak meter vu rms signal level input capture mic line master; do
		ctl="$(printf '%s\n' "$controls" | awk -v p="$pat" 'index(tolower($0), p) { print; exit }')"
		if [ -n "$ctl" ] && control_works "$card" "$ctl"; then
			printf '%s\n' "$ctl"
			return 0
		fi
	done

	hit="$(printf '%s\n' "$controls" | while IFS= read -r ctl; do
		[ -n "$ctl" ] || continue
		if control_works "$card" "$ctl"; then
			printf '%s\n' "$ctl"
			break
		fi
	done)"
	[ -n "$hit" ] || return 1
	printf '%s\n' "$hit"
}

resolve_card_control() {
	cfg_card="$(uci_get amixer_card auto)"
	cfg_control="$(uci_get amixer_control auto)"
	[ "$cfg_card" = "auto" ] && cards="$(list_cards)" || cards="$cfg_card"

	for card in $cards; do
		[ -n "$card" ] || continue
		if [ "$cfg_control" = "auto" ]; then
			control="$(best_control_for_card "$card" 2>/dev/null || true)"
			[ -n "$control" ] || continue
		else
			control="$cfg_control"
			control_works "$card" "$control" || continue
		fi
		printf '%s|%s\n' "$card" "$control"
		return 0
	done
	return 1
}

levels_json() {
	[ "$(uci_get enabled 1)" = "0" ] && {
		emit_json false "" "" 0 "[]" "amixer VU meters are disabled in UCI"
		return 0
	}

	command -v amixer >/dev/null 2>&1 || {
		emit_json false "" "" 0 "[]" "amixer not found; install the package that provides amixer"
		return 0
	}

	resolved="$(resolve_card_control 2>/dev/null || true)"
	if [ -z "$resolved" ]; then
		emit_json false "$(uci_get amixer_card auto)" "$(uci_get amixer_control auto)" 0 "[]" "no amixer simple control with percentage values found"
		return 0
	fi

	old_ifs="$IFS"; IFS='|'; set -- $resolved; IFS="$old_ifs"
	card="$1"; control="$2"
	parsed="$(control_values "$card" "$control" 2>/dev/null || true)"
	if [ -z "$parsed" ]; then
		emit_json false "$card" "$control" 0 "[]" "amixer control did not return percentage values"
		return 0
	fi

	channels="${parsed%%|*}"
	values="${parsed#*|}"
	if ! is_uint "$channels" || [ "$channels" -lt 1 ] || [ "$channels" -gt "$MAX_CHANNELS" ]; then
		emit_json false "$card" "$control" 0 "[]" "invalid channel count parsed from amixer"
		return 0
	fi

	emit_json true "$card" "$control" "$channels" "$values" "amixer -c ${card} sget ${control}"
}

probe() {
	command -v amixer >/dev/null 2>&1 || { echo "amixer not found"; return 1; }
	for card in $(list_cards); do
		echo "card ${card}"
		controls="$(controls_for_card "$card")"
		[ -n "$controls" ] || { echo "  no simple mixer controls found"; continue; }
		printf '%s\n' "$controls" | while IFS= read -r control; do
			[ -n "$control" ] || continue
			parsed="$(control_values "$card" "$control" 2>/dev/null || true)"
			if [ -n "$parsed" ]; then
				channels="${parsed%%|*}"
				values="${parsed#*|}"
				echo "  ${control}: channels=${channels} values=${values}"
			else
				echo "  ${control}: no percentage values"
			fi
		done
	done
}

case "${1:-json}" in
	json|levels|detect) levels_json ;;
	probe) probe ;;
	*) echo "Usage: $0 [json|levels|detect|probe]" >&2; exit 1 ;;
esac
EOF_LEVELS

cat > "$WRAPPER_SCRIPT" <<'EOF_WRAPPER'
#!/bin/sh
exec /usr/libexec/luci-vumeters-levels "$@"
EOF_WRAPPER

cat > "$VIEW_FILE" <<'EOF_VIEW'
'use strict';
'require view';
'require uci';
'require fs';

var CONF = 'luci_vumeters';
var SECTION = 'settings';
var LEVELS_HELPER = '/usr/libexec/luci-vumeters-levels';
var MAX_CHANNELS = 256;

function clampInt(value, min, max, fallback) {
	var n = parseInt(value, 10);
	if (isNaN(n)) n = fallback;
	if (n < min) n = min;
	if (n > max) n = max;
	return n;
}

function injectStyle() {
	if (document.getElementById('vumeters-style')) return;
	document.head.appendChild(E('style', { 'id': 'vumeters-style', 'type': 'text/css' }, [
		'#vumeters-root{width:100%;min-height:calc(100vh - 155px)}' +
		'#vumeters-summary{display:flex;gap:.75em;align-items:center;flex-wrap:wrap;margin:0 0 .6em 0;font-size:.9em}' +
		'#vumeters-summary code{white-space:nowrap}' +
		'#vumeters-status{margin:0 0 .6em 0;min-height:1.4em}' +
		'#vumeters-grid{display:grid;gap:6px;min-height:calc(100vh - 255px)}' +
		'.vumeter-cell{border:1px solid rgba(127,127,127,.35);padding:6px;min-width:56px;min-height:140px;display:flex;flex-direction:column}' +
		'.vumeter-track{position:relative;flex:1 1 auto;min-height:100px;background:linear-gradient(to top,rgba(20,70,20,.55) 0%,rgba(20,70,20,.55) 65%,rgba(90,80,10,.55) 65%,rgba(90,80,10,.55) 85%,rgba(90,20,20,.55) 85%,rgba(90,20,20,.55) 100%);border-radius:3px;overflow:hidden}' +
		'.vumeter-fill{position:absolute;left:0;right:0;bottom:0;height:0%;background:linear-gradient(to top,rgba(53,255,30,.95) 0%,rgba(53,255,30,.95) 65%,rgba(255,215,5,.95) 65%,rgba(255,215,5,.95) 85%,rgba(255,47,30,.95) 85%,rgba(255,47,30,.95) 100%);transition:height .12s linear}' +
		'.vumeter-value{position:absolute;left:0;right:0;bottom:.35em;text-align:center;font-size:.85em;color:#fff;text-shadow:0 1px 2px #000}' +
		'.vumeter-caption{margin-top:.35em;line-height:1.2;font-size:.82em;text-align:center;white-space:nowrap}' +
		'.vumeters-placeholder{padding:2em;text-align:center;border:1px dashed rgba(127,127,127,.45)}'
	]));
}

return view.extend({
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	load: function() {
		return uci.load(CONF).catch(function(err) {
			console.warn('vumeters: could not load UCI config "' + CONF + '":', err);
			return null;
		});
	},

	render: function() {
		injectStyle();

		var pollMs = clampInt(uci.get(CONF, SECTION, 'poll_ms'), 100, 5000, 500);
		var maxColumns = clampInt(uci.get(CONF, SECTION, 'max_columns'), 1, 16, 16);
		var renderedChannels = 0;
		var timer = null;
		var fills = [];
		var valueLabels = [];

		var summaryCard = E('code', {}, [ '-' ]);
		var summaryControl = E('code', {}, [ '-' ]);
		var summaryChannels = E('code', {}, [ '0' ]);
		var summaryPoll = E('code', {}, [ String(pollMs) + ' ms' ]);
		var status = E('div', { 'id': 'vumeters-status', 'class': 'alert-message notice' }, [ _('Waiting for amixer levels...') ]);
		var grid = E('div', { 'id': 'vumeters-grid' });

		function renderGrid(channelCount) {
			var channels = clampInt(channelCount, 0, MAX_CHANNELS, 0);
			var cols = channels > 0 ? Math.min(maxColumns, channels) : 1;
			var rows = channels > 0 ? Math.ceil(channels / cols) : 1;
			renderedChannels = channels;
			fills = [];
			valueLabels = [];
			grid.style.gridTemplateColumns = 'repeat(' + cols + ', minmax(0, 1fr))';
			grid.style.gridTemplateRows = 'repeat(' + rows + ', minmax(130px, 1fr))';
			while (grid.firstChild) grid.removeChild(grid.firstChild);

			if (channels === 0) {
				grid.appendChild(E('div', { 'class': 'vumeters-placeholder' }, [ _('No amixer percentage channels detected yet.') ]));
				return;
			}

			for (var channel = 1; channel <= channels; channel++) {
				var fill = E('div', { 'class': 'vumeter-fill' });
				var val = E('div', { 'class': 'vumeter-value' }, [ '0%' ]);
				fills.push(fill);
				valueLabels.push(val);
				grid.appendChild(E('div', { 'class': 'vumeter-cell' }, [
					E('div', { 'class': 'vumeter-track' }, [ fill, val ]),
					E('div', { 'class': 'vumeter-caption' }, [ 'CH ' + channel ])
				]));
			}
		}

		function setValues(values) {
			if (!Array.isArray(values)) return;
			for (var i = 0; i < fills.length; i++) {
				var pct = clampInt(values[i], 0, 100, 0);
				fills[i].style.height = pct + '%';
				valueLabels[i].textContent = pct + '%';
			}
		}

		function updateMetadata(data) {
			summaryCard.textContent = data.card || '-';
			summaryControl.textContent = data.control || '-';
			summaryChannels.textContent = String(clampInt(data.channels, 0, MAX_CHANNELS, 0));
			summaryPoll.textContent = String(pollMs) + ' ms';
			status.className = data.ok ? 'alert-message notice' : 'alert-message warning';
			status.textContent = data.message || (data.ok ? _('Reading amixer levels.') : _('Waiting for amixer levels.'));
		}

		function handleReply(res) {
			var text = (res && res.stdout) ? res.stdout.trim() : '';
			var data = JSON.parse(text || '{}');
			var channels = clampInt(data.channels, 0, MAX_CHANNELS, 0);
			if (channels !== renderedChannels) renderGrid(channels);
			setValues(data.values);
			updateMetadata(data);
		}

		function schedule(root) {
			if (!document.body.contains(root)) {
				if (timer !== null) window.clearTimeout(timer);
				return;
			}
			timer = window.setTimeout(function() { poll(root); }, pollMs);
		}

		function poll(root) {
			fs.exec(LEVELS_HELPER, []).then(function(res) {
				try { handleReply(res); }
				catch (e) {
					status.className = 'alert-message error';
					status.textContent = _('Error processing amixer data: ') + e;
				}
				schedule(root);
			}, function(err) {
				status.className = 'alert-message error';
				status.textContent = _('Cannot execute amixer helper: ') + err;
				schedule(root);
			});
		}

		var root = E('div', { 'id': 'vumeters-root', 'class': 'cbi-map' }, [
			E('h2', {}, [ _('VU Meters') ]),
			E('div', { 'class': 'cbi-map-descr' }, [ _('amixer-only ALSA percentages. One meter is shown for each percentage value returned by the selected mixer control.') ]),
			E('div', { 'id': 'vumeters-summary' }, [
				E('span', {}, [ _('Card'), ': ', summaryCard ]),
				E('span', {}, [ _('Control'), ': ', summaryControl ]),
				E('span', {}, [ _('Channels'), ': ', summaryChannels ]),
				E('span', {}, [ _('Poll'), ': ', summaryPoll ])
			]),
			status,
			grid
		]);

		renderGrid(0);
		poll(root);
		return root;
	}
});
EOF_VIEW

chmod 0755 "$LEVELS_SCRIPT" "$WRAPPER_SCRIPT"
chmod 0644 "$VIEW_FILE" "$MENU_FILE" "$ACL_FILE"

rm -f /tmp/luci-indexcache 2>/dev/null || true
rm -f /tmp/luci-modulecache/* 2>/dev/null || true
[ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd restart >/dev/null 2>&1 || true
if [ -x /etc/init.d/uhttpd ]; then
	/etc/init.d/uhttpd reload >/dev/null 2>&1 || /etc/init.d/uhttpd restart >/dev/null 2>&1 || true
fi

echo "Installed LuCI amixer-only VU Meters."
echo "Open: LuCI -> Status -> VU Meters"
echo "amixer card: ${AMIXER_CARD}  control: ${AMIXER_CONTROL}  poll: ${POLL_MS} ms  max-cols: ${MAX_COLUMNS}"
echo "No background capture daemon is used. Diagnostic: /usr/sbin/luci-vumeters-capture probe"
