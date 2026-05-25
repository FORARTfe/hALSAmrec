### 1. Architecture Overview

```
Installer.sh          ← fetches + deploys all components
recorder              ← main ALSA capture loop (/usr/sbin/recorder)
initscript            ← procd init for recorder service
hotplug               ← reload trigger on block/USB events
controlweb_cgi        ← CGI command interface (/www/cgi-bin/cm)
```

---

### 2. Issues Found in the old version

**[CRITICAL]**
- **`recorder`: `awk` dependency** — single `awk '{print $NF}'` call in bitformat parsing; only external tool that can be eliminated with `${var##* }`
- **`recorder`: `arecord -l` called twice** — outer loop reads it for readiness check; inner block calls it again from scratch to parse card/device numbers; second call is entirely redundant
- **`controlweb_cgi`: double `sed` pipeline** — `echo "$QUERY_STRING" | sed … | sed …` spawns 3 processes; pure shell parameter expansion costs zero
- **`controlweb_cgi`: `ABOUT` in installer output but `STATUS` in CGI** — installer prints `cmnd=ABOUT` which is an unknown command in the CGI; silent functional bug

**[MODERATE]**
- **`Installer.sh`: `set -e` + unreachable error path** — `opkg install "$pkg"` is a plain command under `set -e`; failure exits the script immediately; the `if [ $? -eq 0 ]` error message block is dead code and never runs
- **`Installer.sh`: `opkg list-installed | grep` per package** — fires a full package list parse on each iteration; `opkg install` is already idempotent (skips installed packages at current version), making the entire check loop redundant
- **`recorder`: dead code in disk-space block** — `if [ -n "$recorder" ]` guard before `kill` is unreachable; at that point in the flow, `recorder` is guaranteed empty (it passed the `[ -n "$recorder" ] && continue` above)
- **`recorder`: unquoted `$disk` in `[ -e $disk ]`** — if `disk=""`, evaluates as `[ -e ]` which returns 0 (true) in some sh variants, incorrectly marking readiness

**[MINOR]**
- **`recorder`: `RECORDER_PROC` path repeated 4×** — hard-coded `/usr/sbin/recorder` appears inline in every `pgrep` call; same for `/etc/init.d/autorecorder`
- **`recorder`: `exfat_parts` list + separate counting loop** — builds a space-separated string only to count it with a second loop; can track count inline
- **`recorder`: intermediate variables** — `name`, `waiton`, `ready`, `device_info`, `inputhw=$(echo "$card,$device")` each spawn a subshell or add a variable where none is needed
- **`controlweb_cgi`: `echo "$(...)"` wrapper in PROBE** — `echo "$(arecord ...)"` creates a subshell only to pass output to `echo`; direct exec suffices
- **`initscript`: `STOP=01`** — leading zero is a cosmetic issue; `STOP=1` is cleaner
- **`initscript`: unused `NAME=recorder`** — `NAME` is a legacy rc.common variable not used by procd `USE_PROCD=1` style scripts

---

### 3. Optimization Strategy

- **Eliminate `awk`**: `${fmt_raw##* }` extracts the last whitespace-delimited token in pure sh — zero additional processes
- **Merge `arecord -l` calls**: capture output once, reuse for both the readiness check (`card_line` non-empty) and card/device number parsing
- **Replace `grep | sed` chains with single `sed -n`**: `sed -n 's/^LABEL:.../\1/p'` does what `grep LABEL | sed` does in one process instead of two
- **Replace `echo | sed | sed` with shell expansion**: `${QUERY_STRING##*cmnd=}` / `${tmp%%&*}` needs no subprocesses
- **Replace per-package `opkg` loop with single invocation**: `opkg install $PACKAGES` — idempotent by design, fixes the `set -e` dead-code bug
- **Collapse `mv` + `chmod` to `install -m MODE`**: atomic, available in busybox, one call instead of two
- **Remove dead code and redundant intermediate variables** throughout

---

### 4. Key Improvements

**Dependency elimination**

| Removed | Replaced with | Saves |
|---|---|---|
| `awk '{print $NF}'` | `${fmt_raw##* }` | 1 process/recording cycle |
| `grep … \| sed …` (×5 in recorder) | `sed -n 's/^LABEL:…/p'` | 1 process per parse call |
| `echo \| sed \| sed` (CGI) | `${var##*cmnd=}` / `${var%%&*}` | 3 processes per CGI request |
| `echo "$(arecord …)"` (CGI) | `arecord … 2>&1` directly | 1 subshell per PROBE |
| Second `arecord -l` (recorder) | Reuse `card_line` | 1 full `arecord` exec/loop |
| `opkg list-installed \| grep` ×N | `opkg install $PACKAGES` once | N list+grep pairs |
| `mv` + `chmod` pairs (installer) | `install -m MODE src dst` | 1 call per file |

**Bug fixes**
- Dead `if [ $? -eq 0 ]` error branch in installer (unreachable under `set -e`) — replaced with correct `opkg install $PACKAGES` single call
- `cmnd=ABOUT` in installer output corrected to `cmnd=STATUS` to match actual CGI handler
- Unquoted `[ -e $disk ]` guarded via `[ -z "$disk" ]` before any use
- Dead `if [ -n "$recorder" ]` block inside disk-space check removed

**Size reduction**
- `recorder`: ~25 lines removed (second `arecord -l` call + `device_info` parse block + intermediate variables + dead disk-check guard + `exfat_parts` build+count loop)
- `Installer.sh`: 18-line per-package loop → 1 line
- `controlweb_cgi`: 2-pipe sed chain → 2 shell expansions, inline constants extracted

---

### 5. Risk Assessment

| Change | Risk | Rationale |
|---|---|---|
| `${fmt_raw##* }` replacing `awk '{print $NF}'` | None | Both extract last whitespace-delimited token; sh parameter expansion is POSIX |
| Single `arecord -l` call | None | `card_line` is captured before the `is_running`/`wait` branch, same call site as the original outer check |
| `sed -n 's/^LABEL:…/p'` replacing `grep LABEL \| sed` | None | `^LABEL:` anchor is stricter than grep's substring match — actually more correct |
| `opkg install $PACKAGES` without loop | Low | opkg idempotency is documented; if a package is absent from feeds the entire install fails loudly rather than silently skipping — preferable on embedded |
| `ABOUT` → `STATUS` in installer output | Fix, not risk | `ABOUT` was a broken link; `STATUS` matches the CGI handler |
| `NAME=recorder` removed from initscript | None | Unused by `USE_PROCD=1` scripts; procd uses the init script filename as service name |

---

### Bonus — Optional Future Improvements

- **`recorder`: replace `dd \| grep` exFAT detection with `blkid -o value -s TYPE "$dev"`** — more reliable, handles VFAT vs exFAT edge cases, already available when `block-mount` is installed (which is a required package)
- **`controlweb_cgi`: add POST support for mutating commands** — `START`/`STOP` over GET are susceptible to CSRF if the router admin visits a crafted page while logged in
- **`recorder`: add minimum-space guard at recording start** (currently only checks before mount; a long recording session can still fill the disk mid-capture without triggering a clean stop)
- **`recorder`: persist card index in UCI** rather than always auto-detecting — eliminates `arecord -l` from the hot loop entirely on stable hardware
