module("luci.controller.halsamrec", package.seeall)

function index()
	local page  = entry({"admin", "services", "halsamrec"}, alias("admin", "services", "halsamrec", "devices"), _("Audio Devices"), 10)
	page.dependent = true
	entry({"admin", "services", "halsamrec", "devices"}, template("halsamrec/devices"), _("Audio Devices"), 10)
	entry({"admin", "services", "halsamrec", "status"}, call("action_status"), nil).leaf = true
	entry({"admin", "services", "halsamrec", "start"}, call("action_recorder_start"), nil).leaf = true
	entry({"admin", "services", "halsamrec", "stop"}, call("action_recorder_stop"), nil).leaf = true
end

-- Query status: is recorder running? PID? arecord results? (or warning if recorder is running)
function action_status()
	local sys = require "luci.sys"
	local http = require "luci.http"
	-- 1. Recorder status
	local pid = sys.exec("pgrep -f '/usr/sbin/recorder' | head -n1 | tr -d '\n'")
	local running = (pid ~= nil and pid ~= "")

	local arecord_output = ""
	local arecord_error = nil
	if running then
		arecord_output = "WARNING: recorder is running, stop to probe!"
		arecord_error = true
	else
		-- Only allow our hardcoded query
		-- Don't allow user override!
		local fp = io.popen("arecord --dump-hw-params -D hw:0,0 2>&1")
		if fp then
			arecord_output = fp:read("*all") or ""
			fp:close()
		else
			arecord_output = "Failed to run arecord"
			arecord_error = true
		end
	end

	http.prepare_content("application/json")
	http.write_json({
		recorder = {
			running = running,
			pid = running and pid or nil,
		},
		arecord = {
			raw = arecord_output,
			error = arecord_error or false
		}
	})
end

-- Start recorder
function action_recorder_start()
	local sys = require "luci.sys"
	local http = require "luci.http"
	local ok = false
	local msg = ""
	if sys.exec("pgrep -f '/usr/sbin/recorder' | head -n1 | tr -d '\n'") ~= "" then
		ok = true
		msg = "Already running"
	else
		local rc = sys.call("/etc/init.d/autorecorder start >/dev/null 2>&1")
		luci.sys.exec("sleep 2")  -- Wait a short moment
		if sys.exec("pgrep -f '/usr/sbin/recorder' | head -n1 | tr -d '\n'") ~= "" then
			ok = true
			msg = "Started successfully"
		else
			msg = "Failed to start"
		end
	end
	http.prepare_content("application/json")
	http.write_json({ success = ok, message = msg })
end

-- Stop recorder
function action_recorder_stop()
	local sys = require "luci.sys"
	local http = require "luci.http"
	local ok = false
	local msg = ""
	if sys.exec("pgrep -f '/usr/sbin/recorder' | head -n1 | tr -d '\n'") == "" then
		ok = true
		msg = "Already stopped"
	else
		local rc = sys.call("/etc/init.d/autorecorder stop >/dev/null 2>&1")
		luci.sys.exec("sleep 2")
		if sys.exec("pgrep -f '/usr/sbin/recorder' | head -n1 | tr -d '\n'") == "" then
			ok = true
			msg = "Stopped successfully"
		else
			msg = "Failed to stop"
		end
	end
	http.prepare_content("application/json")
	http.write_json({ success = ok, message = msg })
end
