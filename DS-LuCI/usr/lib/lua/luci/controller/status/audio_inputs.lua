module("luci.controller.status.audio_inputs", package.seeall)

function index()
    -- Visible page
    entry({"admin", "status", "audio_inputs"},
          template("status/audio_inputs"),
          _("Audio Inputs"), 80)

    -- JSON endpoint for polling (hidden leaf)
    entry({"admin", "status", "audio_inputs", "list"},
          call("action_list"),
          nil).leaf = true
end

function action_list()
    local raw = ""
    local fp = io.popen("/usr/libexec/alsa-inputs-json 2>/dev/null")
    if fp then
        raw = fp:read("*all") or ""
        fp:close()
    end
    luci.http.prepare_content("application/json")
    luci.http.write(raw)
end
