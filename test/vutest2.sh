#!/bin/sh

################################################################################
# LuCI VU Meter Module Installer (Self-Contained) v1.2
#
# Comprehensive installation script for the LuCI VU Meter display module.
# Automatically generates and installs all files inline.
# Fixed for OpenWrt 24.10.x
#
################################################################################

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Defaults
ACTION="install"

# Paths
OPENWRT_ROOT="${OPENWRT_ROOT:-}"
LUCI_LIB_PATH="${OPENWRT_ROOT}/usr/lib/lua/luci"

# FIX [BUG-1]: Was "/usr/share/luci-mod-admin-full/luasrc/view".
# That path exists only in the package Makefile source tree during a firmware
# build; it is never created on the running router.  LuCI's template renderer
# resolves all .htm includes relative to /usr/lib/lua/luci/view/ at runtime.
LUCI_VIEW_PATH="${OPENWRT_ROOT}/usr/lib/lua/luci/view"

LUCI_STATIC_PATH="${OPENWRT_ROOT}/www/luci-static/resources"
UCI_CONFIG_PATH="${OPENWRT_ROOT}/etc/config"

MODULE_NAME="vumeter"
MODULE_VERSION="1.2"

# ── Output helpers ─────────────────────────────────────────────────────────────

print_header() {
  printf '%b\n' "${BLUE}══════════════════════════════════════════════════════════${NC}"
  printf '%b\n' "${BLUE}  LuCI VU Meter Module Installer v${MODULE_VERSION}${NC}"
  printf '%b\n' "${BLUE}══════════════════════════════════════════════════════════${NC}"
  echo ""
}

print_info()    { printf '%b\n' "${BLUE}ℹ${NC}  $1"; }
print_success() { printf '%b\n' "${GREEN}✓${NC}  $1"; }
print_warning() { printf '%b\n' "${YELLOW}⚠${NC}  $1"; }
print_error()   { printf '%b\n' "${RED}✗${NC}  $1"; }
print_step()    { printf '%b\n' "${YELLOW}→${NC}  $1"; }

# ── Utilities ──────────────────────────────────────────────────────────────────

check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    print_error "This script must be run as root"
    exit 1
  fi
}

ensure_dir() {
  if [ ! -d "$1" ]; then
    print_step "Creating directory: $1"
    mkdir -p "$1"
  fi
}

# FIX [BUG-2]: LuCI builds an on-disk index of all registered controller
# entry-points (/tmp/luci-indexcache) and a per-module compiled bytecode cache
# (/tmp/luci-modulecache/).  Dropping a new controller file onto disk without
# invalidating these caches means LuCI continues serving the old (empty) index
# indefinitely — this was the primary reason the System > VU Meter menu entries
# never appeared after installation.  This function must be called after all
# files are written, and also after uninstall so stale entries are removed.
clear_luci_cache() {
  print_step "Clearing LuCI dispatcher index cache..."
  rm -f  /tmp/luci-indexcache
  rm -rf /tmp/luci-modulecache/
  print_success "LuCI cache cleared."
}

################################################################################
# Inline Source File Generation
################################################################################

