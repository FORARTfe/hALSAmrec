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

uci -q batch <<EOF
set ${UCI_CONF}.${UCI_SECTION}=grid
set ${UCI_CONF}.${UCI_SECTION}.rows='${ROWS}'
set ${UCI_CONF}.${UCI_SECTION}.cols='${COLS}'
set ${UCI_CONF}.${UCI_SECTION}.random_demo='${DEMO}'
commit ${UCI_CONF}
EOF

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

function createVuMeter(elem, config) {
	config = config || {};

	var max = config.max || 100;
	var boxCount = config.boxCount || 16;
	var boxCountRed = config.boxCountRed || 3;
	var boxCountYellow = config.boxCountYellow || 4;
	var boxGapFraction = config.boxGapFraction || 0.2;
	var jitter = config.jitter || 0.01;

	var redOn = 'rgba(255,47,30,0.9)';
	var redOff = 'rgba(64,12,8,0.9)';
	var yellowOn = 'rgba(255,215,5,0.9)';
	var yellowOff = 'rgba(64,53,0,0.9)';
	var greenOn = 'rgba(53,255,30,0.9)';
	var greenOff = 'rgba(13,64,8,0.9)';

	var width = elem.width;
	var height = elem.height;
	var curVal = 0;
	var boxHeight;
	var boxGapY;
	var boxWidth;
	var boxGapX;
	var ctx = elem.getContext('2d');
	var running = true;
	var raf = null;

	function recalc() {
		width = elem.width;
		height = elem.height;
		boxHeight = height / (boxCount + (boxCount + 1) * boxGapFraction);
		boxGapY = boxHeight * boxGapFraction;
		boxWidth = width - (boxGapY * 2);
		boxGapX = (width - boxWidth) / 2;
	}

	function getId(index) {
		return Math.abs(index - (boxCount - 1)) + 1;
	}

	function isOn(id, val) {
		var maxOn = Math.ceil((val / max) * boxCount);
		return id <= maxOn;
	}

	function getBoxColor(id, val) {
		if (id > boxCount - boxCountRed)
			return isOn(id, val) ? redOn : redOff;

		if (id > boxCount - boxCountRed - boxCountYellow)
			return isOn(id, val) ? yellowOn : yellowOff;

		return isOn(id, val) ? greenOn : greenOff;
	}

	function drawBoxes(val) {
		ctx.save();
		ctx.translate(boxGapX, boxGapY);

		for (var i = 0; i < boxCount; i++) {
			var id = getId(i);

			ctx.beginPath();

			if (isOn(id, val)) {
				ctx.shadowBlur = 10;
				ctx.shadowColor = getBoxColor(id, val);
			} else {
				ctx.shadowBlur = 0;
			}

			ctx.rect(0, 0, boxWidth, boxHeight);
			ctx.fillStyle = getBoxColor(id, val);
			ctx.fill();
			ctx.translate(0, boxHeight + boxGapY);
		}

		ctx.restore();
	}

	function draw() {
		if (!running)
			return;

		if (!document.body.contains(elem)) {
			running = false;
			return;
		}

		var targetVal = clampMeterValue(elem.dataset.val || 0);

		if (curVal <= targetVal)
			curVal += (targetVal - curVal) / 5;
		else
			curVal -= (curVal - targetVal) / 5;

		if (jitter > 0 && curVal > 0) {
			var amount = Math.random() * jitter * max;

			if (Math.random() > 0.5)
				amount = -amount;

			curVal += amount;
		}

		if (curVal < 0)
			curVal = 0;

		if (curVal > max)
			curVal = max;

		ctx.save();
		ctx.beginPath();
		ctx.rect(0, 0, width, height);
		ctx.fillStyle = 'rgb(32,32,32)';
		ctx.fill();
		ctx.restore();

		drawBoxes(curVal);

		raf = window.requestAnimationFrame(draw);
	}

	recalc();
	draw();

	return {
		stop: function() {
			running = false;

			if (raf !== null)
				window.cancelAnimationFrame(raf);
		}
	};
}

return view.extend({
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	load: function() {
		return uci.load(CONF);
	},

	render: function() {
		injectStyle();

		var meters = [];
		var demoTimer = null;

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
			for (var i = 0; i < meters.length; i++)
				meters[i].stop();

			meters = [];

			if (demoTimer !== null) {
				window.clearInterval(demoTimer);
				demoTimer = null;
			}
		}

		function setChannelValue(channel, value) {
			var canvas = document.querySelector('.vumeter-canvas[data-channel="' + channel + '"]');

			if (canvas)
				canvas.dataset.val = String(clampMeterValue(value));
		}

		function setAllChannelValues(values) {
			if (!values)
				return;

			for (var i = 0; i < values.length; i++)
				setChannelValue(i + 1, values[i]);
		}

		function startMeters(canvases, demoEnabled, root) {
			stopMeters();

			for (var i = 0; i < canvases.length; i++) {
				meters.push(createVuMeter(canvases[i], {
					max: 100,
					boxCount: 16,
					boxCountRed: 3,
					boxCountYellow: 4,
					boxGapFraction: 0.2,
					jitter: 0.01
				}));
			}

			window.setVuChannelValue = setChannelValue;
			window.setVuChannelValues = setAllChannelValues;

			if (demoEnabled) {
				demoTimer = window.setInterval(function() {
					if (!document.body.contains(root)) {
						stopMeters();
						return;
					}

					for (var i = 0; i < canvases.length; i++)
						canvases[i].dataset.val = String(Math.floor(Math.random() * 101));
				}, 250);
			}
		}

		function renderGrid(r, c, demoEnabled, root) {
			var channel = 1;
			var canvases = [];

			stopMeters();

			while (tbody.firstChild)
				tbody.removeChild(tbody.firstChild);

			for (var row = 0; row < r; row++) {
				var tr = E('tr');

				for (var col = 0; col < c; col++) {
					var canvas = E('canvas', {
						'class': 'vumeter-canvas',
						'width': String(Math.max(90, Math.floor(720 / c))),
						'height': String(Math.max(140, Math.floor(720 / r))),
						'data-channel': String(channel),
						'data-val': '0'
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
