#!/bin/sh
#
# ALSA Audio Inputs LuCI App Installer for OpenWrt
# 
# This script installs a LuCI status page that displays
# live ALSA capture devices with real-time polling.
#
# Usage:
#   chmod +x install.sh
#   ./install.sh [target_ip] [--uninstall]
#
# Examples:
#   ./install.sh 192.168.1.1          # Install to router at 192.168.1.1
#   ./install.sh root@192.168.1.1     # Install with username
#   ./install.sh 192.168.1.1 --uninstall  # Remove installation

set -e

# Configuration
SCRIPT_NAME="alsa-inputs-json"
CONTROLLER_NAME="audio_inputs.lua"
TEMPLATE_NAME="audio_inputs.htm"
MENU_NAME="luci-app-audio-inputs.json"

# Paths on the target router
LIBEXEC_DIR="/usr/libexec"
CONTROLLER_DIR="/usr/lib/lua/luci/controller/status"
TEMPLATE_DIR="/usr/lib/lua/luci/view/status"
MENU_DIR="/usr/share/luci/menu.d"
CACHE_DIR="/tmp"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

usage() {
    cat <<EOF
${GREEN}ALSA Audio Inputs LuCI App Installer${NC}

Usage: $0 <target> [--uninstall]

Arguments:
  target        Router address (e.g., 192.168.1.1 or root@192.168.1.1)
  --uninstall   Remove previously installed files

Examples:
  $0 192.168.1.1                    # Install
  $0 root@192.168.1.1               # Install with explicit user
  $0 192.168.1.1 --uninstall        # Remove

Requirements:
  - SSH access to the target router
  - alsa-utils package installed on target (opkg install alsa-utils)
  - LuCI web interface running on target
EOF
    exit 1
}

# Parse arguments
TARGET=""
UNINSTALL=0

for arg in "$@"; do
    case "$arg" in
        --uninstall)
            UNINSTALL=1
            ;;
        *)
            if [ -z "$TARGET" ]; then
                TARGET="$arg"
            else
                echo "${RED}Error: Unexpected argument: $arg${NC}"
                usage
            fi
            ;;
    esac
done

if [ -z "$TARGET" ]; then
    echo "${RED}Error: Target not specified${NC}"
    usage
fi

# Test SSH connectivity
echo "${YELLOW}Testing SSH connection to $TARGET...${NC}"
if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$TARGET" "echo SSH_OK" 2>/dev/null; then
    echo "${RED}Error: Cannot connect to $TARGET via SSH${NC}"
    echo "       Please ensure:"
    echo "       - SSH is enabled on the router"
    echo "       - You have key-based authentication or password prompt works"
    echo "       - The IP address is correct"
    exit 1
fi
echo "${GREEN}SSH connection OK${NC}"

# Remote command helper
remote_exec() {
    ssh "$TARGET" "$@" 2>/dev/null
}

remote_cp() {
    scp "$1" "$TARGET:$2" 2>/dev/null
}

# -------------------------------------------------------------------
# UNINSTALL
# -------------------------------------------------------------------
if [ $UNINSTALL -eq 1 ]; then
    echo "${YELLOW}Removing ALSA Audio Inputs LuCI app...${NC}"
    
    FILES_TO_REMOVE="
        $LIBEXEC_DIR/$SCRIPT_NAME
        $CONTROLLER_DIR/$CONTROLLER_NAME
        $TEMPLATE_DIR/$TEMPLATE_NAME
        $MENU_DIR/$MENU_NAME
    "
    
    for file in $FILES_TO_REMOVE; do
        echo "  Checking $file..."
        if remote_exec "[ -f '$file' ] && rm -f '$file' && echo 'removed' || echo 'not found'"; then
            echo "  ${GREEN}✓ Remote file $file removed${NC}"
        else
            echo "  ${YELLOW}- File $file not found (already removed)${NC}"
        fi
    done
    
    # Clear LuCI cache
    echo "${YELLOW}Clearing LuCI cache...${NC}"
    if remote_exec "rm -f $CACHE_DIR/luci-indexcache $CACHE_DIR/luci-modulecache"; then
        echo "${GREEN}✓ LuCI cache cleared${NC}"
    else
        echo "${RED}✗ Failed to clear cache (may require manual restart)${NC}"
    fi
    
    # Restart uhttpd
    echo "${YELLOW}Restarting uhttpd...${NC}"
    if remote_exec "/etc/init.d/uhttpd restart 2>/dev/null || service uhttpd restart 2>/dev/null || echo 'failed'"; then
        echo "${GREEN}✓ uhttpd restarted${NC}"
    else
        echo "${YELLOW}⚠ Could not restart uhttpd (please restart manually)${NC}"
    fi
    
    echo ""
    echo "${GREEN}Uninstall complete.${NC}"
    echo "You may need to reload the LuCI page in your browser."
    exit 0
