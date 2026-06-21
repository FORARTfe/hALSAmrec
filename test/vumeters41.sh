#!/bin/sh
#
# install_luci_vumeters.sh
#
# OpenWrt 24.x / LuCI-compatible installer.
# Usage:
#   sh install_luci_vumeters.sh
#   sh install_luci_vumeters.sh --rows 3 --cols 2
#   sh install_luci_vumeters.sh --rows 3 --cols 3 --demo 0
#
# After installation:
#   LuCI -> Status -> VU Meters
#
# The page exposes a browser-side helper:
#   window.setVuChannelValue(channelNumber, value0to100)
# Example from browser console:
#   window.setVuChannelValue(1, 80)

set -eu

ROWS="2"
COLS="2"
DEMO="1"

APP_ID="luci-app-vumeters"
UCI_CONF="luci_vumeters"
UCI_SECTION="settings"
UCI_CONF_FILE="/etc/config/${UCI_CONF}"

VIEW_DIR="/www/luci-static/resources/view/vumeters"
VIEW_FILE="${VIEW_DIR}/vumeters.js"
MENU_FILE="/usr/share/luci/menu.d/luci-app-vumeters.json"
ACL_FILE="/usr/share/rpcd/acl.d/luci-app-vumeters.json"

MAX_ROWS="12"
MAX_COLS="12"

usage() {
	cat <<EOF
Usage: sh $0 [--rows N] [--cols N] [--demo 0|1]

Options:
  --rows N        Initial row count, 1-${MAX_ROWS}. Default: ${ROWS}
  --cols N        Initial column count, 1-${MAX_COLS}. Default: ${COLS}
  --columns N     Same as --cols
  --demo 0|1      Enable random demo values by default. Default: ${DEMO}
  -h, --help      Show this help
EOF
}

is_uint() {
	case "$1" in
		''|*[!0-9]*) return 1 ;;
		*) return 0 ;;
	esac
}

check_range() {
	name="$1"
	value="$2"
	min="$3"
	max="$4"

	if ! is_uint "$value"; then
		echo "Invalid ${name}: ${value}" >&2
		exit 1
	fi

	if [ "$value" -lt "$min" ] || [ "$value" -gt "$max" ]; then
		echo "Invalid ${name}: ${value}; expected ${min}-${max}" >&2
		exit 1
	fi
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--rows)
			[ "$#" -ge 2 ] || { usage >&2; exit 1; }
			ROWS="$2"
			shift 2
			;;
		--cols|--columns)
			[ "$#" -ge 2 ] || { usage >&2; exit 1; }
			COLS="$2"
			shift 2
			;;
		--demo)
			[ "$#" -ge 2 ] || { usage >&2; exit 1; }
			DEMO="$2"
			shift 2
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			echo "Unknown argument: $1" >&2
			usage >&2
			exit 1
			;;
	esac
done

check_range "rows" "$ROWS" 1 "$MAX_ROWS"
check_range "cols" "$COLS" 1 "$MAX_COLS"

case "$DEMO" in
	0|1) ;;
	*)
		echo "Invalid demo value: ${DEMO}; expected 0 or 1" >&2
		exit 1
		;;
esac

if [ "$(id -u)" != "0" ]; then
	echo "Run this script as root on the OpenWrt router." >&2
	exit 1
fi

if [ ! -d "/usr/share/luci/menu.d" ] || [ ! -d "/www/luci-static/resources" ]; then
	echo "LuCI paths not found. Install LuCI first, for example: opkg update && opkg install luci" >&2
	exit 1
fi

if ! command -v uci >/dev/null 2>&1; then
	echo "uci command not found; this does not look like a normal OpenWrt system." >&2
	exit 1
fi

backup_if_exists() {
	file="$1"
	if [ -f "$file" ]; then
		ts="$(date +%Y%m%d%H%M%S 2>/dev/null || echo backup)"
		cp -p "$file" "${file}.bak.${ts}"
	fi
}

umask 022

mkdir -p "$VIEW_DIR"
mkdir -p "$(dirname "$MENU_FILE")"
mkdir -p "$(dirname "$ACL_FILE")"

