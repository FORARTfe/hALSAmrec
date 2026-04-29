'use strict';
'require view';
'require rpc';

/*
 * Status → Audio Inputs
 *
 * Service lifecycle is USER-controlled only:
 *   1. User clicks Stop  → recorder stops
 *   2. User clicks Probe → alsa-inputs-json runs (backend refuses with 409
 *                          if recorder is still running)
 *   3. User clicks Start → recorder restarts
 *
 * No automatic stop/start is ever performed by this view.
 */

var callExec = rpc.declare({
	object: 'file',
	method: 'exec',
	params: ['command'],
	expect: { stdout: '' }
});

return view.extend({

	/* ── render ──────────────────────────────────────────────────────── */
	render: function () {
		var self = this;

		self._statusEl = E('span',  { id: 'ai-svc-status' }, [ _('Loading…') ]);
		self._btnStop  = E('button', {
			disabled: true,
			click: function () { self._svcAction('stop'); }
		}, [ _('Stop') ]);
		self._btnStart = E('button', {
			disabled: true,
			click: function () { self._svcAction('start'); }
		}, [ _('Start') ]);
		self._btnProbe = E('button', {
			disabled: true,
			click: function () { self._runProbe(); }
		}, [ _('Probe Devices') ]);
		self._probeMsg = E('span', { style: 'margin-left:1em' });
		self._tbody    = E('tbody', {}, [
			E('tr', { class: 'tr placeholder' }, [
				E('td', { class: 'td', colspan: '6' }, [ '—' ])
			])
		]);

		var container = E('div', { class: 'cbi-map' }, [
			E('h2', {}, [ _('Audio Inputs') ]),
			E('p', { class: 'cbi-map-descr' }, [
				_('Stop the recorder first, then click Probe Devices. Start the recorder again when done.')
			]),

			/* Service status bar */
			E('div', { style: 'margin-bottom:1em' }, [
				E('strong', {}, [ _('Recorder: ') ]),
				self._statusEl,
				' ',
				self._btnStop,
				' ',
				self._btnStart
			]),

			/* Device table */
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
					self._tbody
				])
			]),

			/* Probe row */
			E('div', { style: 'margin-top:1em' }, [
				self._btnProbe,
				self._probeMsg
			]),

			E('p', { class: 'cbi-map-descr', style: 'margin-top:1em' }, [
				_('Source: '), E('code', {}, [ 'arecord -l' ]),
				' / ', E('code', {}, [ '/proc/asound' ]), '.'
			])
		]);

		/* Fetch initial service status — no polling, user drives the flow */
		self._fetchStatus();

		return container;
	},

	/* ── service status ──────────────────────────────────────────────── */
	_fetchStatus: function () {
		var self = this;
		return callExec('/etc/init.d/autorecorder status').then(function (out) {
			var running = /running/.test(out) && !/not running/.test(out);
			self._applyStatus(running ? 'running' : 'stopped');
		}).catch(function () {
			self._applyStatus('unknown');
		});
	},

	_applyStatus: function (st) {
		var self = this;
		self._statusEl.textContent =
			st.charAt(0).toUpperCase() + st.slice(1);
		self._statusEl.style.color =
			st === 'running' ? 'var(--success-color,#080)'
			: st === 'stopped' ? 'var(--error-color,#c00)'
			: '#888';
		self._btnStop.disabled  = (st !== 'running');
		self._btnStart.disabled = (st !== 'stopped');
		/* Probe available only when recorder is confirmed stopped */
		self._btnProbe.disabled = (st !== 'stopped');
	},

	/* ── stop / start (user-initiated only) ─────────────────────────── */
	_svcAction: function (action) {
		var self = this;
		self._btnStop.disabled = self._btnStart.disabled =
			self._btnProbe.disabled = true;
		self._statusEl.textContent = _('Working…');
		return callExec('/etc/init.d/autorecorder ' + action)
			.then(function () { return self._fetchStatus(); })
			.catch(function () { self._applyStatus('unknown'); });
	},

	/* ── probe (user-initiated only) ─────────────────────────────────── */
	// Calls alsa-inputs-json directly via rpcd.
	// Does NOT stop or start the recorder — if the recorder is still running
	// the probe will fail (alsa device busy) and we surface the error.
	_runProbe: function () {
		var self = this;
		self._btnProbe.disabled = true;
		self._probeMsg.textContent = _('Probing…');

		return callExec('/usr/libexec/alsa-inputs-json')
			.then(function (stdout) {
				var devices;
				try { devices = JSON.parse(stdout || '[]'); }
				catch (e) { devices = []; }

				if (!Array.isArray(devices)) {
					/* {"error":"..."} from the shell script */
					self._probeMsg.textContent =
						_('Error: ') + (devices.error || _('unexpected response'));
					self._btnProbe.disabled = false;
					return;
				}

				self._renderTable(devices);
				self._probeMsg.textContent = _('Done.');
				self._btnProbe.disabled = false;
			})
			.catch(function (err) {
				self._probeMsg.textContent =
					_('Probe failed: ') + (err.message || String(err));
				self._btnProbe.disabled = false;
			});
	},

	/* ── table rendering ─────────────────────────────────────────────── */
	_renderTable: function (devices) {
		var self = this;
		if (!devices.length) {
			self._tbody.replaceChildren(E('tr', { class: 'tr placeholder' }, [
				E('td', { class: 'td', colspan: '6' }, [ _('No ALSA capture devices found.') ])
			]));
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
		self._tbody.replaceChildren.apply(self._tbody, rows);
	},

	/* Disable default LuCI save/reset buttons */
	handleSaveApply: null,
	handleSave:      null,
	handleReset:     null
});
