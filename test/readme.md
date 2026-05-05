# hALSAmrec CGI → LuCI Migration: Forensic Parity Analysis

> Source: CGI/bash v2/v3 (`controlweb_cgi`, `hotplug`, `initscript`, `recorder`)  
> Target: LuCI v4 installer (`luciv4.sh`)  
> Analyst methodology: exhaustive reverse-engineering + architecture reconstruction  

---

## Executive Summary

The LuCI v4 port is **architecturally sound** and represents a genuine improvement over the
CGI v2/v3 baseline in several dimensions: it adds UCI persistence for hardware parameters, a
proper rpcd abstraction layer, a full LuCI JS view, and an improved exFAT detection strategy.
However, it introduces **five functional regressions** and **three security/reliability gaps**
that must be remediated before the port can be considered operationally equivalent.

The most critical regression is the **missing USB hotplug handler**. The original installer
deploys the hotplug script to both `/etc/hotplug.d/block/` and `/etc/hotplug.d/usb/`; the v4
installer only deploys to `block/`. This silently breaks the core use-case: plugging in a USB
audio interface does not trigger a recorder re-evaluation.

The second critical regression is **silent failure reporting** for START/STOP operations. The
CGI returned deterministic text (`Failed to start`, `Stopped successfully`). The LuCI JS
discards the `result` field from the rpcd response entirely, so the user receives no actionable
feedback when a service control action fails.

The remaining deficiencies are mid-priority parity breaks: the PROBE command behavioral change
(CGI hardcodes `hw:0,0`; rpcd uses UCI-configured card), a missing poll error guard that silently
freezes the status display on transient rpcd failures, and the complete removal of the
`/cgi-bin/cm` HTTP endpoint which breaks any external integrations.

---

## Runtime Architecture Reconstruction

### CGI v2/v3 System

```
 ┌─────────────────────────────────────────────────┐
 │  HTTP client (browser / curl / external script) │
 └───────────────┬─────────────────────────────────┘
                 │  GET /cgi-bin/cm?cmnd=X
                 ▼
 ┌───────────────────────────────────┐
 │  uhttpd (OpenWrt web server)      │
 │  CGI exec: /www/cgi-bin/cm        │
 │  Env: QUERY_STRING, REQUEST_METHOD│
 └───────────────┬───────────────────┘
                 │
                 ▼
 ┌────────────────────────────────────────────────────────────┐
 │  controlweb_cgi (/www/cgi-bin/cm)                          │
 │   ├── GET check (exits 1 on non-GET)                       │
 │   ├── QUERY_STRING parse → CMND                            │
 │   └── case CMND in                                         │
 │        START  → /etc/init.d/autorecorder start; sleep 2    │
 │        STOP   → /etc/init.d/autorecorder stop;  sleep 2    │
 │        STATUS → pgrep -f /usr/sbin/recorder → PID          │
 │        PROBE  → arecord -D hw:0,0 --dump-hw-params         │
 └─────────────┬──────────────────────────────────────────────┘
               │
               ▼
 ┌──────────────────────────────────────────────────────────┐
 │  /etc/init.d/autorecorder (rc.common + procd)            │
 │   START=99 / STOP=1 / USE_PROCD=1                        │
 │   procd_set_param reload_signal SIGHUP                   │
 │   reload_service → procd_send_signal (SIGHUP to recorder)│
 └───────────────┬──────────────────────────────────────────┘
                 │  procd manages
                 ▼
 ┌──────────────────────────────────────────────────────────┐
 │  /usr/sbin/recorder (v3)                                 │
 │   ├── trap SIGHUP 'true'    ← wakes wait, re-evaluates   │
 │   ├── trap SIGTERM → kill arecord, umount, exit          │
 │   ├── sentinel: sleep infinity & $dummy                  │
 │   └── loop:                                              │
 │        ├── wait ${recorder:-$dummy}                      │
 │        ├── scan /proc/partitions → dd|grep EXFAT         │
 │        ├── arecord -l | grep '^card' → card/dev          │
 │        ├── /proc/$recorder stale PID check               │
 │        ├── disk+card readiness gate                      │
 │        ├── mount $disk $MNT                              │
 │        ├── df -k space check (>100MB)                    │
 │        ├── arecord --dump-hw-params → parse params       │
 │        └── arecord > $MNT/$(date +%s)_ch-rate-fmt.raw & │
 └──────────────────────────────────────────────────────────┘

 Hotplug triggers (BOTH fire on USB events):
 /etc/hotplug.d/block/autorecorder → service autorecorder reload (→ SIGHUP)
 /etc/hotplug.d/usb/autorecorder  → service autorecorder reload (→ SIGHUP)
```

### LuCI v4 System

```
 ┌───────────────────────────────────────────────────┐
 │  LuCI Browser Session (authenticated)             │
 └──────────────┬────────────────────────────────────┘
                │  XHR RPC /ubus (session token)
                ▼
 ┌──────────────────────────────────────────────────┐
 │  rpcd + ubus bridge                              │
 │   → exec /usr/libexec/rpcd/autorecorder          │
 └──────────────┬───────────────────────────────────┘
                │  $1=call $2=method; params via stdin
                ▼
 ┌─────────────────────────────────────────────────────────────────┐
 │  /usr/libexec/rpcd/autorecorder (shell plugin)                  │
 │   methods: status start stop probe disk_status get_config       │
 │            set_config                                           │
 └────────────┬──────────────────────────────────────────────────-─┘
              │
              ▼
 ┌──────────────────────────────────────────────────────────────┐
 │  /usr/sbin/recorder (v4) — UCI-aware                         │
 │   ├── uci_get mount / card / device                          │
 │   ├── blkid primary disk detection, dd fallback              │
 │   └── auto-persist detected card/device to UCI               │
 └──────────────────────────────────────────────────────────────┘

 Hotplug triggers (ONLY block, USB missing):
 /etc/hotplug.d/block/50-autorecorder → service autorecorder reload
 ← /etc/hotplug.d/usb/ directory: NOTHING INSTALLED
```

---

## Functional Flow Analysis

### CGI START Flow