backup_if_exists "$VIEW_FILE"
backup_if_exists "$MENU_FILE"
backup_if_exists "$ACL_FILE"

# Make sure the uci package file exists *before* we touch it. rpcd's "uci"
# ubus object (which LuCI's browser-side uci.load() talks to) returns ubus
# code 4 ("Resource not found") if /etc/config/<name> is missing, and a
# rejected uci.load() crashes the whole view before render() ever runs.
[ -f "$UCI_CONF_FILE" ] || : > "$UCI_CONF_FILE"

# Clear out any stale uncommitted delta from a previous interrupted run of
# this installer, so the batch below starts from a clean, predictable state.
uci -q revert "$UCI_CONF" 2>/dev/null || true

uci -q batch <<EOF
set ${UCI_CONF}.${UCI_SECTION}=grid
set ${UCI_CONF}.${UCI_SECTION}.rows='${ROWS}'
set ${UCI_CONF}.${UCI_SECTION}.cols='${COLS}'
set ${UCI_CONF}.${UCI_SECTION}.random_demo='${DEMO}'
commit ${UCI_CONF}
EOF

# Defense in depth: verify the commit actually landed. If it didn't (e.g.
# read-only overlay, odd uci state), write a minimal valid config directly
# so the file is never missing or empty when LuCI asks rpcd for it.
if ! uci -q get "${UCI_CONF}.${UCI_SECTION}" >/dev/null 2>&1; then
	echo "Warning: 'uci commit ${UCI_CONF}' did not persist as expected; writing ${UCI_CONF_FILE} directly." >&2
	cat > "$UCI_CONF_FILE" <<-EOF2
	config grid '${UCI_SECTION}'
		option rows '${ROWS}'
		option cols '${COLS}'
		option random_demo '${DEMO}'
	EOF2
fi

cat > "$MENU_FILE" <<'EOF'
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
EOF

cat > "$ACL_FILE" <<'EOF'
{
	"luci-app-vumeters": {
		"description": "Grant access to the LuCI VU meters page",
		"read": {
			"uci": [ "luci_vumeters" ]
		},
		"write": {
			"uci": [ "luci_vumeters" ]
		}
	}
}
EOF

cat > "$VIEW_FILE" <<'EOF'
'use strict';
'require view';
'require uci';

var CONF = 'luci_vumeters';
var SECTION = 'settings';

var MIN_ROWS = 1;
var MAX_ROWS = 12;
var MIN_COLS = 1;
var MAX_COLS = 12;

// ---- Performance tuning constants -----------------------------------------
//
// These exist because canvas work scales with rows*cols, and this page has
// to stay responsive on very low-power SBCs (e.g. Raspberry Pi class
// hardware) even with a full 12x12 = 144 channel grid.

var MIN_BOX_PX = 4;            // never draw LED segments thinner than this;
                                // dense grids automatically use fewer, fatter
                                // segments instead of 16 useless slivers
var PEAK_GLOW_MAX_CHANNELS = 32; // only spend shadowBlur (expensive) on the
                                  // single "peak" LED per meter, and only
                                  // below this total channel count
var FPS_SMALL_GRID = 60;       // small grids keep the original silky feel
var FPS_BIG_GRID = 30;         // big grids redraw less often - a VU meter
                                // doesn't need 60fps to read fine, and this
                                // alone roughly halves canvas work
var BIG_GRID_CHANNEL_THRESHOLD = 12;
var EASE_DIVISOR = 5;
var SETTLE_EPSILON = 0.5;      // snap to target once this close, so idle
                                // channels can actually reach "0" and stop
                                // being redrawn every frame

var COLOR_GREEN_ON   = 'rgba(53,255,30,0.9)';
var COLOR_GREEN_OFF  = 'rgba(13,64,8,0.9)';
var COLOR_YELLOW_ON  = 'rgba(255,215,5,0.9)';
var COLOR_YELLOW_OFF = 'rgba(64,53,0,0.9)';
var COLOR_RED_ON     = 'rgba(255,47,30,0.9)';
var COLOR_RED_OFF    = 'rgba(64,12,8,0.9)';
var BG_COLOR          = 'rgb(32,32,32)';
var BOX_GAP_FRACTION  = 0.2;
var JITTER_AMOUNT     = 0.01;

