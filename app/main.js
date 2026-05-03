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

// ── View ──────────────────────────────────────────────────────────────────────

return view.extend({

    load: function () {
        return callStatus();
    },

    render: function (status) {
        var self = this;

        // ── Status row ────────────────────────────────────────────────────────
        var statusCell = E('td', { 'class': 'td left' },
            [self._badge(status)]);

        // ── Control buttons ───────────────────────────────────────────────────
        var btnStart = E('button', {
            'class': 'btn cbi-button cbi-button-apply',
            'id':    'ar-btn-start',
            'click': function () { self._doStart(); }
        }, _('Start'));

        var btnStop = E('button', {
            'class': 'btn cbi-button cbi-button-negative',
            'id':    'ar-btn-stop',
            'click': function () { self._doStop(); }
        }, _('Stop'));

        // ── Probe section ─────────────────────────────────────────────────────
        var btnProbe = E('button', {
            'class': 'btn cbi-button cbi-button-action',
            'id':    'ar-btn-probe',
            'click': function () { self._doProbe(); }
        }, _('Probe Hardware'));

        var probeOutput = E('pre', {
            'id':    'ar-probe-output',
            'style': 'display:none;margin-top:0.75em;padding:8px 10px;' +
                     'background:#f4f4f4;border:1px solid #ddd;border-radius:3px;' +
                     'font-size:0.82em;white-space:pre-wrap;word-break:break-all;' +
                     'max-height:320px;overflow-y:auto'
        });

        // ── Page assembly ─────────────────────────────────────────────────────
        var page = E('div', { 'class': 'cbi-map' }, [

            E('h2', _('ALSA Recorder')),

            // Status + controls
            E('div', { 'class': 'cbi-section' }, [
                E('div', { 'class': 'cbi-section-descr' },
                    _('Manage the autorecorder service. Status refreshes every 5 seconds.')),

                E('table', { 'class': 'table cbi-section-table' }, [
                    E('tr', { 'class': 'tr cbi-rowstyle-1' }, [
                        E('td', { 'class': 'td left', 'style': 'width:160px;font-weight:bold' },
                            _('Service Status')),
                        statusCell
                    ])
                ]),

                E('div', { 'style': 'margin-top:1em;display:flex;gap:6px;flex-wrap:wrap' }, [
                    btnStart, btnStop
                ])
            ]),

            // Hardware probe
            E('div', { 'class': 'cbi-section' }, [
                E('h3', _('Hardware Probe')),
                E('div', { 'class': 'cbi-section-descr' },
                    _('Query raw ALSA hardware parameters from hw:0,0. ' +
                      'The recorder must be stopped first.')),
                btnProbe,
                probeOutput
            ])
        ]);

        // ── Status poll ───────────────────────────────────────────────────────
        poll.add(function () {
            return callStatus().then(function (s) {
                var cell = document.getElementById('ar-status-badge');
                if (cell)
                    dom.content(cell, self._badge(s).childNodes);
            });
        }, 5);

        return page;
    },

    // ── Badge helper ──────────────────────────────────────────────────────────

    _badge: function (status) {
        var running = status && status.running;
        var label   = running
            ? ('● ' + _('Running') + ' (PID:\u00a0' + status.pid + ')')
            : ('● ' + _('Stopped'));
        return E('span', {
            'id':    'ar-status-badge',
            'style': running ? 'color:#28a745;font-weight:bold'
                             : 'color:#dc3545;font-weight:bold'
        }, label);
    },

    // ── Button state helpers ──────────────────────────────────────────────────

    _setBusy: function (busy) {
        ['ar-btn-start', 'ar-btn-stop', 'ar-btn-probe'].forEach(function (id) {
            var el = document.getElementById(id);
            if (el) el.disabled = busy;
        });
    },

    // ── Action handlers ───────────────────────────────────────────────────────

    _doStart: function () {
        var self = this;
        self._setBusy(true);
        return callStart().then(function () {
            // poll will pick up the new status within 5 s
        }).catch(function (err) {
            window.alert(_('RPC error: ') + (err.message || String(err)));
        }).then(function () {
            self._setBusy(false);
        });
    },

    _doStop: function () {
        var self = this;
        self._setBusy(true);
        return callStop().then(function () {
            // poll will pick up the new status within 5 s
        }).catch(function (err) {
            window.alert(_('RPC error: ') + (err.message || String(err)));
        }).then(function () {
            self._setBusy(false);
        });
    },

    _doProbe: function () {
        var self = this;
        var pre  = document.getElementById('ar-probe-output');
        if (!pre) return;

        pre.style.display = 'block';
        pre.textContent   = _('Querying hardware…');
        self._setBusy(true);

        return callProbe().then(function (res) {
            if (res.error === 'recorder_running') {
                pre.textContent = _('Cannot probe: recorder is running. Stop it first.');
            } else {
                pre.textContent = res.output || _('(no output)');
            }
        }).catch(function (err) {
            pre.textContent = _('RPC error: ') + (err.message || String(err));
        }).then(function () {
            self._setBusy(false);
        });
    },

    // Suppress default LuCI save/apply/reset footer buttons —
    // this view has no UCI config to save.
    handleSaveApply: null,
    handleSave:      null,
    handleReset:     null
});
