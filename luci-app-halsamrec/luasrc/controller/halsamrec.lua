module("luci.controller.halsamrec", package.seeall)

function index()
	entry({"admin", "services", "halsamrec"}, alias("admin", "services", "halsamrec", "devices"), _("HALSAmRec Audio Devices"), 10).dependent = true
	entry({"admin", "services", "halsamrec", "devices"}, template("halsamrec/devices"), _("Audio Devices"), 10)
	entry({"admin", "services", "halsamrec", "probe"}, call("action_probe"), nil).leaf = true
end

function action_probe()
	local sys = require "luci.sys"
	local uci = require "luci.model.uci".cursor()
	
	-- Run arecord -l and capture all output
	local devices_data = {}
	local fp = io.popen("arecord -l 2>&1")
	if fp then
		local raw_output = fp:read("*all")
		fp:close()
		
		-- Parse the output line by line
		for line in raw_output:gmatch("[^\r\n]+") do
			table.insert(devices_data, line)
		end
	end
	
	luci.http.prepare_content("application/json")
	luci.http.write_json({
		raw = raw_output or "",
		devices = devices_data
	})
end