1. `GET /cgi-bin/cm?cmnd=START` arrives at uhttpd
2. uhttpd executes `/www/cgi-bin/cm` as CGI, sets `REQUEST_METHOD=GET`, `QUERY_STRING=cmnd=START`
3. Script prints `Content-type: text/plain\n\n`
4. Method check passes
5. QUERY_STRING parsing: `tmp="${QUERY_STRING##*cmnd=}"` → `"START"`, `CMND="${tmp%%&*}"` → `"START"`
   - **Note:** `##*cmnd=` is a greedy left-strip. If QUERY_STRING is `foo=1&cmnd=START&bar=2`,
     `tmp` = `"START&bar=2"`, `CMND` = `"START"`. Works correctly.
   - **Edge case:** If QUERY_STRING is `cmnd=STOP&cmnd=START`, `##*cmnd=` strips to `"START"` (last match).
6. `is_running` → `pgrep -f /usr/sbin/recorder` → exit 0 if found
7. If not running: `$INIT start >/dev/null 2>&1` (procd starts recorder), `sleep 2`
8. Re-check: if running → `"Started successfully"`, else `"Failed to start"`
9. uhttpd closes connection; response body is the text message

### LuCI START Flow (v4)

1. Browser calls `callStart()` → XHR POST to `/ubus`
2. Request body: `{"method":"call","params":["<session>","autorecorder","start",{}]}`
3. rpcd authenticates session via ubus RPC session
4. rpcd executes `/usr/libexec/rpcd/autorecorder call start`
5. Plugin: `is_running` → `pgrep -f /usr/sbin/recorder`
6. If not running: `"$INIT" start >/dev/null 2>&1`, `sleep 2`, re-check
7. Returns `{"result":"started"}` or `{"result":"failed"}`
8. rpcd wraps in `{"id":..,"result":[0,{...}]}` to browser
9. `callStart().then(function(res) {...})` runs with `res = {result: "started"}`
10. **BUG:** `_doStart` handler calls `.then(function() { self._setBusy(false); })` — the
    resolved value (including `res.result`) is never inspected or displayed to the user.

### CGI PROBE Flow

1. `GET /cgi-bin/cm?cmnd=PROBE`
2. If running: `"WARNING: recorder is running, stop to probe!"`
3. If not running: `arecord -D "hw:0,0" --dump-hw-params 2>&1`
   - **ALWAYS uses `hw:0,0`** — no UCI, no config lookup
   - Output (potentially multi-line) goes directly to HTTP response body

### LuCI PROBE Flow (v4)

1. `callProbe()` → rpcd `probe` method
2. If running: `{"error":"recorder_running","output":""}`
3. If not running:
   - `card=$(uci_get card); card="${card:-0}"`
   - `dev=$(uci_get device); dev="${dev:-0}"`
   - `arecord -D "hw:${card},${dev}" --dump-hw-params 2>&1`
   - **Uses UCI card/device with fallback to 0** — different from CGI's unconditional `hw:0,0`
4. `json_str` escapes output
5. Returns `{"error":"","output":"<escaped text>"}`
6. JS displays in `<pre>` element

**Behavioral difference:** If UCI has `card=1,device=0`, LuCI probes `hw:1,0`; CGI always
probes `hw:0,0`. This is functionally an improvement but breaks parity.

### Hotplug Event Flow

#### v2/v3 (correct):
- USB storage insert → block hotplug → `service autorecorder reload` → SIGHUP to recorder
- USB audio insert → **usb hotplug** → `service autorecorder reload` → SIGHUP to recorder
- USB storage remove → block hotplug → SIGHUP → recorder loop re-evaluates → stops recording
- USB audio remove → **usb hotplug** → SIGHUP → recorder stops

#### v4 (broken):
- USB storage insert → block hotplug → `service autorecorder reload` → SIGHUP ✓
- **USB audio insert → NO hotplug fired → recorder not awakened ✗**
- USB storage remove → block hotplug → SIGHUP ✓
- **USB audio remove → NO hotplug fired → recorder may not stop cleanly ✗**

---

## Hidden / Implicit Behaviors

### H-1: QUERY_STRING greedy left-strip (controlweb_cgi)

```sh
tmp="${QUERY_STRING##*cmnd=}"   # greedy: strips up to LAST occurrence of "cmnd="
CMND="${tmp%%&*}"               # strips from first "&" onwards
```

If `QUERY_STRING=cmnd=START&cmnd=STOP`, `CMND` becomes `"STOP"` (last wins). This is not
documented anywhere. Relevant if any client sends duplicate parameters.

### H-2: SIGHUP interrupts `wait` non-destructively

```sh
trap 'true' SIGHUP
wait ${recorder:-$dummy}
```

`trap 'true' SIGHUP` installs a no-op handler. When SIGHUP arrives, the shell's `wait`
builtin is interrupted (returns 129 on some busybox builds, or just resumes). The trap body
(`true`) runs. Critically, this does **not** kill `$recorder` (the arecord subprocess). The
recorder keeps recording; only the shell loop re-evaluates hardware state. This is correct and
intentional — a hotplug event wakes the supervisor without disrupting an in-progress recording.

### H-3: `exfat_count` single-disk enforcement

```sh
[ "$exfat_count" -ne 1 ] && disk=""
```

If two or more exFAT partitions are found, `disk` is cleared and recording stops. This silently
refuses to record when multiple exFAT disks are attached. The user has no indication of this
restriction. Both v3 and v4 share this behavior.

### H-4: `arecord -l` re-runs every cycle unless recording is active

In v3, audio card detection via `arecord -l` runs unconditionally at the top of each loop
iteration. If a recording is already in progress (`$recorder` is set), the new `card_line` is
computed but never used (the `[ -n "$recorder" ] && continue` gate fires before any new arecord
starts). So the detection is wasted work when already recording, but it's harmless and keeps
card_line fresh.

In v4, if `uci_get card` returns a value, `arecord -l` is skipped entirely. This is the
optimization intent. **Hidden implication:** If the physical card changes (e.g., card is
re-numbered after USB re-enumeration) while UCI still has the old card number, the v4 recorder
will fail to record on the wrong hw: path and keep retrying. The v3 recorder would auto-correct
by re-detecting. The v4 hotplug handler (if it fired) sends SIGHUP, which would cause the loop
to re-evaluate, but the stale UCI value is still used.

