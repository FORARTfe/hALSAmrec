module("luci.controller.ALSA", package.seeall)

function index()
	-- Move menu to main bar (not under admin/services)
	entry({"admin", "ALSA"}, alias("admin", "ALSA", "devices"), _("Audio Devices"), 60).dependent = true
	entry({"admin", "ALSA", "devices"}, template("ALSA/devices"), _("Audio Devices"), 10)
	entry({"admin", "ALSA", "probe"}, call("action_probe"), nil).leaf = true
	entry({"admin", "ALSA", "service"}, call("action_service"), nil).leaf = true
end

function action_probe()
	local sys = require "luci.sys"
	
	-- Run arecord to probe audio interface parameters on hw:0,0
	local devices_data = {}
	local raw_output = ""
	
	local fp = io.popen("arecord --dump-hw-params -D hw:0,0 2>&1")
	if fp then
		raw_output = fp:read("*all") or ""
		fp:close()
		
		-- Parse the output line by line
		for line in raw_output:gmatch("[^\r\n]+") do
			table.insert(devices_data, line)
		end
	end
	
	luci.http.prepare_content("application/json")
	luci.http.write_json({
		raw = raw_output,
		devices = devices_data
	})
end

function action_service()
	local http = require "luci.http"
	local sys = require "luci.sys"
	
	local action = http.getarg("action") or ""
	local result = {}
	
	-- Whitelist valid actions
	local valid_actions = {start=1, stop=1, status=1}
	if not valid_actions[action] then
		luci.http.status(400, "Bad Request")
		luci.http.write_json({error = "Invalid action"})
		return
	end
	
	if action == "start" then
		sys.call("/etc/init.d/autorecorder start >/dev/null 2>&1")
		sys.call("sleep 1")
		if sys.call("pgrep -f '/usr/sbin/recorder' >/dev/null 2>&1") == 0 then
			result.status = "running"
			result.message = "Started successfully"
		else
			result.status = "stopped"
			result.message = "Failed to start"
		end
		
	elseif action == "stop" then
		sys.call("/etc/init.d/autorecorder stop >/dev/null 2>&1")
		sys.call("sleep 1")
		if sys.call("pgrep -f '/usr/sbin/recorder' >/dev/null 2>&1") == 0 then
			result.status = "running"
			result.message = "Failed to stop"
		else
			result.status = "stopped"
			result.message = "Stopped successfully"
		end
		
	elseif action == "status" then
		if sys.call("pgrep -f '/usr/sbin/recorder' >/dev/null 2>&1") == 0 then
			result.status = "running"
		else
			result.status = "stopped"
		end
	end
	
	luci.http.prepare_content("application/json")
	luci.http.write_json(result)
end