fi

# -------------------------------------------------------------------
# INSTALL
# -------------------------------------------------------------------
echo ""
echo "${GREEN}========================================${NC}"
echo "${GREEN}ALSA Audio Inputs LuCI App Installer${NC}"
echo "${GREEN}========================================${NC}"
echo ""

# Check for alsa-utils on target
echo "${YELLOW}Checking for alsa-utils on target...${NC}"
if remote_exec "which arecord >/dev/null 2>&1 && echo 'found' || echo 'missing'"; then
    echo "${GREEN}✓ alsa-utils is installed${NC}"
else
    echo "${YELLOW}⚠ alsa-utils not found. Installing...${NC}"
    if remote_exec "opkg update && opkg install alsa-utils"; then
        echo "${GREEN}✓ alsa-utils installed${NC}"
    else
        echo "${RED}✗ Failed to install alsa-utils. Please install manually:${NC}"
        echo "       ssh $TARGET 'opkg install alsa-utils'"
        exit 1
    fi
fi

# Create temporary directory for file generation
TEMP_DIR=$(mktemp -d /tmp/alsa-inputs-installer.XXXXXX)
trap "rm -rf $TEMP_DIR" EXIT

echo "${YELLOW}Generating files...${NC}"

# -------------------------------------------------------------------
# Generate backend script
# -------------------------------------------------------------------
cat > "$TEMP_DIR/$SCRIPT_NAME" << 'SCRIPT_EOF'
#!/bin/sh
# ALSA input devices - strict JSON array for LuCI
# Requires: /proc/asound, arecord (optional)
# Output: [{"card":0,"device":0,"name":"...","hw_id":"hw:0,0","capture":true},...]

set -e

if [ -x /usr/bin/arecord ] && arecord -l 2>/dev/null | grep -q 'List of CAPTURE'; then
    arecord -l 2>/dev/null | awk '
    BEGIN {
        print "["
        first = 1
    }
    /^card [0-9]+:/ {
        if (match($0, /^card ([0-9]+): (.+?) \[([^\]]+)\], device ([0-9]+): (.+?) \[([^\]]+)\]/, m)) {
            card_num = m[1]
            dev_name = m[6]
            hw_id    = "hw:" card_num "," m[4]

            gsub(/\\/, "\\\\", dev_name)
            gsub(/"/, "\\\"", dev_name)
            gsub(/\n/, "\\n", dev_name)

            if (!first) printf ",\n"
            first = 0
            printf "  {\"card\": %d, \"device\": %d, \"name\": \"%s\", \"hw_id\": \"%s\", \"capture\": true}",
                card_num, m[4], dev_name, hw_id
        }
    }
    END { print "\n]" }
    '