function clampInt(value, min, max, fallback) {
	var n = parseInt(value, 10);

	if (isNaN(n))
		n = fallback;

	if (n < min)
		n = min;

	if (n > max)
		n = max;

	return n;
}

function clampMeterValue(value) {
	var n = parseInt(value, 10);

	if (isNaN(n))
		n = 0;

	if (n < 0)
		n = 0;

	if (n > 100)
		n = 100;

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

		'#vumeters-controls {' +
			'display: flex;' +
			'gap: 1em;' +
			'align-items: end;' +
			'flex-wrap: wrap;' +
			'margin: 0 0 1em 0;' +
		'}' +

		'#vumeters-controls label {' +
			'display: flex;' +
			'flex-direction: column;' +
			'gap: .25em;' +
		'}' +

		'#vumeters-controls .inline-check {' +
			'flex-direction: row;' +
			'align-items: center;' +
			'gap: .45em;' +
			'margin-bottom: .35em;' +
		'}' +

		'#vumeters-controls input[type="number"] {' +
			'width: 5.5em;' +
		'}' +

		'#vumeters-status {' +
			'margin: 0 0 .75em 0;' +
			'min-height: 1.4em;' +
		'}' +

		'#vumeters-grid-wrap {' +
			'width: 100%;' +
			'height: calc(100vh - 255px);' +
			'min-height: 360px;' +
			'overflow: hidden;' +
		'}' +

		'table.vumeters-grid {' +
			'width: 100%;' +
			'height: 100%;' +
			'table-layout: fixed;' +
			'border-collapse: collapse;' +
		'}' +

		'table.vumeters-grid td {' +
			'border: 1px solid rgba(127,127,127,.35);' +
			'padding: 8px;' +
			'vertical-align: middle;' +
			'text-align: center;' +
		'}' +

		'.vumeter-cell {' +
			'height: 100%;' +
			'display: flex;' +
			'flex-direction: column;' +
			'align-items: stretch;' +
			'justify-content: center;' +
		'}' +

		'.vumeter-canvas {' +
			'display: block;' +
			'width: 100%;' +
			'flex: 1 1 auto;' +
			'min-height: 80px;' +
			'background: rgb(32,32,32);' +
			'border-radius: 4px;' +
		'}' +

		'.vumeter-caption {' +
			'margin-top: .45em;' +
			'line-height: 1.2;' +
			'font-size: .95em;' +
			'white-space: nowrap;' +
		'}'
	]));
}

// ---- Shared rendering engine -----------------------------------------------
//
// All cells in the grid render at the same pixel size (it's derived purely
// from rows/cols), so box geometry, segment count, and per-segment colors
// are computed exactly ONCE per grid build and shared by every channel,
// instead of being recomputed per-meter or, worse, per-frame.

function pickBoxCount(heightPx) {
	var boxCount = 16;

	while (boxCount > 6) {
		var boxHeight = heightPx / (boxCount + (boxCount + 1) * BOX_GAP_FRACTION);

		if (boxHeight >= MIN_BOX_PX)
			break;

		boxCount--;
	}

	return boxCount;
}

function deriveZoneCounts(boxCount) {
	// keep roughly the same proportions as the original fixed 16-segment
	// meter (3 red / 4 yellow / 9 green)
	var red = Math.max(1, Math.round(boxCount * 3 / 16));
	var yellow = Math.max(1, Math.round(boxCount * 4 / 16));

	if (red + yellow > boxCount - 1)
		yellow = Math.max(1, boxCount - red - 1);

	var green = boxCount - red - yellow;

	return { red: red, yellow: yellow, green: green };
}

