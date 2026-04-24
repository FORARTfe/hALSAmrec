module("luci.controller.halsamrec", package.seeall)

local RECORDER_PROC = "/usr/sbin/recorder"
local RECORDER_INIT = "/etc/init.d/autorecorder"

function index()
    -- Top-level "ALSA" menu entry in the admin bar
    entry({"admin", "alsa"},
        alias("admin", "alsa", "devices"),
        _("ALSA"), 40)

    -- "Audio Devices" page directly under ALSA
    entry({"admin", "alsa", "devices"},
        template("halsamrec/devices"),
        _("Audio Devices"), 10)

    -- JSON endpoints — leaf nodes, not visible in menu
    entry({"admin", "alsa", "probe"},
        call("action_probe"), nil).leaf = true
    entry({"admin", "alsa", "service"},
        call("action_service"), nil).leaf = true
end

local function is_running()
    return require("luci.sys").call(
        "pgrep -f '" .. RECORDER_PROC .. "' >/dev/null 2>&1") == 0
end

function action_probe()
    local raw = ""
    local fp = io.popen("arecord --dump-hw-params -D hw:0,0 2>&1")
    if fp then
        raw = fp:read("*all") or ""
        fp:close()
    end
    luci.http.prepare_content("application/json")
    luci.http.write_json({ raw = raw })
end

function action_service()
    local http   = require "luci.http"
    local sys    = require "luci.sys"
    local action = http.getarg("action") or ""
    local valid  = { start = true, stop = true, status = true }

    if not valid[action] then
        luci.http.status(400, "Bad Request")
        luci.http.write_json({ error = "Invalid action" })
        return
    end

    local result = {}

    if action == "status" then
        result.status = is_running() and "running" or "stopped"
    else
        sys.call(RECORDER_INIT .. " " .. action .. " >/dev/null 2>&1")
        sys.call("sleep 1")
        local running = is_running()
        result.status  = running and "running" or "stopped"
        if action == "start" then
            result.message = running and "Started successfully" or "Failed to start"
        else
            result.message = running and "Failed to stop" or "Stopped successfully"
        end
    end

    luci.http.prepare_content("application/json")
    luci.http.write_json(result)
end