### H-5: `sleep 5` after low-disk condition

```sh
if [ $(($4 / 1024)) -le 100 ]; then
    umount -l "$MNT"
    sleep 5
    continue
fi
```

On low disk, the script sleeps 5 seconds before the next loop iteration (which starts with
`wait`, which would block indefinitely without a signal). The `sleep 5` is inside the loop body
but before the loop's `wait` at the top. On the next iteration, `wait ${recorder:-$dummy}`
immediately runs — `recorder` is empty so it waits on `$dummy` (sleep infinity). Without a
hotplug event or manual SIGHUP, the recorder will stay in the low-disk idle state indefinitely.
This is correct behavior but non-obvious.

### H-6: `--buffer-time` / `--buffer-size` may be empty

If `arecord --dump-hw-params` does not print `BUFFER_TIME:` or `BUFFER_SIZE:` lines (some USB
audio devices omit them), `buf_time` and `buf_size` will be empty strings. The arecord command
then runs with `--buffer-time=` and `--buffer-size=` (empty values). On ALSA's `arecord`, an
empty `--buffer-time=` causes arecord to use its compiled default, not to error out. This is a
silent fallback in both v3 and v4.

### H-7: `df -k | tail -n 1 | set --` field indexing

```sh
set -- $(df -k "$MNT" | tail -n 1)
if [ $(($4 / 1024)) -le 100 ]; then
```

`df -k` output columns: `Filesystem 1K-blocks Used Available Use% Mounted-on`. `$4` is
`Available`. This relies on `df` producing a single-row result for the mount (no line wrapping).
If the filesystem path is very long, some `df` implementations wrap the first line, shifting
columns. On busybox's `df`, line wrapping does not occur. Both v3 and v4 are safe on OpenWrt.

### H-8: `pgrep -f /usr/sbin/recorder` false-positive risk

`pgrep -f` matches against the full command line of every process. If any process has
`/usr/sbin/recorder` as an argument (e.g., a shell running `cat /usr/sbin/recorder`), `is_running`
returns true. In practice this is extremely unlikely on a typical OpenWrt router, but it is a
latent bug. A more robust check would be `pgrep -x recorder` or using a pidfile.

### H-9: Implicit `/tmp/mnt` persistence across recorder restarts

After `$INIT stop`, procd sends SIGTERM to the recorder. The SIGTERM trap runs `umount -l "$MNT"`.
If `umount -l` fails (e.g., the mount is busy), the filesystem remains mounted. The next start
will attempt `mount "$disk" "$MNT"` which fails with "already mounted". The `|| continue` skips
the recording cycle. The recorder will be stuck until the mount is cleared manually or a hotplug
event fires. Both v3 and v4 share this behavior.

### H-10: `set -e` in v4 installer only

The v4 installer (`luciv4.sh`) uses `set -e` at the top level but the embedded scripts
(recorder, rpcd plugin, hotplug) do not. The rpcd plugin in particular never uses `set -e`,
meaning a failed `uci` call in `set_config` is silently ignored unless explicitly checked.
The `|| true` on `uci -q delete` is intentional, but other uci calls lack error handling.

### H-11: `hotplug` chmod 644 in original installer vs 755 in v4

The original `installer.sh` runs:
```sh
cp hotplug /etc/hotplug.d/block/autorecorder  && chmod 644 ...
cp hotplug /etc/hotplug.d/usb/autorecorder   && chmod 644 ...
```

OpenWrt's hotplug daemon executes scripts via `execv()` (not `source`). A script without execute
permission will fail silently (the hotplug call succeeds but the script is not run). This is
likely a bug in the original v2 installer. The v4 installer correctly uses `chmod 0755` for the
hotplug script.

### H-12: Recorder v4 auto-persist UCI commit timing

```sh
if [ "$card_ready" -eq 1 ] && [ -z "$(uci_get card)" ]; then
    uci -q set autorecorder.config=autorecorder
    uci -q set autorecorder.config.card="$card_num"
    uci -q set autorecorder.config.device="$dev_num"
    uci -q commit autorecorder
fi
```

This `uci commit` runs from a background process (the recorder, managed by procd). If the user
is simultaneously editing config via LuCI (`callSetConfig`), two concurrent `uci commit` calls
can race. UCI uses advisory locking internally, but the last writer wins. If the recorder commits
after the user's set_config commit, the recorder's auto-detected values overwrite the user's
manual settings. This is a real race condition, though its window is narrow.

---

## LuCI Port Deficiencies

### D-1 [CRITICAL]: Missing USB Hotplug Handler

**File:** `/etc/hotplug.d/usb/autorecorder` — **not created by v4 installer**

Original installer:
```sh
cp hotplug /etc/hotplug.d/block/autorecorder  && chmod 644 ...
cp hotplug /etc/hotplug.d/usb/autorecorder    && chmod 644 ...
```

v4 installer only creates:
```sh
cat > /etc/hotplug.d/block/50-autorecorder << 'EOF_HOTPLUG'
#!/bin/sh
service autorecorder reload
EOF_HOTPLUG
```

**Impact:** When a USB audio interface (e.g., USB sound card, USB microphone) is plugged in or
removed, no SIGHUP is sent to the recorder. The recorder's main loop remains blocked on `wait`.
Recording does not start until a block device event (storage) also fires. In a setup where the
USB audio card is plugged in first and storage is already present (or vice versa), the recorder
never initiates recording without manual intervention.

**Root cause:** The developer apparently reasoned that only block events matter (storage
insertion). However the original author correctly recognized that USB audio re-enumeration also
requires a wakeup — a USB audio card can be removed and re-inserted without any block device
event.

### D-2 [CRITICAL]: Start/Stop Result Not Surfaced to User

**File:** `/www/luci-static/resources/view/autorecorder/main.js`

```javascript
_doStart: function() {
    var self = this;
    self._setBusy(true);
    return callStart().catch(function(err) {
        window.alert(_('RPC error: ') + (err.message || String(err)));
    }).then(function() { self._setBusy(false); });  // ← result value discarded
},
```

