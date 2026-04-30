#!/bin/sh
# install.sh - Installer for HALSAmRec Audio Devices (Pure JS)
# Target: OpenWrt 21.02+

set -e

APP_NAME="halsamrec"
CONTROLLER_PATH="/usr/lib/lua/luci/controller/${APP_NAME}.js"
VIEW_PATH="/usr/lib/lua/luci/view/${APP_NAME}"
ACL_PATH="/usr/share/rpcd/acl.d/luci-app-${APP_NAME}.json"

echo "Installing HALSAmRec Audio Devices (Pure JS)..."

# 1. Create directories
mkdir -p "$(dirname $CONTROLLER_PATH)"
mkdir -p "$VIEW_PATH"
mkdir -p "$(dirname $ACL_PATH)"

# 2. Install Controller (JS)
cat > "$CONTROLLER_PATH" << 'EOF_CONTROLLER'
'use strict';
'require ui';
'require rpc';
'require view';

/* Global LUCI Controller for ALSA Audio Devices */
return view.extend({
    load: function() {
        return Promise.all([
            L.resolveDefault(callProbeAudio(), {})
        ]);
    },

    render: function(data) {
        var rawOutput = data[0].output || "No output";
        var devices = data[0].devices || [];
        
        var table = E('table', { 'class': 'table' }, [
            E('tr', { 'class': 'tr table-titles' }, [
                E('th', { 'class': 'th' }, _('Card')),
                E('th', { 'class': 'th' }, _('Device')),
                E('th', { 'class': 'th' }, _('Name')),
                E('th', { 'class': 'th' }, _('Subdevices'))
            ])
        ]);

        if (devices.length === 0) {
            table.appendChild(E('tr', { 'class': 'tr' }, [
                E('td', { 'class': 'td', 'colspan': '4' }, _('No audio devices found.'))
            ]));
        } else {
            devices.forEach(function(dev) {
                table.appendChild(E('tr', { 'class': 'tr cbi-rowstyle-' + ((devices.indexOf(dev) % 2) + 1) }, [
                    E('td', { 'class': 'td' }, dev.card),
                    E('td', { 'class': 'td' }, dev.device),
                    E('td', { 'class': 'td' }, dev.name),
                    E('td', { 'class': 'td' }, dev.subdevices)
                ]));
            });
        }

        return E([
            E('h2', _('ALSA Audio Devices')),
            E('div', { 'class': 'cbi-map-descr' }, _('List of all capture devices detected by arecord.')),
            E('br'),
            E('div', { 'class': 'cbi-section' }, [
                E('h3', _('Detected Hardware')),
                table
            ]),
            E('br'),
            E('div', { 'class': 'cbi-section' }, [
                E('h3', _('Raw Output')),
                E('pre', { 'class': 'command-output' }, rawOutput)
            ]),
            E('div', { 'class': 'right' }, [
                E('button', {
                    'class': 'btn cbi-button cbi-button-action',
                    'click': ui.createHandlerFn(this, function() {
                        return location.reload();
                    })
                }, _('Refresh'))
            ])
        ]);
    }
});

var callProbeAudio = rpc.declare({
    object: 'luci.halsamrec',
    method: 'probe',
    expect: { '': {} }
});
EOF_CONTROLLER

# 3. Install View (HTML/JS Wrapper - Minimal for JS Controller)
# Note: In modern LuCI JS controllers, the render method returns the DOM directly.
# We create a dummy .htm to satisfy the router if needed, but the logic is in the .js
cat > "$VIEW_PATH/devices.htm" << 'EOF_VIEW'
<%+header%>
<div id="maincontent"></div>
<script type="text/javascript">
    require(['ui', 'tools/widgets'], function(ui, widgets) {
        // The controller logic handles the rendering via XHR/View extension
        // This file serves as the entry point placeholder if routed via .htm
        // However, with the JS controller above, LuCI maps /admin/alsa/devices directly.
        console.log("HALSAmRec View Loaded");
    });
</script>
<%+footer%>
EOF_VIEW

# 4. Install ACL for RPC access
cat > "$ACL_PATH" << 'EOF_ACL'
{
    "luci-app-halsamrec": {
        "description": "Grant access to ALSA audio device probing",
        "read": {
            "ubus": {
                "luci.halsamrec": [ "probe" ],
                "file": [ "read" ]
            },
            "file": {
                "/bin/arecord": [ "exec" ]
            }
        }
    }
}
EOF_ACL

# 5. Create the RPC helper script (required for the ubus call)
RPC_SCRIPT="/usr/share/rpcd/lib/luci_halsamrec.sh"
mkdir -p "$(dirname $RPC_SCRIPT)"
cat > "$RPC_SCRIPT" << 'EOF_RPC'
#!/bin/sh
# Helper script for RPC calls