function buildGeometry(widthPx, heightPx) {
	var boxCount = pickBoxCount(heightPx);
	var zones = deriveZoneCounts(boxCount);

	var boxHeight = heightPx / (boxCount + (boxCount + 1) * BOX_GAP_FRACTION);
	var boxGapY = boxHeight * BOX_GAP_FRACTION;
	var boxWidth = widthPx - (boxGapY * 2);
	var boxGapX = (widthPx - boxWidth) / 2;

	var boxX = new Array(boxCount);
	var boxY = new Array(boxCount);
	var colorOn = new Array(boxCount);
	var colorOff = new Array(boxCount);
	var boxId = new Array(boxCount);

	for (var i = 0; i < boxCount; i++) {
		var id = Math.abs(i - (boxCount - 1)) + 1;

		boxId[i] = id;
		boxX[i] = boxGapX;
		boxY[i] = boxGapY + i * (boxHeight + boxGapY);

		if (id > boxCount - zones.red) {
			colorOn[i] = COLOR_RED_ON;
			colorOff[i] = COLOR_RED_OFF;
		} else if (id > boxCount - zones.red - zones.yellow) {
			colorOn[i] = COLOR_YELLOW_ON;
			colorOff[i] = COLOR_YELLOW_OFF;
		} else {
			colorOn[i] = COLOR_GREEN_ON;
			colorOff[i] = COLOR_GREEN_OFF;
		}
	}

	return {
		width: widthPx,
		height: heightPx,
		boxCount: boxCount,
		boxWidth: boxWidth,
		boxHeight: boxHeight,
		boxId: boxId,
		boxX: boxX,
		boxY: boxY,
		colorOn: colorOn,
		colorOff: colorOff
	};
}

function drawMeter(geom, state, glowEnabled) {
	var ctx = state.ctx;
	var boxCount = geom.boxCount;
	var boxId = geom.boxId;
	var boxX = geom.boxX;
	var boxY = geom.boxY;
	var colorOn = geom.colorOn;
	var colorOff = geom.colorOff;
	var boxWidth = geom.boxWidth;
	var boxHeight = geom.boxHeight;

	ctx.fillStyle = BG_COLOR;
	ctx.fillRect(0, 0, geom.width, geom.height);

	var maxOn = Math.ceil((state.curVal / 100) * boxCount);
	var peakIndex = -1;
	var peakId = -1;

	for (var i = 0; i < boxCount; i++) {
		var on = boxId[i] <= maxOn;

		ctx.fillStyle = on ? colorOn[i] : colorOff[i];
		ctx.fillRect(boxX[i], boxY[i], boxWidth, boxHeight);

		if (on && boxId[i] > peakId) {
			peakId = boxId[i];
			peakIndex = i;
		}
	}

	// A single glowing "peak" segment instead of glowing every lit segment -
	// shadowBlur is the single most expensive canvas operation, so this caps
	// its cost at one draw per meter (and it's skipped entirely on large
	// grids, see PEAK_GLOW_MAX_CHANNELS).
	if (glowEnabled && peakIndex >= 0) {
		ctx.save();
		ctx.shadowBlur = 10;
		ctx.shadowColor = colorOn[peakIndex];
		ctx.fillStyle = colorOn[peakIndex];
		ctx.fillRect(boxX[peakIndex], boxY[peakIndex], boxWidth, boxHeight);
		ctx.restore();
	}
}