The rpcd `start` method returns `{"result":"failed"}` when the recorder fails to start. The JS
`.then(function() {...})` receives the resolved value from `callStart()` (which is
`{result: "failed"}`) but ignores it entirely. The user sees the buttons re-enable with no
indication of success or failure.

**CGI behavior:** Printed `"Failed to start"` or `"Started successfully"` as HTTP response body.

**Required fix:**
```javascript
_doStart: function() {
    var self = this;
    self._setBusy(true);
    return callStart().then(function(res) {
        if (res && res.result === 'failed') {
            window.alert(_('Failed to start recorder.'));
        }
    }).catch(function(err) {
        window.alert(_('RPC error: ') + (err.message || String(err)));
    }).then(function() { self._setBusy(false); });
},
```

Same fix needed for `_doStop`.

### D-3 [HIGH]: Poll Error Handler Missing — Silent Status Freeze

**File:** `/www/luci-static/resources/view/autorecorder/main.js`

```javascript
poll.add(function() {
    return Promise.all([callStatus(), callDiskStatus()]).then(function(results) {
        var sc = document.getElementById('ar-status-cell');
        var dc = document.getElementById('ar-disk-cell');
        if (sc) dom.content(sc, self._statusBadge(results[0]));
        if (dc) dom.content(dc, self._diskInfo(results[1]));
    });   // ← no .catch()
}, 5);
```

If either `callStatus()` or `callDiskStatus()` rejects (rpcd timeout, session expiry, transient
network error), `Promise.all` rejects, the `.then` does not run, and the DOM is not updated.
LuCI's `poll` infrastructure does not stop polling on a rejected promise, so subsequent intervals
still fire. However, the status/disk display silently freezes at stale values with no user
indication.

**Required fix:**
```javascript
poll.add(function() {
    return Promise.all([
        callStatus().catch(function() { return { running: false, pid: 0 }; }),
        callDiskStatus().catch(function() { return { mounted: false, total_kb: 0, used_kb: 0, avail_kb: 0, mount: '/tmp/mnt' }; })
    ]).then(function(results) {
        var sc = document.getElementById('ar-status-cell');
        var dc = document.getElementById('ar-disk-cell');
        if (sc) dom.content(sc, self._statusBadge(results[0]));
        if (dc) dom.content(dc, self._diskInfo(results[1]));
    });
}, 5);
```

### D-4 [HIGH]: CGI HTTP Endpoint Removed — External API Broken

The original CGI provided a simple unauthenticated HTTP API:
```
http://<router>/cgi-bin/cm?cmnd=START
http://<router>/cgi-bin/cm?cmnd=STOP
http://<router>/cgi-bin/cm?cmnd=STATUS
http://<router>/cgi-bin/cm?cmnd=PROBE
```