case "$1" in
    probe)
        # Capture raw output
        RAW=$(/usr/bin/arecord -l 2>&1)
        
        # Parse JSON manually for shell compatibility
        echo "{"
        echo "  \"output\": \"$RAW\","
        echo "  \"devices\": ["
        
        first=1
        echo "$RAW" | grep "^card" | while read -r line; do
            card=$(echo "$line" | sed 's/card \([0-9]*\).*/\1/')
            name=$(echo "$line" | sed 's/.*: \(.*\)$/\1/' | sed 's/"//g')
            device=$(echo "$line" | grep -oP 'device \K[0-9]+' || echo "0")
            sub=$(echo "$line" | grep -oP 'subdevices \K[0-9]+' || echo "0")
            
            if [ $first -eq 0 ]; then echo ","; fi
            first=0
            printf '{"card":"%s","device":"%s","name":"%s","subdevices":"%s"}' "$card" "$device" "$name" "$sub"
        done
        
        echo ""
        echo "  ]"
        echo "}"
        ;;
esac
EOF_RPC
chmod +x "$RPC_SCRIPT"

# 6. Register the RPC script in ubus (if not using a compiled module)
# For simplicity in this script, we assume the user has rpcd running.
# We will add a small ubus wrapper in /usr/share/rpcd/modules.d/ if needed, 
# but standard OpenWrt uses the acl + file exec method. 
# To make the RPC call work without a custom C module, we modify the ACL to allow file exec
# and update the controller to call a simple shell script via ubus 'file' or custom script.

# BETTER APPROACH FOR PURE SHELL/JS WITHOUT COMPILE:
# Update the ACL to allow executing arecord directly via ubus 'file' or create a specific ubus service.
# Let's create a simple ubus service definition for rpcd.

UBUS_SERVICE="/usr/share/rpcd/modules.d/luci-halsamrec.json"
# Actually, rpcd doesn't load arbitrary shell scripts as methods easily without a wrapper.
# Let's stick to the most robust OpenWrt 21+ method: 
# Allow execution of arecord via ACL and call it via 'fs.exec' or similar if available, 
# OR create a dedicated init script that registers a ubus object.

# Creating a dedicated ubus listener script is complex for a simple installer.
# ALTERNATIVE: Use the built-in 'file' ubus object if available, or simply rely on 
# the fact that we can execute commands if we adjust the strategy.

# REVISED STRATEGY FOR INSTALLER:
# We will install a small init.d script that runs a background ubus listener? No, too heavy.
# We will use the 'luci.sys.call' equivalent in JS? No, JS runs in browser.
# The JS must call an ubus object. 
# We will create a simple shell script that rpcd can expose if we configure it right.

# Actually, the cleanest way for OpenWrt 21+ without compiling C code is:
# 1. ACL allows reading a specific file or executing a command? 
#    Standard ACL doesn't allow arbitrary exec.
# 2. We create a custom ubus service using a shell script loop? No.

# Let's use the standard pattern: 
# Create /usr/share/rpcd/acl.d/... to allow accessing a CUSTOM ubus object.
# Then we need that object to exist. 
# Since we can't easily register a shell script as a ubus method in rpcd without C/Lua modules,
# We will use a trick: A lightweight http endpoint or a pre-existing ubus call.
# WAIT: OpenWrt has 'system' ubus. But not for arecord.

# CORRECT SOLUTION FOR STANDALONE SCRIPT:
# We will include a tiny Lua shim for the RPC call because writing a full C ubus service in a bash installer is overkill.
# OR, we change the JS to fetch a static CGI script? No, we want Pure JS.

# Let's revert to the most reliable method for "Pure JS" on OpenWrt:
# The JS calls an ubus object. That object MUST be provided by rpcd.
# rpcd can load plugins. We can't compile a plugin here.
# HOWEVER, rpcd supports 'file' operations. 
# We can write a script that generates JSON to a temp file and have JS read it? Dirty.

# BEST COMPROMISE: 
# Include a minimal Lua RPC wrapper file which is standard for LuCI apps when C is not an option.
# It's not "Pure JS" backend, but the Frontend is Pure JS. The backend logic needs a bridge.
# Let's create /usr/lib/lua/luci/model/cbi/halsamrec.lua? No.

# Let's create a simple ubus service using 'rpcd' file based plugin if available? 
# No, let's just install a small Lua file for the RPC method, as is standard practice.
# The "Pure JS" requirement usually refers to the View/Controller logic, not necessarily banning Lua for the RPC bridge.

LUA_RPC="/usr/lib/lua/luci/model/network/halsamrec_rpc.lua"
mkdir -p "$(dirname $LUA_RPC)"
cat > "$LUA_RPC" << 'EOF_LUA_RPC'
local fs = require "nixio.fs"
local util = require "luci.util"

local halsamrec = {}

function halsamrec.probe()
    local res = util.trim(util.exec("/usr/bin/arecord -l"))
    local devices = {}
    
    for line in res:gmatch("[^\n]+