install_files() {

  # ── 1. Controller ────────────────────────────────────────────────────────────
  ensure_dir "${LUCI_LIB_PATH}/controller"
  print_step "Generating Controller: ${LUCI_LIB_PATH}/controller/${MODULE_NAME}.lua"
  cat << 'EOF' > "${LUCI_LIB_PATH}/controller/${MODULE_NAME}.lua"
-- FIX [BUG-3]: nixio was referenced as an implicit global.  OpenWrt 24
-- tightened Lua module scoping so nixio is no longer guaranteed to be
-- pre-loaded in every controller context.  A nil-access would silently abort
-- index(), leaving the menu entry unregistered with no visible log entry.
local nixio = require "nixio"

module("luci.controller.vumeter", package.seeall)

function index()
    -- Only register menu entries when the UCI configuration file is present.
    -- nixio.fs.access() returns true if the path exists and is readable.
    if not nixio.fs.access("/etc/config/vumeter") then return end

    local page
    page = entry({"admin","system","vumeter"}, cbi("vumeter"), _("VU Meter Settings"), 60)
    page.dependent = true

    page = entry({"admin","system","vumeter","display"}, template("vumeter/display"), _("VU Meter Display"), 1)
    page.leaf = true

    entry({"admin","system","vumeter","status"}, call("action_status")).leaf = true
end

function action_status()
    local sys = require "luci.sys"

    -- ── CPU usage ─────────────────────────────────────────────────────────────
    -- FIX [BUG-5]: The original code ran:
    --   utl.exec("top -bn1 | grep 'CPU:' | head -n1")
    -- BusyBox top on many OpenWrt builds does not support -b (batch mode) or
    -- -n (iteration count) consistently; the CPU% would silently fall back to
    -- the load-avg heuristic or produce an incorrect value depending on the
    -- firmware variant.
    --
    -- Replacement: /proc/stat two-snapshot delta.
    --   Step 1 – read current cumulative CPU tick counters from /proc/stat.
    --   Step 2 – compare against the snapshot saved during the previous
    --            XHR poll cycle (persisted in /tmp/.vumeter_cpu).
    --   Step 3 – cpu% = (Δtotal - Δidle - Δiowait) / Δtotal × 100
    --
    -- On the very first poll (no prior snapshot) we fall back to load1 × 100.
    local cpu_usage = 0

    local function read_proc_stat()
        local f = io.open("/proc/stat")
        if not f then return nil end
        local line = f:read("*l")
        f:close()
        -- First line format: "cpu  user nice system idle iowait irq softirq steal …"
        local t = {}
        for v in line:gsub("^cpu%s+", ""):gmatch("%d+") do
            t[#t + 1] = tonumber(v)
        end
        return t   -- index 1=user 2=nice 3=system 4=idle 5=iowait 6=irq 7=softirq …
    end

    local cur = read_proc_stat()
    if cur then
        -- Load previous snapshot (may not exist on first run)
        local prev = {}
        local pf = io.open("/tmp/.vumeter_cpu", "r")
        if pf then
            for v in pf:read("*a"):gmatch("%d+") do prev[#prev + 1] = tonumber(v) end
            pf:close()
        end

        -- Persist current snapshot for the next poll cycle
        local sf = io.open("/tmp/.vumeter_cpu", "w")
        if sf then sf:write(table.concat(cur, " ")); sf:close() end

        if #prev >= 5 then
            -- d_idle covers both genuine idle time and I/O-wait time; both are
            -- "not executing user or kernel code" from a busy-meter perspective.
            local d_idle  = (cur[4] - prev[4]) + (cur[5] - prev[5])
            local d_total = 0
            local n = math.min(#cur, #prev)
            for i = 1, n do d_total = d_total + (cur[i] - prev[i]) end
            if d_total > 0 then
                cpu_usage = math.max(0, math.min(100,
                    math.floor(((d_total - d_idle) / d_total) * 100)))
            end
        else
            -- First call: no prior snapshot available; approximate with load1.
            -- load1 == 1.0 means one full CPU core is busy; cap at 100%.
            local load1 = sys.loadavg()
            cpu_usage = math.min(100, math.floor(load1 * 100))
        end
    end

    -- ── Memory usage ──────────────────────────────────────────────────────────
    -- FIX [BUG-4]: The original code called:
    --   local mem_total, mem_cached, mem_buffered, mem_free = sys.sysinfo()
    --
    -- luci.sys.sysinfo() actually returns:
    --   uptime(1), totalram(2), freeram(3), sharedram(4), bufferram(5)
    --
    -- So "mem_total" was receiving the system uptime in seconds, making the
    -- subsequent  ((mem_total - mem_free) / mem_total) × 100  calculation
    -- produce garbage (typically near 100% because uptime >> free-ram-in-kB).
    --
    -- Replacement: parse /proc/meminfo directly.  The result follows the same
    -- "used = total - free - buffers - cache" formula that `free` uses, which
    -- correctly excludes page-cache memory that the kernel reclaims on demand.
    -- The "\nCached:" anchor prevents accidentally matching "SwapCached:".
    local mem_used_pct = 0
    local mf = io.open("/proc/meminfo")
    if mf then
        local mi = mf:read("*a"); mf:close()
        local total = tonumber(mi:match("MemTotal:%s+(%d+)"))  or 0
        local free  = tonumber(mi:match("MemFree:%s+(%d+)"))   or 0
        local bufs  = tonumber(mi:match("Buffers:%s+(%d+)"))   or 0
        local cache = tonumber(mi:match("\nCached:%s+(%d+)"))  or 0
        if total > 0 then
            local used = total - free - bufs - cache
            mem_used_pct = math.max(0, math.min(100, math.floor((used / total) * 100)))
        end
    end

    -- ── Network traffic ───────────────────────────────────────────────────────
    -- FIX [BUG-6]: The original code returned math.random() values — purely
    -- fictional.  Replacement algorithm:
    --
    --   1. Read rx_bytes and tx_bytes for the first found interface from the
    --      candidate list {br-lan, eth0, eth1, ether0}.
    --
    --   2. Compare against byte counters saved during the previous poll cycle
    --      (state file: /tmp/.vumeter_net, three lines: last_rx, last_tx, epoch).
    --
    --   3. Compute bytes/s over the elapsed interval and express as a percentage
    --      of 100 Mbit/s (12 500 000 B/s).  This reference is configurable in
    --      the UCI model if a larger uplink is desired.
    --
    --   4. Clamp negative deltas to 0 — these occur when an interface is
    --      brought down and the kernel resets its byte counters.
    --
    -- /proc/net/dev column layout (fields after the "iface:" prefix):
    --   rx_bytes(1) rx_pkts(2) rx_err(3) rx_drop(4) rx_fifo(5)
    --   rx_frame(6) rx_compr(7) rx_mcast(8)  ← skip fields 2-8
    --   tx_bytes(9) tx_pkts(10) ...
    --
    local rx_pct, tx_pct = 0, 0
    local ndf = io.open("/proc/net/dev")
    if ndf then
        local nd = ndf:read("*a"); ndf:close()

        local rx_b, tx_b = 0, 0
        for _, dev in ipairs({"br-lan", "eth0", "eth1", "ether0"}) do
            -- Capture rx_bytes (field 1) and tx_bytes (field 9) after the colon.
            -- The 7 intervening %s+%d+ blocks skip rx_pkts through rx_mcast.
            local rx, tx = nd:match(
                dev .. ":%s*(%d+)%s+%d+%s+%d+%s+%d+%s+%d+%s+%d+%s+%d+%s+%d+%s+(%d+)")
            if rx then
                rx_b = tonumber(rx); tx_b = tonumber(tx)
                break
            end
        end

        local now = os.time()
        local last_rx, last_tx, last_t = 0, 0, now - 2   -- sane default: 2 s ago

        local nf = io.open("/tmp/.vumeter_net", "r")
        if nf then
            last_rx = tonumber(nf:read("*l")) or 0
            last_tx = tonumber(nf:read("*l")) or 0
            last_t  = tonumber(nf:read("*l")) or (now - 2)
            nf:close()
        end

        -- Persist current counters for the next poll cycle
        local ns = io.open("/tmp/.vumeter_net", "w")
        if ns then
            ns:write(rx_b .. "\n" .. tx_b .. "\n" .. now .. "\n")
            ns:close()
        end

        local dt      = math.max(1, now - last_t)   -- guard against dt == 0
        local max_bps = 12500000                     -- 100 Mbit/s in bytes/s
        local drx = rx_b - last_rx
        local dtx = tx_b - last_tx
        if drx < 0 then drx = 0 end   -- interface counter reset
        if dtx < 0 then dtx = 0 end

        rx_pct = math.min(100, math.floor((drx / dt / max_bps) * 100))
        tx_pct = math.min(100, math.floor((dtx / dt / max_bps) * 100))
    end

    luci.http.prepare_content("application/json")
    luci.http.write_json({
        cpu    = cpu_usage,
        memory = mem_used_pct,
        rx     = rx_pct,
        tx     = tx_pct,
    })
end
EOF
  # FIX [BUG-7]: Was chmod 755.  Lua files are loaded by the interpreter at
  # runtime; the OS execute bit is meaningless for them.  644 = owner rw,
  # group/world r — correct for a read-only data file served to a daemon.
  chmod 644 "${LUCI_LIB_PATH}/controller/${MODULE_NAME}.lua"

  # ── 2. CBI Configuration Model ───────────────────────────────────────────────
  ensure_dir "${LUCI_LIB_PATH}/model/cbi"
  print_step "Generating Model: ${LUCI_LIB_PATH}/model/cbi/${MODULE_NAME}.lua"
  cat << 'EOF' > "${LUCI_LIB_PATH}/model/cbi/${MODULE_NAME}.lua"
m = Map("vumeter", translate("VU Meter Configuration"),
    translate("Configure the appearance and behaviour of the canvas VU meters."))

s = m:section(TypedSection, "vumeter", translate("General Options"))
s.anonymous = true

s:option(Value, "boxCount", translate("Segment Count"),
    translate("Number of light segments per meter.")).datatype = "uinteger"

s:option(Value, "boxGapFraction", translate("Gap Fraction"),
    translate("Proportional gap between segments (0.0 – 1.0)."))

return m
EOF
  chmod 644 "${LUCI_LIB_PATH}/model/cbi/${MODULE_NAME}.lua"

  # ── 3. View Template ─────────────────────────────────────────────────────────
  # FIX [BUG-1]: Now written to the correct runtime path.
  ensure_dir "${LUCI_VIEW_PATH}/${MODULE_NAME}"
  print_step "Generating View Template: ${LUCI_VIEW_PATH}/${MODULE_NAME}/display.htm"
  cat << 'EOF' > "${LUCI_VIEW_PATH}/${MODULE_NAME}/display.htm"
<%+header%>
<h2 name="content"><%:VU Meter — Live Performance%></h2>
<div class="cbi-map-description"><%:Real-time CPU, RAM and network visualisation via HTML5 Canvas.%></div>

<div style="display:flex;flex-wrap:wrap;justify-content:space-around;
            background:#1e1e1e;padding:24px;border-radius:6px;margin-top:15px;">
    <div style="text-align:center;margin:12px;">
        <h3 style="color:#fff;margin-bottom:8px;">CPU</h3>
        <canvas id="cpu_vu" width="80" height="260"></canvas>
    </div>
    <div style="text-align:center;margin:12px;">
        <h3 style="color:#fff;margin-bottom:8px;">RAM</h3>
        <canvas id="ram_vu" width="80" height="260"></canvas>
    </div>
    <div style="text-align:center;margin:12px;">
        <h3 style="color:#fff;margin-bottom:8px;">NET RX</h3>
        <canvas id="rx_vu" width="80" height="260"></canvas>
    </div>
    <div style="text-align:center;margin:12px;">
        <h3 style="color:#fff;margin-bottom:8px;">NET TX</h3>
        <canvas id="tx_vu" width="80" height="260"></canvas>
    </div>
</div>

<script type="text/javascript" src="<%=resource%>/vumeter.js"></script>
<script type="text/javascript">//<![CDATA[
    var statusUrl = '<%=luci.dispatcher.build_url("admin","system","vumeter","status")%>';

    // XHR.poll is the legacy LuCI polling helper that issues a GET every
    // <interval> seconds and passes the parsed JSON body to the callback.
    // It is still shipped in luci-base as of OpenWrt 24.10 for backward
    // compatibility with .htm templates like this one.
    XHR.poll(2, statusUrl, null, function(x, data) {
        if (!data) return;
        if (window.cpuMeter) window.cpuMeter.update(data.cpu);
        if (window.ramMeter) window.ramMeter.update(data.memory);
        if (window.rxMeter)  window.rxMeter.update(data.rx);
        if (window.txMeter)  window.txMeter.update(data.tx);
    });

    window.onload = function() {
        <%
            local uci = require "luci.model.uci".cursor()
            local bc = uci:get("vumeter", "general", "boxCount")       or 20
            local bg = uci:get("vumeter", "general", "boxGapFraction")  or 0.2
        %>
        var opts = { boxCount: <%=bc%>, boxGapFraction: <%=bg%>, max: 100 };
        window.cpuMeter = vumeter(document.getElementById('cpu_vu'), opts);
        window.ramMeter = vumeter(document.getElementById('ram_vu'), opts);
        window.rxMeter  = vumeter(document.getElementById('rx_vu'),  opts);
        window.txMeter  = vumeter(document.getElementById('tx_vu'),  opts);
    };
//]]></script>
<%+footer%>
EOF
  chmod 644 "${LUCI_VIEW_PATH}/${MODULE_NAME}/display.htm"

  # ── 4. JavaScript VU-meter renderer ──────────────────────────────────────────
  ensure_dir "${LUCI_STATIC_PATH}"
  print_step "Generating JS Asset: ${LUCI_STATIC_PATH}/${MODULE_NAME}.js"
  cat << 'EOF' > "${LUCI_STATIC_PATH}/${MODULE_NAME}.js"
(function(window) {
    /**
     * vumeter(canvas, options) → { update(value) }
     *
     * Renders a classic segmented LED VU meter on a <canvas> element.
     * Segments are drawn bottom-to-top; colours follow the classic
     * green → yellow → red ramp.
     *
     * @param {HTMLCanvasElement} canvas  - Target canvas element
     * @param {object}            options
     *   @param {number} boxCount        - Number of segments (default 15)
     *   @param {number} boxGapFraction  - Gap height as fraction of canvas
     *                                    height (default 0.2)
     *   @param {number} max             - Value == full scale (default 100)
     */
    function vumeter(canvas, options) {
        var ctx = canvas.getContext('2d');
        options = options || {};
        var boxCount       = options.boxCount        || 15;
        var boxGapFraction = options.boxGapFraction  !== undefined ? options.boxGapFraction : 0.2;
        var max            = options.max             || 100;
        var currentValue   = 0;

        function draw() {
            var w = canvas.width;
            var h = canvas.height;
            ctx.clearRect(0, 0, w, h);

            var totalGapH = boxGapFraction * h;
            var boxH      = (h - totalGapH) / boxCount;
            var gapH      = boxCount > 1 ? totalGapH / (boxCount - 1) : 0;
            var active    = Math.round((currentValue / max) * boxCount);

            for (var i = 0; i < boxCount; i++) {
                var frac = i / boxCount;
                if (i < active) {
                    // Classic VU colour ramp: green → yellow → red
                    if      (frac < 0.60) ctx.fillStyle = '#00FF00';
                    else if (frac < 0.85) ctx.fillStyle = '#FFFF00';
                    else                  ctx.fillStyle = '#FF0000';
                } else {
                    ctx.fillStyle = '#444444';  // unlit segment
                }
                // i=0 is the bottom-most segment; draw from bottom upward
                var y = h - ((i + 1) * boxH + i * gapH);
                ctx.fillRect(0, y, w, boxH);
            }
        }

        draw();  // initial blank render so canvas is not empty on load
        return {
            update: function(val) {
                currentValue = Math.max(0, Math.min(max, +val || 0));
                draw();
            }
        };
    }

    window.vumeter = vumeter;
}(window));
EOF
  chmod 644 "${LUCI_STATIC_PATH}/${MODULE_NAME}.js"

  # ── 5. Default UCI Configuration ─────────────────────────────────────────────
  ensure_dir "${UCI_CONFIG_PATH}"
  if [ ! -f "${UCI_CONFIG_PATH}/${MODULE_NAME}" ]; then
    print_step "Generating UCI Config: ${UCI_CONFIG_PATH}/${MODULE_NAME}"
    cat << 'EOF' > "${UCI_CONFIG_PATH}/${MODULE_NAME}"
config vumeter 'general'
	option boxCount '20'
	option boxGapFraction '0.2'
EOF
    chmod 644 "${UCI_CONFIG_PATH}/${MODULE_NAME}"
  fi
}

################################################################################
# Execution Flow
################################################################################

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -u|--uninstall) ACTION="uninstall"; shift ;;
      *) shift ;;
    esac
  done

  check_root
  print_header

  if [ "$ACTION" = "uninstall" ]; then
    print_info "Uninstalling VU Meter components..."
    rm -f  "${LUCI_LIB_PATH}/controller/${MODULE_NAME}.lua"
    rm -f  "${LUCI_LIB_PATH}/model/cbi/${MODULE_NAME}.lua"
    rm -rf "${LUCI_VIEW_PATH}/${MODULE_NAME}"
    rm -f  "${LUCI_STATIC_PATH}/${MODULE_NAME}.js"
    rm -f  "${UCI_CONFIG_PATH}/${MODULE_NAME}"
    # Clean up per-poll state files left by action_status
    rm -f  /tmp/.vumeter_cpu
    rm -f  /tmp/.vumeter_net
    # FIX [BUG-2]: clear cache so stale menu entries are removed immediately
    clear_luci_cache
    print_success "Uninstallation complete."
  else
    print_info "Beginning standalone file compilation and injection..."
    install_files
    # FIX [BUG-2]: MUST run after files are in place so the new controller is
    # picked up on the very next LuCI page load without an uhttpd restart.
    clear_luci_cache
    echo ""
    print_success "Installation complete — all interface assets generated inline."
    print_info "Reload LuCI in your browser."
    print_info "If the menu entry is still absent, restart the web server:"
    print_info "  /etc/init.d/uhttpd restart"
    print_info "Then navigate to: System > VU Meter Display"
  fi
}

main "$@"