else
    if [ ! -d /proc/asound ]; then
        echo "[]"
        exit 0
    fi

    awk '
    BEGIN {
        while ((getline < "/proc/asound/cards") > 0) {
            if (match($0, /^ *([0-9]+) \[.*\] *: .* - (.*)/, arr)) {
                card_num = arr[1]
                name = arr[2]
                gsub(/^ +| +$/, "", name)
                cards[card_num] = name
            }
        }
        close("/proc/asound/cards")

        print "["
        first = 1
        while ((getline < "/proc/asound/devices") > 0) {
            if ($0 ~ /capture/) {
                if (match($0, /^ *[0-9]+: \[ *([0-9]+)- *([0-9]+)\]/, arr)) {
                    c = arr[1]
                    d = arr[2]
                    name = (c in cards) ? cards[c] : "Unknown"
                    hw_id = "hw:" c "," d

                    gsub(/\\/, "\\\\", name); gsub(/"/, "\\\"", name)
                    if (!first) printf ",\n"
                    first = 0
                    printf "  {\"card\": %d, \"device\": %d, \"name\": \"%s\", \"hw_id\": \"%s\", \"capture\": true}",
                        c, d, name, hw_id
                }
            }
        }
        close("/proc/asound/devices")
        print "\n]"
    }'
fi
SCRIPT_EOF

chmod 755 "$TEMP_DIR/$SCRIPT_NAME"
echo "  ${GREEN}✓ Backend script generated${NC}"

# -------------------------------------------------------------------
# Generate controller
# -------------------------------------------------------------------
cat > "$TEMP_DIR/$CONTROLLER_NAME" << 'CONTROLLER_EOF'
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
CONTROLLER_EOF

echo "  ${GREEN}✓ Controller generated${NC}"

# -------------------------------------------------------------------
# Generate template
# -------------------------------------------------------------------
cat > "$TEMP_DIR/$TEMPLATE_NAME" << 'TEMPLATE_EOF'
<%# ALSA Audio Inputs - Live Capture Device List -%>
<%+header%>

<h2><%:Audio Inputs%></h2>
<p><%:Live list of all detected ALSA capture devices. Updates automatically every 1.5 seconds.%></p>

<table id="devtable" border="1" style="width:100%; border-collapse:collapse; margin-top:1em;">
  <thead>
    <tr style="background-color:#f0f0f0;">
      <th style="padding:8px;"><%:Card%></th>
      <th style="padding:8px;"><%:Device%></th>
      <th style="padding:8px;"><%:Name%></th>
      <th style="padding:8px;"><%:Hardware ID%></th>
      <th style="padding:8px;"><%:Capture%></th>
    </tr>
  </thead>
  <tbody>
    <tr><td colspan="5" style="padding:8px; text-align:center;"><em><%:Loading...%></em></td></tr>
  </tbody>
</table>

<script>
(function() {
  'use strict';
  var tbody = document.querySelector('#devtable tbody');

  function fetchDevices() {
    fetch('<%=luci.dispatcher.build_url("admin/status/audio_inputs/list")%>')
      .then(function(r) {
        if (!r.ok) throw new Error('Bad response');
        return r.json();
      })
      .then(function(devices) {
        if (!Array.isArray(devices) || devices.length === 0) {
          tbody.innerHTML = '<tr><td colspan="5" style="padding:8px; text-align:center;"><%:No audio input devices found.%></td></tr>';
          return;
        }
        var rows = devices.map(function(d) {
          return '<tr>' +
            '<td style="padding:8px;">' + d.card + '</td>' +
            '<td style="padding:8px;">' + d.device + '</td>' +
            '<td style="padding:8px;">' + luci_eschtml(d.name) + '</td>' +
            '<td style="padding:8px;">' + luci_eschtml(d.hw_id) + '</td>' +
            '<td style="padding:8px;">' + (d.capture ? '<%:Yes%>' : '<%:No%>') + '</td>' +
            '</tr>';
        });
        tbody.innerHTML = rows.join('');
      })
      .catch(function() {
        tbody.innerHTML = '<tr><td colspan="5" style="padding:8px; text-align:center; color:red;"><%:Error fetching device list. Check browser console for details.%></td></tr>';
      });
  }

  // Helper: escape HTML entities
  function luci_eschtml(s) {
    var d = document.createElement('div');
    d.appendChild(document.createTextNode(s));
    return d.innerHTML;
  }

  // Initial fetch
  fetchDevices();
  
  // Poll every 1.5 seconds
  setInterval(fetchDevices, 1500);
})();
</script>

