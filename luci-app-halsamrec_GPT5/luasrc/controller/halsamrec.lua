module("luci.controller.halsamrec", package.seeall)

local http = require "luci.http"
local sys = require "luci.sys"

local RECORDER_INIT = "/etc/init.d/autorecorder"
local RECORDER_MATCH = "/usr/sbin/recorder"
local PROBE_DEVICE = "hw:0,0"

local function split_lines(text)
	local lines = {}

	for line in (text or ""):gmatch("[^\r\n]+") do
		lines[#lines + 1] = line
	end

	return lines
end

local function recorder_running()
	return sys.call("pgrep -f '" .. RECORDER_MATCH .. "' >/dev/null 2>&1") == 0
end

local function service_status()
	return recorder_running() and "running" or "stopped"
end

local function write_json(data, status_code, status_message)
	if status_code then
		http.status(status_code, status_message or "")
	end

	http.prepare_content("application/json")
	http.write_json(data or {})
end

function index()
	local page = entry({"admin", "halsamrec"}, alias("admin", "halsamrec", "devices"), _("Audio Devices"), 60)
	page.dependent = true

	entry({"admin", "halsamrec", "devices"}, template("halsamrec/devices"), _("Audio Devices"), 10)
	entry({"admin", "halsamrec", "probe"}, call("action_probe")).leaf = true
	entry({"admin", "halsamrec", "service"}, call("action_service")).leaf = true
end

function action_probe()
	local fp = io.popen("arecord --dump-hw-params -D " .. PROBE_DEVICE .. " 2>&1")
	local raw_output = fp and (fp:read("*all") or "") or ""

	if fp then
		fp:close()
	end

	write_json({
		raw = raw_output,
		devices = split_lines(raw_output)
	})
end

function action_service()
	local action = http.getarg("action") or ""

	if action == "status" then
		return write_json({ status = service_status() })
	end

	if action ~= "start" and action ~= "stop" then
		return write_json({ error = "Invalid action" }, 400, "Bad Request")
	end

	sys.call(RECORDER_INIT .. " " .. action .. " >/dev/null 2>&1")
	sys.call("sleep 1")

	local status = service_status()
	local success = (action == "start" and status == "running")
		or (action == "stop" and status == "stopped")

	write_json({
		status = status,
		message = success
			and (action == "start" and "Started successfully" or "Stopped successfully")
			or (action == "start" and "Failed to start" or "Failed to stop")
	})
end
