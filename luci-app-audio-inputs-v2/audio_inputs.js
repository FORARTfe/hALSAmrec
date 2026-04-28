'use strict';
'require view';
'require poll';
'require rpc';
'require ui';

/*
 * Status → Audio Inputs
 * Live table of ALSA capture devices.
 * Polls alsa-inputs-json via rpcd every 1.5 s.
 *
 * Requires rpcd-mod-rpcsys OR rpcd file-exec ACL grant for
 * /usr/libexec/alsa-inputs-json.  Install rpcd-mod-rpcsys if absent:
 *   opkg install rpcd-mod-rpcsys
 */

var callExec = rpc.declare({
	object: 'file',
	method: 'exec',
	params: ['command'],
	expect: { stdout: '' }
});

return view.extend({

	/* ── initial render ──────────────────────────────────────────────── */
	render: function () {
		var self = this;

		/* Outer container — poll will replace #audio-inputs-tbody */
		var container = E('div', { class: 'cbi-map' }, [
			E('h2', {}, [ _('Audio Inputs') ]),
			E('p', { class: 'cbi-map-descr' },
				_('Live list of ALSA capture devices. Refreshes every 1.5 seconds.')),
			E('div', { class: 'table-wrapper' }, [
				E('table', { class: 'table cbi-section-table' }, [
					E('thead', {}, [
						E('tr', { class: 'tr table-titles' }, [
							E('th', { class: 'th' }, [ _('Card')        ]),
							E('th', { class: 'th' }, [ _('Dev')         ]),
							E('th', { class: 'th' }, [ _('Card Name')   ]),
							E('th', { class: 'th' }, [ _('Stream Name') ]),
							E('th', { class: 'th' }, [ _('HW ID')       ]),
							E('th', { class: 'th' }, [ _('Capture')     ])
						])
					]),
					E('tbody', { id: 'audio-inputs-tbody' }, [
						self._loadingRow()
					])
				])
			]),
			E('p', { class: 'cbi-map-descr', style: 'margin-top:1em' }, [
				_('Source: '),
				E('code', {}, [ 'arecord -l' ]),
				' / ',
				E('code', {}, [ '/proc/asound' ]),
				'. ',
				_('Plug in a USB audio device and it will appear within 2 seconds.')
			])
		]);

		/* Start 1500 ms poll */
		poll.add(function () { return self._refresh(); }, 1.5);

		return container;
	},

	/* ── poll callback ───────────────────────────────────────────────── */
	_refresh: function () {
		var self = this;
		return callExec('/usr/libexec/alsa-inputs-json').then(function (stdout) {
			var tbody = document.getElementById('audio-inputs-tbody');
			if (!tbody) return;

			var devices;
			try { devices = JSON.parse(stdout || '[]'); }
			catch (e) { devices = []; }

			/* Handle {"error":"..."} sentinel from the shell script */
			if (!Array.isArray(devices)) {
				tbody.replaceChildren(self._errorRow(
					devices.error || _('Unexpected response from alsa-inputs-json')));
				return;
			}

			if (devices.length === 0) {
				tbody.replaceChildren(self._emptyRow());
				return;
			}

			var rows = devices.map(function (d) {
				return E('tr', { class: 'tr' }, [
					E('td', { class: 'td', 'data-title': _('Card')        }, [ String(d.card        ?? '') ]),
					E('td', { class: 'td', 'data-title': _('Dev')         }, [ String(d.device      ?? '') ]),
					E('td', { class: 'td', 'data-title': _('Card Name')   }, [ String(d.card_name   ?? '') ]),
					E('td', { class: 'td', 'data-title': _('Stream Name') }, [ String(d.name        ?? '') ]),
					E('td', { class: 'td', 'data-title': _('HW ID')       }, [
						E('code', {}, [ String(d.hw_id ?? '') ])
					]),
					E('td', { class: 'td', 'data-title': _('Capture')     }, [
						d.capture
							? E('span', { class: 'label-status label-success' }, [ _('yes') ])
							: E('span', { class: 'label-status label-warning' }, [ _('no')  ])
					])
				]);
			});

			tbody.replaceChildren.apply(tbody, rows);
		}).catch(function (err) {
			var tbody = document.getElementById('audio-inputs-tbody');
			if (tbody) tbody.replaceChildren(self._errorRow(err.message || String(err)));
		});
	},

	/* ── helper rows ─────────────────────────────────────────────────── */
	_loadingRow: function () {
		return E('tr', { class: 'tr placeholder' }, [
			E('td', { class: 'td', colspan: '6' }, [ _('Loading\u2026') ])
		]);
	},

	_emptyRow: function () {
		return E('tr', { class: 'tr placeholder' }, [
			E('td', { class: 'td', colspan: '6' }, [
				_('No ALSA capture devices found.')
			])
		]);
	},

	_errorRow: function (msg) {
		return E('tr', { class: 'tr placeholder' }, [
			E('td', { class: 'td', colspan: '6' }, [
				E('em', { style: 'color:var(--error-color,#c00)' }, [
					_('Error: ') + msg
				])
			])
		]);
	},

	/* Disable the default LuCI save/reset buttons */
	handleSaveApply: null,
	handleSave:      null,
	handleReset:     null
});