<%+footer%>
TEMPLATE_EOF

echo "  ${GREEN}✓ Template generated${NC}"

# -------------------------------------------------------------------
# Generate menu JSON
# -------------------------------------------------------------------
cat > "$TEMP_DIR/$MENU_NAME" << 'MENU_EOF'
{
    "admin/status/audio_inputs": {
        "title": "Audio Inputs",
        "order": 80,
        "action": {
            "type": "view",
            "path": "status/audio_inputs"
        }
    }
}
MENU_EOF

echo "  ${GREEN}✓ Menu definition generated${NC}"

# -------------------------------------------------------------------
# Create remote directories (if they don't exist)
# -------------------------------------------------------------------
echo ""
echo "${YELLOW}Creating remote directories...${NC}"
for dir in "$LIBEXEC_DIR" "$CONTROLLER_DIR" "$TEMPLATE_DIR" "$MENU_DIR"; do
    if remote_exec "mkdir -p '$dir' 2>/dev/null && echo 'ok' || echo 'fail'"; then
        echo "  ${GREEN}✓ $dir${NC}"
    else
        echo "  ${RED}✗ Failed to create $dir${NC}"
        exit 1
    fi
done

# -------------------------------------------------------------------
# Copy files to target
# -------------------------------------------------------------------
echo ""
echo "${YELLOW}Copying files to $TARGET...${NC}"

if remote_cp "$TEMP_DIR/$SCRIPT_NAME" "$LIBEXEC_DIR/$SCRIPT_NAME"; then
    echo "  ${GREEN}✓ Backend script → $LIBEXEC_DIR/$SCRIPT_NAME${NC}"
else
    echo "  ${RED}✗ Failed to copy backend script${NC}"
    exit 1
fi

if remote_cp "$TEMP_DIR/$CONTROLLER_NAME" "$CONTROLLER_DIR/$CONTROLLER_NAME"; then
    echo "  ${GREEN}✓ Controller → $CONTROLLER_DIR/$CONTROLLER_NAME${NC}"
else
    echo "  ${RED}✗ Failed to copy controller${NC}"
    exit 1
fi

if remote_cp "$TEMP_DIR/$TEMPLATE_NAME" "$TEMPLATE_DIR/$TEMPLATE_NAME"; then
    echo "  ${GREEN}✓ Template → $TEMPLATE_DIR/$TEMPLATE_NAME${NC}"
else
    echo "  ${RED}✗ Failed to copy template${NC}"
    exit 1
fi

if remote_cp "$TEMP_DIR/$MENU_NAME" "$MENU_DIR/$MENU_NAME"; then
    echo "  ${GREEN}✓ Menu JSON → $MENU_DIR/$MENU_NAME${NC}"
else
    echo "  ${RED}✗ Failed to copy menu definition${NC}"
    exit 1
fi

# -------------------------------------------------------------------
# Set permissions
# -------------------------------------------------------------------
echo ""
echo "${YELLOW}Setting permissions...${NC}"
if remote_exec "chmod 755 '$LIBEXEC_DIR/$SCRIPT_NAME'"; then
    echo "  ${GREEN}✓ Backend script made executable${NC}"
else
    echo "  ${RED}✗ Failed to set permissions${NC}"
    exit 1
fi

# -------------------------------------------------------------------
# Clear LuCI cache
# -------------------------------------------------------------------
echo ""
echo "${YELLOW}Clearing LuCI cache...${NC}"
if remote_exec "rm -f $CACHE_DIR/luci-indexcache $CACHE_DIR/luci-modulecache"; then
    echo "  ${GREEN}✓ Cache cleared${NC}"
