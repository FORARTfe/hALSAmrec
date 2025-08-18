#!/bin/sh
# /usr/lib/lua/luci/controller/recorder.lua - Web interface for recorder control

module("luci.controller.recorder", package.seeall)

function index()
    entry({"admin", "services", "recorder"}, call("recorder_index"), _("Recorder Control"), 99)
    entry({"admin", "services", "recorder", "action"}, call("recorder_action"))
    entry({"cm"}, call("command_interface"))
end

function recorder_index()
    local status = get_recorder_status()
    luci.template.render("recorder/index", {status = status})
end

function recorder_action()
    local action = luci.http.formvalue("action")
    local result = ""
    
    if action == "start" then
        result = start_recorder()
    elseif action == "stop" then
        result = stop_recorder()
    elseif action == "status" then
        result = get_recorder_status()
    end
    
    luci.http.prepare_content("application/json")
    luci.http.write_json({result = result, status = get_recorder_status()})
end

function command_interface()
    local cmd = luci.http.formvalue("cmnd")
    local result = "Unknown command"
    
    if cmd == "Power ON" or cmd == "Power%20ON" then
        result = start_recorder()
    elseif cmd == "Power OFF" or cmd == "Power%20OFF" then
        result = stop_recorder()
    elseif cmd == "Status" then
        result = get_recorder_status()
    end
    
    luci.http.prepare_content("text/plain")
    luci.http.write(result)
end

function get_recorder_status()
    local handle = io.popen("pgrep -f '/usr/sbin/recorder' 2>/dev/null")
    local pid = handle:read("*a")
    handle:close()
    
    if pid and pid ~= "" then
        return "RUNNING (PID: " .. string.gsub(pid, "\n", "") .. ")"
    else
        return "STOPPED"
    end
end

function start_recorder()
    local status = get_recorder_status()
    if string.match(status, "RUNNING") then
        return "Already running"
    end
    
    os.execute("/etc/init.d/autorecorder start >/dev/null 2>&1")
    -- Wait a moment for the service to start
    os.execute("sleep 2")
    
    local new_status = get_recorder_status()
    if string.match(new_status, "RUNNING") then
        return "Started successfully"
    else
        return "Failed to start"
    end
end

function stop_recorder()
    local status = get_recorder_status()
    if string.match(status, "STOPPED") then
        return "Already stopped"
    end
    
    os.execute("/etc/init.d/autorecorder stop >/dev/null 2>&1")
    -- Wait a moment for the service to stop
    os.execute("sleep 2")
    
    local new_status = get_recorder_status()
    if string.match(new_status, "STOPPED") then
        return "Stopped successfully"
    else
        return "Failed to stop"
    end
end
