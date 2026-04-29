module("luci.controller.status.audio_inputs", package.seeall)

-- Adjust these two constants to match your recorder setup
local RECORDER_PROC = "/usr/sbin/recorder"
local RECORDER_INIT = "/etc/init.d/autorecorder"

function index()
    entry({"admin", "status", "audio_inputs"},
        template("status/audio_inputs"),
        _("Audio Inputs"), 80)

    entry({"admin", "status", "audio_inputs", "list"},
        call("action_list"), nil).leaf = true

    entry({"admin", "status", "audio_inputs", "probe"},
        call("action_probe"), nil).leaf = true

    entry({"admin", "status", "audio_inputs", "service"},
        call("action_service"), nil).leaf = true
end

-- ── helpers ──────────────────────────────────────────────────────────────────

local function is_running()
    return require("luci.sys").call(
        "pgrep -f '" .. RECORDER_PROC .. "' >/dev/null 2>&1") == 0
end

-- ── endpoints ─────────────────────────────────────────────────────────────────

function action_list()
    local fp  = io.popen("/usr/libexec/alsa-inputs-json 2>/dev/null")
    local raw = fp and fp:read("*all") or "[]"
    if fp then fp:close() end
    luci.http.prepare_content("application/json")
    luci.http.write(raw ~= "" and raw or "[]")
end

function action_probe()
    local fp  = io.popen("arecord --dump-hw-params -D hw:0,0 2>&1")
    local raw = fp and fp:read("*all") or ""
    if fp then fp:close() end
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