else
    echo "  ${YELLOW}⚠ Could not clear cache (may not be needed)${NC}"
fi

# -------------------------------------------------------------------
# Restart uhttpd
# -------------------------------------------------------------------
echo ""
echo "${YELLOW}Restarting uhttpd...${NC}"
if remote_exec "/etc/init.d/uhttpd restart 2>/dev/null || service uhttpd restart 2>/dev/null"; then
    echo "  ${GREEN}✓ uhttpd restarted${NC}"
else
    echo "  ${YELLOW}⚠ Could not restart uhttpd automatically${NC}"
    echo "       Please run manually: /etc/init.d/uhttpd restart"
fi

# -------------------------------------------------------------------
# Verify installation
# -------------------------------------------------------------------
echo ""
echo "${YELLOW}Verifying installation...${NC}"

VERIFY_OK=1

# Check if backend script exists and is executable
if remote_exec "test -x '$LIBEXEC_DIR/$SCRIPT_NAME' && echo 'ok' || echo 'fail'"; then
    echo "  ${GREEN}✓ Backend script exists and is executable${NC}"
else
    echo "  ${RED}✗ Backend script verification failed${NC}"
    VERIFY_OK=0
fi

# Test backend script execution
echo "  Testing backend script..."
BACKEND_OUTPUT=$(remote_exec "$LIBEXEC_DIR/$SCRIPT_NAME" 2>/dev/null || echo "EXEC_FAILED")
if [ "$BACKEND_OUTPUT" != "EXEC_FAILED" ]; then
    echo "  ${GREEN}✓ Backend script runs successfully${NC}"
    echo "  Output: $BACKEND_OUTPUT"
else
    echo "  ${YELLOW}⚠ Backend script returned empty (possibly no ALSA devices)${NC}"
fi

# Check if controller exists
if remote_exec "test -f '$CONTROLLER_DIR/$CONTROLLER_NAME' && echo 'ok' || echo 'fail'"; then
    echo "  ${GREEN}✓ Controller exists${NC}"
else
    echo "  ${RED}✗ Controller verification failed${NC}"
    VERIFY_OK=0
fi

# Check if template exists
if remote_exec "test -f '$TEMPLATE_DIR/$TEMPLATE_NAME' && echo 'ok' || echo 'fail'"; then
    echo "  ${GREEN}✓ Template exists${NC}"
else
    echo "  ${RED}✗ Template verification failed${NC}"
    VERIFY_OK=0
fi

# -------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------
echo ""
if [ $VERIFY_OK -eq 1 ]; then
    echo "${GREEN}========================================${NC}"
    echo "${GREEN}  Installation Complete!${NC}"
    echo "${GREEN}========================================${NC}"
    echo ""
    echo "Access the page at:"
    echo "  http://$TARGET/cgi-bin/luci/admin/status/audio_inputs"
    echo ""
    echo "Or navigate through LuCI:"
    echo "  Status → Audio Inputs"
    echo ""
    echo "To test the JSON endpoint directly:"
    echo "  http://$TARGET/cgi-bin/luci/admin/status/audio_inputs/list"
    echo ""
    echo "To run the backend from SSH:"
    echo "  ssh $TARGET /usr/libexec/alsa-inputs-json"
    echo ""
    if ! remote_exec "which arecord >/dev/null 2>&1"; then
        echo "${YELLOW}Note: alsa-utils not found. Install with:${NC}"
        echo "  ssh $TARGET opkg install alsa-utils"
        echo ""
    fi
    echo "To uninstall:"
    echo "  $0 $TARGET --uninstall"
else
    echo "${RED}========================================${NC}"
    echo "${RED}  Installation had issues.${NC}"
    echo "${RED}========================================${NC}"
    echo "Please check the errors above and try again."
    echo ""
    echo "To retry after fixing issues:"
    echo "  $0 $TARGET --uninstall"
    echo "  $0 $TARGET"
    exit 1
fi