The v4 installer does not create `/www/cgi-bin/cm`. Any external script, cron job, or monitoring
system that calls this endpoint will receive HTTP 404. If the use-case requires machine-to-machine
control (the installer's own README hints at it), this is a functional regression.

**Note:** This is an expected architectural trade-off of moving to LuCI/rpcd, but it must be
explicitly documented and mitigated (e.g., optionally preserve the CGI, or document the ubus
CLI replacement: `ubus call autorecorder start`).

### D-5 [HIGH]: PROBE Hardware Target Behavioral Difference

**CGI (v2/v3):**
```sh
PROBE) arecord -D "hw:0,0" --dump-hw-params 2>&1 ;;
```
Always probes `hw:0,0`, regardless of any configuration.

**rpcd plugin (v4):**
```sh
card=$(uci_get card); card="${card:-0}"
dev=$(uci_get device); dev="${dev:-0}"
raw=$(arecord -D "hw:${card},${dev}" --dump-hw-params 2>&1)
```
Uses UCI-configured card/device, falling back to 0,0.

**Impact:** On a system where the USB audio card is enumerated as `card 1`, the CGI probes
the wrong device (hw:0,0) while rpcd probes the correct one (hw:1,0). The v4 behavior is
functionally superior but breaks exact parity. Users migrating from CGI who relied on its
output will see different behavior. Not a regression in the technical sense, but a parity break
that should be documented.

### D-6 [MEDIUM]: `mountpoint` Busybox Availability

**File:** `/usr/libexec/rpcd/autorecorder`, `disk_status` method

```sh
if mountpoint -q "$mnt" 2>/dev/null; then
```

`mountpoint` is provided by `util-linux`. On busybox-only OpenWrt builds (common in embedded
targets), `mountpoint` may not be available. The command would fail silently (`mountpoint -q`
exit 127), causing `disk_status` to always report `{"mounted":false,...}` even when the disk
is mounted.

**Safer alternative (busybox-safe):**
```sh
if grep -q " $mnt " /proc/mounts 2>/dev/null; then
```
Or, since the recorder already knows the mount state:
```sh
if awk -v m="$mnt" '$2==m{found=1} END{exit !found}' /proc/mounts; then
```

### D-7 [MEDIUM]: `set_config` Input Not Sanitized (Mount Path)

**File:** `/usr/libexec/rpcd/autorecorder`, `set_config` method

```sh
mount_path=$(printf '%s' "$input" | jsonfilter -e '@.mount' 2>/dev/null)
...
uci -q set autorecorder.config.mount="$mount_path"
```

The mount path is extracted from user-controlled JSON input and written directly to UCI without
validation. A malicious value like `../../etc/config/system` or a path containing UCI special
characters could corrupt the config. While rpcd ACL guards this to authenticated users with
`write` permission, the rpcd plugin itself should validate the mount path:
```sh
case "$mount_path" in
    /*) ;; # must be absolute
    *) printf '{"result":"invalid_mount"}\n'; exit 0 ;;
esac
```

### D-8 [MEDIUM]: Card/Device UCI Auto-Persist Race with LuCI

See H-12 above. The recorder background process and LuCI's `set_config` both call `uci commit
autorecorder`. On first successful detection, the recorder auto-persists `card` and `device`.
If the user is simultaneously saving config in LuCI, the recorder's commit may clobber the
user's changes.

**Mitigation:** In the recorder, only auto-persist if the key is genuinely absent (already
implemented), AND check again before committing:
```sh
# Double-check before commit to minimize race window
[ -n "$(uci_get card)" ] && continue  # user may have set it between our check and here
uci -q set ...
uci -q commit autorecorder
```
This does not eliminate the race but narrows it significantly.

### D-9 [LOW]: Hotplug Script Prefix/Ordering Change

Original: `/etc/hotplug.d/block/autorecorder` (no numeric prefix)
v4: `/etc/hotplug.d/block/50-autorecorder`

OpenWrt's hotplug daemon executes scripts in lexicographic order. Without a prefix, `autorecorder`
runs before any `[0-9]*` prefixed scripts. With `50-`, it runs after scripts prefixed `[0-9]` to
`4[0-9]`. In practice this ordering change is benign — the autorecorder script only calls
`service autorecorder reload` and does not depend on other block hotplug scripts. However it is
a behavior change that could theoretically matter if other block scripts (e.g., `block-mount`
automount) need to run first.

**Assessment:** The `50-` prefix is actually better practice (ensures mount helpers have run
before waking the recorder). This is an improvement, not a regression.

### D-10 [LOW]: UCI Config File Includes Empty-String Options

```
config autorecorder 'config'
    option card ''
    option device ''
    option mount '/tmp/mnt'
```

Writing `option card ''` to the config file means `uci get autorecorder.config.card` returns
the empty string (not "option not found"). The recorder's `uci_get` function handles this via
`[ -n "$card_num" ]`, correctly treating empty string as "not configured." However some UCI
tooling and LuCI CBI widgets treat absent options differently from empty options. If a future
CBI map is added, this could cause unexpected behavior.

**Safer approach:** Omit the options entirely from the initial config file and let the UCI API
return an error (which `uci -q get` handles by returning nothing to stdout):
```
config autorecorder 'config'
    option mount '/tmp/mnt'
```

---

## Feature Parity Matrix

| Feature | CGI v2/v3 Behavior | LuCI v4 State | Root Cause | Required Fix | Priority | Risk |
|---|---|---|---|---|---|---|
| USB audio hotplug | Fires on USB events via `/etc/hotplug.d/usb/` | **Missing** — not installed | Installer omits usb hotplug dir | Add `cat > /etc/hotplug.d/usb/50-autorecorder` | CRITICAL | High — core use-case broken |
| Start action result | Prints `"Failed to start"` / `"Started successfully"` to HTTP | Result field silently discarded in JS | `_doStart` ignores resolved value | Inspect `res.result` in `.then()`, alert on failure | CRITICAL | Low |
| Stop action result | Prints `"Failed to stop"` / `"Stopped successfully"` | Result field silently discarded | Same as above | Same fix pattern | CRITICAL | Low |
| Poll error resilience | N/A (synchronous CGI) | Unhandled promise rejection silently freezes display | No `.catch()` on poll `Promise.all` | Add per-call `.catch()` with fallback values | HIGH | Low |
| HTTP API endpoint | `GET /cgi-bin/cm?cmnd=X` (unauthenticated) | **Removed** — 404 | Architectural change to rpcd | Document/preserve CGI or document `ubus call` equivalent | HIGH | Medium |
| PROBE target device | Always `hw:0,0` | UCI card/device with `:-0` fallback | Intentional improvement but parity break | Document difference; consider dual probe or note in UI | HIGH | Low |
| `mountpoint` availability | N/A (recorder uses `mount`) | `mountpoint -q` may fail on busybox | busybox omits `mountpoint` | Use `/proc/mounts` grep | MEDIUM | Medium |
| Mount path validation | N/A (CGI has no set_config) | No path validation before UCI write | Input not sanitized | Add absolute-path check | MEDIUM | Low |
| UCI auto-persist race | N/A | Background uci commit races with LuCI | Concurrent writers | Add guard + double-check pattern | MEDIUM | Low |
| Hotplug chmod | 644 (likely bug in v2 installer) | 755 (correct) | v2 bug fixed | Already fixed in v4 — no action | LOW | None |
| Hotplug ordering | `autorecorder` (early) | `50-autorecorder` (mid) | Prefix added | Actually an improvement | LOW | None |
| UCI empty options | N/A | `option card ''` created | Write convenience | Omit empty options from initial config | LOW | None |
| ALSA card detection | `arecord -l` every cycle | UCI-first, `arecord -l` fallback | v4 optimization | Verify fallback correctly resets when card changes | MEDIUM | Low |
| Disk detection | `dd\|grep EXFAT` only | `blkid` primary, `dd` fallback | Improvement | Verify `blkid` available in target OpenWrt build | LOW | Low |
| Space check 100MB | `df -k $4 / 1024 <= 100` → umount, sleep 5 | Identical | — | No change needed | NONE | None |
| Single-exFAT enforcement | `exfat_count != 1` → no disk | Identical | — | No change needed | NONE | None |
| SIGHUP non-destructive wake | `trap 'true' SIGHUP` + `wait` | Identical | — | No change needed | NONE | None |
| SIGTERM cleanup | kill arecord + umount | Identical | — | No change needed | NONE | None |
| Sentinel sleep | `sleep infinity & dummy=$!` | Identical | — | No change needed | NONE | None |
| Rate cap 48000 | `[ "$max_rate" -gt 48000 ] && max_rate=48000` | Identical | — | No change needed | NONE | None |
| Raw PCM output filename | `$(date +%s)_ch-rate-fmt.raw` | Identical | — | No change needed | NONE | None |
| procd `START=99` | Late start after networking | Identical | — | No change needed | NONE | None |
| procd `reload_signal SIGHUP` | Reload sends SIGHUP | Identical | — | No change needed | NONE | None |
| LuCI authentication | None (CGI open) | Session required + ACL | Architectural | Expected; document API breakage | LOW | None |
| GET-only enforcement | `REQUEST_METHOD` check | N/A (rpcd handles method) | Architectural | No action needed | NONE | None |

---

## Critical Bugs

### BUG-1: USB Audio Hotplug Missing

**Severity:** CRITICAL  
**Symptom:** Plugging in a USB audio interface (e.g., USB microphone, USB sound card) does not
wake the recorder. Recording never starts even if a valid exFAT storage device is already present.  
**Affected component:** v4 installer (`luciv4.sh`)  
**Root cause:** The installer heredoc only creates `/etc/hotplug.d/block/50-autorecorder`.
The `/etc/hotplug.d/usb/` directory receives nothing.  
**Fix:** Add to the installer after the block hotplug section:
```sh
mkdir -p /etc/hotplug.d/usb
cat > /etc/hotplug.d/usb/50-autorecorder << 'EOF_HOTPLUG_USB'
#!/bin/sh
service autorecorder reload
EOF_HOTPLUG_USB
chmod 0755 /etc/hotplug.d/usb/50-autorecorder
OK "/etc/hotplug.d/usb/50-autorecorder"
```

### BUG-2: Start/Stop Silent Failure

**Severity:** CRITICAL  
**Symptom:** User clicks "Start"; recorder fails to start (procd error, arecord not found,
etc.); UI shows no error, buttons re-enable, status updates in 5 seconds to "Stopped".  
**Affected component:** `main.js`, `_doStart()` and `_doStop()` handlers  
**Fix:** Inspect `res.result` in resolved promise:
```javascript
_doStart: function() {
    var self = this;
    self._setBusy(true);
    return callStart().then(function(res) {
        if (!res || res.result === 'failed') {
            window.alert(_('Failed to start recorder. Check system logs.'));
        }
    }).catch(function(err) {
        window.alert(_('RPC error: ') + (err.message || String(err)));
    }).then(function() { self._setBusy(false); });
},
_doStop: function() {
    var self = this;
    self._setBusy(true);
    return callStop().then(function(res) {
        if (!res || res.result === 'failed') {
            window.alert(_('Failed to stop recorder. Check system logs.'));
        }
    }).catch(function(err) {
        window.alert(_('RPC error: ') + (err.message || String(err)));
    }).then(function() { self._setBusy(false); });
},
```

### BUG-3: Poll Rejection Freezes Status Display

**Severity:** HIGH  
**Symptom:** On rpcd timeout or session expiry, the status badge and disk info freeze
indefinitely at last known values. No error is displayed.  
**Affected component:** `main.js`, `poll.add` callback  
**Fix:** See D-3 above — add per-call `.catch()` in the poll handler.

---

## Security Findings

### S-1: CGI Unauthenticated Access (Legacy Design)

The original `controlweb_cgi` relies entirely on the web server (uhttpd) for access control.
On OpenWrt's default configuration, `uhttpd` requires HTTP basic auth for the admin interface.
If uhttpd is configured without auth (or with the CGI path excluded from auth), START/STOP/PROBE
are exposed without any authentication. The CGI itself performs no auth checks.

**v4 improvement:** rpcd + LuCI session authentication enforces login before any action. The ACL
system (`luci-app-autorecorder`) provides fine-grained read/write separation. This is a security
**improvement** in v4, not a regression.

### S-2: PROBE Command Exposes Hardware Information

Both CGI and LuCI expose `arecord --dump-hw-params` output to the authenticated user. This
output includes ALSA card capabilities, supported rates, buffer sizes, etc. On a multi-user LuCI
setup, any user with ACL `read` on `autorecorder.probe` can enumerate the hardware. This is
intentional functionality but should be noted.

### S-3: Mount Path Injection via set_config

**File:** `/usr/libexec/rpcd/autorecorder`

```sh
mount_path=$(printf '%s' "$input" | jsonfilter -e '@.mount' 2>/dev/null)
uci -q set autorecorder.config.mount="$mount_path"
```

`jsonfilter` correctly extracts the string value from the JSON, so there is no JSON injection.
However `mount_path` is not validated before being written to UCI. A value of `../../../etc/passwd`
would be written to UCI (UCI values are strings and UCI does no path validation). The recorder
would then attempt to mount the exFAT disk to `../../../etc/passwd` which would fail (not a
directory), but the invalid value persists in UCI.

**Impact:** Low — UCI corruption, not code execution. But the mount path should be validated
as an absolute path.

### S-4: `pgrep -f` Matching Breadth

**File:** rpcd `is_running()`, CGI `is_running()`

`pgrep -f /usr/sbin/recorder` matches any process whose full command line contains
`/usr/sbin/recorder`. This includes processes reading, copying, or editing the file. On a
production router this is very unlikely to cause a problem, but it is a theoretically incorrect
process-presence check. A pidfile (`/var/run/recorder.pid`, managed by procd) would be safer,
but procd does not expose pid files for shell-plugin services without explicit configuration.

**Recommended mitigation:** `pgrep -x recorder` (exact name match) combined with checking for
a procd-managed instance:
```sh
is_running() { pgrep -x recorder >/dev/null 2>&1; }
```
Note: `-x` matches only the process name (basename of argv[0]), not the full path. On OpenWrt,
`/usr/sbin/recorder` runs as `recorder` (basename), so this works correctly.

### S-5: rpcd Plugin World-Executable

The installer sets:
```sh
chmod 0755 /usr/libexec/rpcd/autorecorder
```

This is correct — rpcd exec plugins must be executable by rpcd (which runs as root). The `0755`
permission means any user can execute the plugin directly as a shell script, which would print
`{"status":{},...}` (the list response). This is harmless since the plugin's `call` actions
require argv[1]=call argv[2]=method, and without rpcd session context they return valid JSON but
nothing actionable. Not a security risk.

### S-6: `uci commit` from Background Process

The recorder (a procd-managed background process running as root) calls `uci commit
autorecorder`. This is standard OpenWrt practice, but it should be noted that any process
running as root on OpenWrt can modify any UCI config. There is no per-config permission
separation in UCI.

---

## Recommended Refactor Strategy

Beyond minimum parity, the following architectural improvements are recommended:

### R-1: Add ACTION filtering to hotplug scripts

Currently the hotplug scripts fire on all block and USB events (add and remove). The recorder
handles this gracefully, but unnecessary SIGHUP signals cause extra loop iterations. Adding
ACTION filtering reduces load on slow embedded hardware:

```sh
#!/bin/sh
# Only wake recorder on device add/change, not remove
case "$ACTION" in add|change) service autorecorder reload ;; esac
```

For the USB hotplug, also filter by `SUBSYSTEM`:
```sh
#!/bin/sh
[ "$SUBSYSTEM" = "sound" ] || [ "$SUBSYSTEM" = "usb" ] || exit 0
service autorecorder reload
```

### R-2: Use pidfile for process tracking

Replace `pgrep -f` with a procd pidfile approach. Add to `start_service()`:
```sh
start_service() {
    procd_open_instance
    procd_set_param command  "$PROG"
    procd_set_param pidfile  /var/run/recorder.pid
    procd_set_param stdout   1
    procd_set_param stderr   1
    procd_set_param reload_signal SIGHUP
    procd_close_instance
}
```

Then `is_running`:
```sh
is_running() {
    local pid
    pid=$(cat /var/run/recorder.pid 2>/dev/null) && [ -e "/proc/$pid" ]
}
```

### R-3: Expose recording file list via rpcd

The v4 port has no way to list or manage recorded files via LuCI. Adding a `list_files` rpcd
method and a corresponding LuCI table would complete the user workflow:

```sh
list_files)
    mnt=$(uci_get mount); mnt="${mnt:-$MNT_DEFAULT}"
    if mountpoint -q "$mnt" 2>/dev/null; then
        files=$(ls -1t "$mnt"/*.raw 2>/dev/null | head -20)
        # emit JSON array
    fi
    ;;
```

### R-4: Add i18n catalog

The JS view uses `_('...')` for all strings but no `.po` translation file is provided. For a
proper LuCI application, create `po/templates/autorecorder.pot` and ship at least an `en`
catalog to ensure the i18n framework is correctly initialized.

### R-5: Add status update immediately after start/stop

Rather than waiting 5 seconds for the poll to update the status badge after a start/stop action,
trigger an immediate status refresh:

```javascript
_doStart: function() {
    var self = this;
    self._setBusy(true);
    return callStart().then(function(res) {
        if (!res || res.result === 'failed') {
            window.alert(_('Failed to start recorder.'));
        }
        // Immediate refresh
        return callStatus();
    }).then(function(status) {
        var sc = document.getElementById('ar-status-cell');
        if (sc && status) dom.content(sc, self._statusBadge(status));
    }).catch(function(err) {
        window.alert(_('RPC error: ') + (err.message || String(err)));
    }).then(function() { self._setBusy(false); });
},
```

---

## Implementation Roadmap

### Phase 1 — Critical Regressions (fix before deployment)

**P1-A: Add USB hotplug handler**
- File: `luciv4.sh` installer
- Add after block hotplug section:
  ```sh
  mkdir -p /etc/hotplug.d/usb
  cat > /etc/hotplug.d/usb/50-autorecorder << 'EOF_HOTPLUG_USB'
  #!/bin/sh
  service autorecorder reload
  EOF_HOTPLUG_USB
  chmod 0755 /etc/hotplug.d/usb/50-autorecorder
  OK "/etc/hotplug.d/usb/50-autorecorder"
  ```
- Risk: None. Pure addition.
- Test: Plug/unplug USB audio card → verify SIGHUP sent → verify recorder wakes.

**P1-B: Surface start/stop result in JS**
- File: `main.js` (`_doStart`, `_doStop`)
- Inspect `res.result` in resolved promise handler; alert on `"failed"` or null.
- Risk: None. UI-only change.
- Test: Simulate failure by stopping rpcd, clicking Start → expect alert.

**P1-C: Add poll error resilience**
- File: `main.js` (`poll.add` callback)
- Add per-call `.catch()` with safe default return values.
- Risk: None. Defensive addition.
- Test: Temporarily stop rpcd → verify status display shows fallback, not frozen.

### Phase 2 — High Priority (fix within release cycle)

**P2-A: Replace `mountpoint` with `/proc/mounts` check**
- File: rpcd plugin (`disk_status` method)
- Change `mountpoint -q "$mnt"` to `awk -v m="$mnt" '$2==m{found=1}END{exit !found}' /proc/mounts`
- Risk: Low. Behavioral equivalent on all busybox builds.
- Test: Verify disk_status returns correct mounted/unmounted state.

**P2-B: Validate mount path in set_config**
- File: rpcd plugin (`set_config` method)
- Add absolute-path check after `jsonfilter` extraction.
- Risk: None. Rejects invalid input.
- Test: Send `{"mount":"../../../etc"}` → expect `{"result":"invalid_mount"}`.

**P2-C: Document CGI endpoint removal**
- Update README/installer output to mention `ubus call autorecorder start/stop/status/probe`.
- Consider optionally preserving CGI for backward compat (trivial addition).

### Phase 3 — Medium Priority (next iteration)

**P3-A: Add immediate status refresh after action**
- File: `main.js` (both action handlers)
- Trigger `callStatus()` after start/stop, update badge before poll fires.

**P3-B: Narrow auto-persist race window in recorder**
- File: embedded recorder in `luciv4.sh`
- Add re-check of `uci_get card` immediately before commit.

**P3-C: ACTION filter in hotplug scripts**
- Add `case "$ACTION" in add|change) ... esac` to both hotplug scripts.

### Phase 4 — Low Priority / Improvements

**P4-A: Omit empty UCI options from initial config**
- Change initial `/etc/config/autorecorder` to omit `option card ''` and `option device ''`.

**P4-B: Use `pgrep -x recorder` in is_running**
- Both CGI and rpcd plugin.

**P4-C: Add i18n catalog stub**
- Create `po/templates/autorecorder.pot`.

**P4-D: Add recorded files list in LuCI**
- New rpcd method + JS table.

---

## Validation & Regression Test Plan

### T-1: USB Audio Hotplug (BUG-1 verification)

1. Install v4 on a clean OpenWrt device.
2. Attach a known exFAT USB storage drive (already present).
3. Plug in a USB audio interface.
4. Expected: within 3 seconds, `service autorecorder reload` is logged in syslog.
5. Verify: `logread | grep 'autorecorder.*reload'`
6. Further: verify recorder starts recording (check `ls /tmp/mnt/*.raw`).

### T-2: Start/Stop Result Feedback (BUG-2 verification)

1. Open LuCI → ALSA Recorder.
2. Stop the recorder (or ensure it is stopped).
3. Remove execute permission from `/usr/sbin/recorder`: `chmod -x /usr/sbin/recorder`.
4. Click "Start".
5. Expected: alert box appears: "Failed to start recorder."
6. Restore: `chmod +x /usr/sbin/recorder`.

### T-3: Poll Error Resilience (BUG-3 verification)

1. Open LuCI → ALSA Recorder. Note current status.
2. Run `kill $(pgrep rpcd)` to temporarily kill rpcd (it will restart).
3. Observe LuCI page during rpcd restart window (5–15 seconds).
4. Expected: status/disk cells show fallback values (or remain unchanged), no JS console errors.
5. After rpcd restarts: status display resumes updating.

### T-4: USB Storage Hotplug

1. Recorder service running, no storage attached.
2. Plug in exFAT USB drive.
3. Expected: recorder wakes, mounts drive, starts arecord within 5 seconds.
4. Verify: `ls /tmp/mnt/` shows a `.raw` file.

### T-5: Low Disk Space Behavior

1. Fill the USB drive to leave < 100MB free.
2. Send SIGHUP: `service autorecorder reload`.
3. Expected: recorder evaluates, finds < 100MB, sleeps 5s, does not start recording.
4. Verify: no new `.raw` file created. `df -h /tmp/mnt` shows < 100MB free.

### T-6: Multi-exFAT Disk Rejection

1. Attach two exFAT USB drives.
2. Send SIGHUP.
3. Expected: recorder does not start (exfat_count = 2, disk = "").
4. Remove one drive, send SIGHUP again.
5. Expected: recorder starts recording.

### T-7: PROBE Hardware Query

1. Ensure recorder is stopped.
2. Click "Probe Hardware" in LuCI.
3. Expected: `<pre>` shows ALSA hardware parameters for configured card.
4. With UCI card/device empty: should probe hw:0,0 (same as CGI fallback).
5. With UCI card=1,device=0: should probe hw:1,0.

### T-8: Config Save/Clear Cycle

1. Enter card=0, device=0, mount=/tmp/mnt in Hardware Configuration.
2. Click Save. Expected: "Saved ✓" feedback, UCI updated (`uci get autorecorder.config.card` → `0`).
3. Click Clear. Expected: "Cleared ✓" feedback, UCI options deleted.
4. Verify: `uci show autorecorder` shows no card/device options.

### T-9: rpcd ACL Enforcement

1. Create a LuCI user without `luci-app-autorecorder` ACL.
2. Log in as that user.
3. Expected: Services → ALSA Recorder not visible in menu.
4. Direct ubus call: `ubus call autorecorder start` should return error 6 (permission denied).

### T-10: Concurrent UCI Write Race

1. Start recorder without UCI card/device configured.
2. Immediately after service start, run `uci set autorecorder.config.card=1; uci commit autorecorder`.
3. Wait 10 seconds for recorder to auto-detect and attempt to persist.
4. Verify: `uci get autorecorder.config.card` — should be `1` (user's value), not overwritten.

### T-11: `mountpoint` on Target Build

1. On the target OpenWrt image: `which mountpoint` or `mountpoint --version`.
2. If not found: verify D-6 fix is applied before deployment.

---

## Missing Information / Assumptions

**A-1:** The LuCI v4 installer does not include a Lua controller or a `luci-app-autorecorder`
ipk package manifest. It is assumed LuCI's JS-only view system (OpenWrt 22.03+) is being
targeted. On older LuCI versions (OpenWrt 21.02 with CBI-based views), the JS view may not
load correctly. **Assumption:** Target is OpenWrt 22.03 or newer.

**A-2:** The `rpc.declare` calls in `main.js` do not specify `params` for read-only methods
(status, probe, disk_status, get_config). This is correct — zero-parameter calls. The
`set_config` call uses `params: ['card', 'device', 'mount']`. It is assumed this sends the
parameters as a JSON object `{"card":...,"device":...,"mount":...}` via the ubus RPC bridge,
which the rpcd shell plugin reads from stdin. This is the standard LuCI/rpcd integration
pattern and is assumed correct.

**A-3:** No Lua controller file (`controller/autorecorder.lua`) is present or referenced. The
`/usr/share/luci/menu.d/autorecorder.json` menu entry uses `"type":"view"` which is the JS-only
view mode. LuCI will serve the JS view directly without a Lua controller. **Assumption:** This
is intentional and the target LuCI version supports view-type menu entries.

**A-4:** The `_('...')` i18n calls in the JS view will fall back to the string literal if no
translation catalog is loaded. On English-language installations, this is transparent. On
non-English installations, all UI text will appear in English regardless of locale. **Assumption:**
This is acceptable for the current release scope.

**A-5:** The `blkid` binary in OpenWrt's `block-mount` package may or may not have exFAT type
detection compiled in, depending on the specific package version and target architecture. The
v4 recorder correctly falls back to the `dd|grep EXFAT` method when `blkid` returns empty.
**Assumption:** The fallback path is correctly exercised when blkid lacks exFAT support.

**A-6:** `jsonfilter` is assumed available. It is part of OpenWrt's base system but is a
separate package (`jsonfilter`). If not installed, `set_config` will silently fail to parse
inputs and all values will be empty. The installer does not explicitly install `jsonfilter` via
`opkg`. **Assumption:** It is pre-installed on all target OpenWrt versions. If not, add to
`opkg install` in the installer.

**A-7:** The hotplug script `service autorecorder reload` assumes the `service` command is
available. On OpenWrt, `service` is a busybox applet that calls the init script. This is
always available. **Confirmed safe assumption.**

**A-8:** The installer's `set -e` causes the entire script to exit on the first failing command.
If `opkg update` fails (network issue), the installer exits. However the installer uses
`|| WARN ...` for opkg update but `|| ERR ...` for opkg install. If a package in the install
list is unavailable, the installer exits. **Assumption:** All packages in the install list are
available in the configured opkg feeds.
