module("luci.controller.status.audio_inputs", package.seeall)

function index()
    entry({"admin", "status", "audio_inputs"},
        template("status/audio_inputs"),
        _("Audio Inputs"), 80)

    entry({"admin", "status", "audio_inputs", "list"},
        call("action_list"), nil).leaf = true
end

function action_list()
    local fp  = io.popen("/usr/libexec/alsa-inputs-json 2>/dev/null")
    local raw = fp and fp:read("*all") or "[]"
    if fp then fp:close() end
    luci.http.prepare_content("application/json")
    luci.http.write(raw ~= "" and raw or "[]")
end