return view.extend({
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	load: function() {
		// If the uci config is missing or rpcd can't find it for any reason,
		// don't let the whole view crash with an uncaught RPCError - fall
		// back to built-in defaults instead (see render() below).
		return uci.load(CONF).catch(function(err) {
			console.warn('vumeters: could not load uci config "' + CONF + '", using defaults:', err);
			return null;
		});
	},

	render: function() {
		injectStyle();

		var channelStates = [];   // { ctx, curVal, target, drawnIdle }
		var geom = null;
		var glowEnabled = true;
		var frameBudgetMs = 1000 / FPS_SMALL_GRID;
		var rafHandle = null;
		var demoTimer = null;
		var lastFrameTime = 0;
		var gridRoot = null;

		var rows = clampInt(uci.get(CONF, SECTION, 'rows'), MIN_ROWS, MAX_ROWS, 2);
		var cols = clampInt(uci.get(CONF, SECTION, 'cols'), MIN_COLS, MAX_COLS, 2);
		var randomDemo = uci.get(CONF, SECTION, 'random_demo') !== '0';

		var rowsInput = E('input', {
			'id': 'vumeters-rows',
			'type': 'number',
			'min': String(MIN_ROWS),
			'max': String(MAX_ROWS),
			'value': String(rows),
			'class': 'cbi-input-text'
		});

		var colsInput = E('input', {
			'id': 'vumeters-cols',
			'type': 'number',
			'min': String(MIN_COLS),
			'max': String(MAX_COLS),
			'value': String(cols),
			'class': 'cbi-input-text'
		});

		var demoInput = E('input', {
			'id': 'vumeters-demo',
			'type': 'checkbox',
			'checked': randomDemo ? 'checked' : null
		});

		var status = E('div', { 'id': 'vumeters-status' }, [
			randomDemo
				? _('Random demo values are enabled. Disable them to drive values externally.')
				: _('Random demo values are disabled. Use window.setVuChannelValue(channel, value) to drive meters.')
		]);

		var tbody = E('tbody');

		var table = E('table', { 'class': 'vumeters-grid' }, [
			tbody
		]);

		function stopMeters() {
			if (rafHandle !== null) {
				window.cancelAnimationFrame(rafHandle);
				rafHandle = null;
			}

			if (demoTimer !== null) {
				window.clearInterval(demoTimer);
				demoTimer = null;
			}

			channelStates = [];
		}

		function setChannelValue(channel, value) {
			var state = channelStates[channel - 1];

			if (state)
				state.target = clampMeterValue(value);
		}

		function setAllChannelValues(values) {
			if (!values)
				return;

			for (var i = 0; i < values.length; i++)
				setChannelValue(i + 1, values[i]);
		}

		function tick(now) {
			rafHandle = window.requestAnimationFrame(tick);

			if (document.hidden)
				return;

			if (now - lastFrameTime < frameBudgetMs)
				return;

			lastFrameTime = now;

			if (!document.body.contains(gridRoot)) {
				stopMeters();
				return;
			}

			for (var i = 0; i < channelStates.length; i++) {
				var st = channelStates[i];
				var target = st.target;
				var cur = st.curVal;
				var changed = false;

				if (cur !== target) {
					cur += (target - cur) / EASE_DIVISOR;

					if (Math.abs(target - cur) < SETTLE_EPSILON)
						cur = target;

					changed = true;
				}

				if (JITTER_AMOUNT > 0 && cur > 0.5) {
					var amount = (Math.random() * 2 - 1) * JITTER_AMOUNT * 100;

					cur += amount;

					if (cur < 0)
						cur = 0;
					else if (cur > 100)
						cur = 100;

					changed = true;
				}

				st.curVal = cur;

				// Skip the redraw entirely for channels that are silent and
				// already painted blank - this is what keeps idle channels
				// from costing anything once a large grid settles down.
				if (changed || !st.drawnIdle) {
					drawMeter(geom, st, glowEnabled);
					st.drawnIdle = (cur === 0 && target === 0);
				}
			}
		}

		function startMeters(canvases, demoEnabled, root) {
			stopMeters();

			gridRoot = root;

			if (canvases.length === 0)
				return;

			geom = buildGeometry(canvases[0].width, canvases[0].height);

			var totalChannels = canvases.length;
			glowEnabled = totalChannels <= PEAK_GLOW_MAX_CHANNELS;
			frameBudgetMs = 1000 / (totalChannels > BIG_GRID_CHANNEL_THRESHOLD ? FPS_BIG_GRID : FPS_SMALL_GRID);

			channelStates = new Array(totalChannels);

			for (var i = 0; i < canvases.length; i++) {
				var ctx = canvases[i].getContext('2d');

				ctx.fillStyle = BG_COLOR;
				ctx.fillRect(0, 0, geom.width, geom.height);

				channelStates[i] = {
					ctx: ctx,
					curVal: 0,
					target: 0,
					drawnIdle: true
				};
			}

			window.setVuChannelValue = setChannelValue;
			window.setVuChannelValues = setAllChannelValues;

			lastFrameTime = 0;
			rafHandle = window.requestAnimationFrame(tick);

			if (demoEnabled) {
				demoTimer = window.setInterval(function() {
					if (!document.body.contains(root)) {
						stopMeters();
						return;
					}

					for (var i = 0; i < channelStates.length; i++)
						channelStates[i].target = Math.floor(Math.random() * 101);
				}, 250);
			}
		}

		function renderGrid(r, c, demoEnabled, root) {
			var channel = 1;
			var canvases = [];

			stopMeters();

			while (tbody.firstChild)
				tbody.removeChild(tbody.firstChild);

			var canvasWidth = Math.max(90, Math.floor(720 / c));
			var canvasHeight = Math.max(140, Math.floor(720 / r));

			for (var row = 0; row < r; row++) {
				var tr = E('tr');

				for (var col = 0; col < c; col++) {
					var canvas = E('canvas', {
						'class': 'vumeter-canvas',
						'width': String(canvasWidth),
						'height': String(canvasHeight),
						'data-channel': String(channel)
					});

					canvases.push(canvas);

					tr.appendChild(E('td', {
						'style': 'width:' + (100 / c) + '%;height:' + (100 / r) + '%'
					}, [
						E('div', { 'class': 'vumeter-cell' }, [
							canvas,
							E('div', { 'class': 'vumeter-caption' }, [
								'channel ' + channel
							])
						])
					]));

					channel++;
				}

				tbody.appendChild(tr);
			}

			window.setTimeout(function() {
				startMeters(canvases, demoEnabled, root);
			}, 0);
		}

		function saveAndRedraw(root) {
			var r = clampInt(rowsInput.value, MIN_ROWS, MAX_ROWS, rows);
			var c = clampInt(colsInput.value, MIN_COLS, MAX_COLS, cols);
			var demoEnabled = !!demoInput.checked;

			rowsInput.value = String(r);
			colsInput.value = String(c);

			status.textContent = _('Saving layout...');
			status.className = '';

			if (!uci.get(CONF, SECTION))
				uci.add(CONF, 'grid', SECTION);

			uci.set(CONF, SECTION, 'rows', String(r));
			uci.set(CONF, SECTION, 'cols', String(c));
			uci.set(CONF, SECTION, 'random_demo', demoEnabled ? '1' : '0');

			uci.save().then(function() {
				return uci.apply(10);
			}).then(function() {
				rows = r;
				cols = c;
				randomDemo = demoEnabled;
				renderGrid(rows, cols, randomDemo, root);
				status.textContent = _('Saved. Table layout redrawn.');
				status.className = 'alert-message notice';
			}, function(err) {
				renderGrid(r, c, demoEnabled, root);
				status.textContent = _('Table redrawn, but saving failed: ') + err;
				status.className = 'alert-message error';
			});
		}

		var root = E('div', { 'id': 'vumeters-root', 'class': 'cbi-map' }, [
			E('h2', {}, [ _('VU Meters') ]),
			E('div', { 'class': 'cbi-map-descr' }, [
				_('Configurable grid of canvas VU meters. Each cell shows one channel label.')
			]),
			E('div', { 'id': 'vumeters-controls' }, [
				E('label', {}, [
					E('span', {}, [ _('Rows') ]),
					rowsInput
				]),
				E('label', {}, [
					E('span', {}, [ _('Columns') ]),
					colsInput
				]),
				E('label', { 'class': 'inline-check' }, [
					demoInput,
					E('span', {}, [ _('Random demo values') ])
				]),
				E('button', {
					'class': 'btn cbi-button cbi-button-save',
					'click': function() {
						saveAndRedraw(root);
					}
				}, [ _('Save / redraw') ])
			]),
			status,
			E('div', { 'id': 'vumeters-grid-wrap' }, [
				table
			])
		]);

		renderGrid(rows, cols, randomDemo, root);

		return root;
	}
});

EOF

chmod 0644 "$VIEW_FILE" "$MENU_FILE" "$ACL_FILE"

rm -f /tmp/luci-indexcache 2>/dev/null || true
rm -f /tmp/luci-modulecache/* 2>/dev/null || true

if [ -x /etc/init.d/rpcd ]; then
	/etc/init.d/rpcd restart >/dev/null 2>&1 || true
fi

if [ -x /etc/init.d/uhttpd ]; then
	/etc/init.d/uhttpd reload >/dev/null 2>&1 || /etc/init.d/uhttpd restart >/dev/null 2>&1 || true
fi

echo "Installed LuCI VU Meters page."
echo "Open: LuCI -> Status -> VU Meters"
echo "Initial layout: ${ROWS}x${COLS}; random demo values: ${DEMO}"
