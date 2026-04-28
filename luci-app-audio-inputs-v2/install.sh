#!/bin/sh
#
# luci-app-audio-inputs installer
# Runs directly on the OpenWrt router (no scp/rsync needed):
#
#   wget -qO- https://raw.githubusercontent.com/FORARTfe/hALSAmrec/main/luci-app-audio-inputs-v2 | sh
#
# GPL v3 — https://www.gnu.org/licenses/

set -e

BASE_URL="https://raw.githubusercontent.com/FORARTfe/hALSAmrec/main/luci-app-audio-inputs-v2"
TMPDIR="/tmp/audio-inputs-install.$$"

# ── Version detection ────────────────────────────────────────────────────────
# NEW_LUCI=1  →  OpenWrt v21+ (JS/RPCd LuCI, menu.d JSON, view modules)
# NEW_LUCI=0  →  OpenWrt pre-v21 (classic Lua MVC LuCI)
detect_version() {
    if [ ! -f /etc/openwrt_release ]; then
        NEW_LUCI=1; VER="unknown (assuming modern)"; return
    fi
    VER=$(grep DISTRIB_RELEASE /etc/openwrt_release | cut -d'"' -f2)
    case "$VER" in
        SNAPSHOT|r[0-9]*) NEW_LUCI=1 ;;
        *) MAJOR=$(echo "$VER" | cut -d'.' -f1)
           [ "$MAJOR" -ge 21 ] 2>/dev/null && NEW_LUCI=1 || NEW_LUCI=0 ;;
    esac
    echo "[*] OpenWrt ${VER} — $([ "$NEW_LUCI" -eq 1 ] && echo 'modern (v21+)' || echo 'legacy (pre-v21)') LuCI layout"
}
detect_version

# ── Path layout ──────────────────────────────────────────────────────────────
#
# Modern (v21+) — JS/RPCd stack, no luci-compat:
#   JS view       → /www/luci-static/resources/view/status/
#   Menu entry    → /usr/share/luci/menu.d/
#   RPCd ACL      → /usr/share/rpcd/acl.d/
#
# Legacy (pre-v21) — classic Lua MVC stack:
#   Lua controller → /usr/lib/lua/luci/controller/status/
#   Lua/HTM view   → /usr/lib/lua/luci/view/status/
#
if [ "$NEW_LUCI" -eq 1 ]; then
    VIEW_DIR="/www/luci-static/resources/view/status"
    MENU_DIR="/usr/share/luci/menu.d"
    ACL_DIR="/usr/share/rpcd/acl.d"
else
    CTRL_DIR="/usr/lib/lua/luci/controller/status"
    VIEW_DIR="/usr/lib/lua/luci/view/status"
fi

# ── Dependencies ─────────────────────────────────────────────────────────────
echo "[*] Checking dependencies..."

# luci-compat is deliberately NOT installed — files are placed in the layout
# that natively matches the detected OpenWrt version.

opkg list-installed | grep -q "^alsa-utils " || {
    echo "[*] Installing alsa-utils..."
    opkg update 2>/dev/null; opkg install alsa-utils
}

if [ "$NEW_LUCI" -eq 1 ]; then
    opkg list-installed | grep -q "^rpcd-mod-rpcsys " || {
        echo "[*] Installing rpcd-mod-rpcsys..."
        opkg update 2>/dev/null; opkg install rpcd-mod-rpcsys
        /etc/init.d/rpcd restart 2>/dev/null || true
    }
fi

# ── Download ──────────────────────────────────────────────────────────────────
echo "[*] Downloading files..."
mkdir -p "$TMPDIR" && cd "$TMPDIR"

# Common to both layouts
wget -q -O alsa-inputs-json "${BASE_URL}/alsa-inputs-json"

if [ "$NEW_LUCI" -eq 1 ]; then
    wget -q -O audio_inputs.js  "${BASE_URL}/audio_inputs.js"
    wget -q -O menu.json        "${BASE_URL}/luci-app-audio-inputs.json"
    wget -q -O acl.json         "${BASE_URL}/luci-app-audio-inputs.acl.json"
    for f in alsa-inputs-json audio_inputs.js menu.json acl.json; do
        [ -s "$f" ] || { echo "[!] Download failed: $f"; cd /; rm -rf "$TMPDIR"; exit 1; }
    done
else
    wget -q -O audio_inputs.lua "${BASE_URL}/audio_inputs.lua"
    wget -q -O audio_inputs.htm "${BASE_URL}/audio_inputs.htm"
    for f in alsa-inputs-json audio_inputs.lua audio_inputs.htm; do
        [ -s "$f" ] || { echo "[!] Download failed: $f"; cd /; rm -rf "$TMPDIR"; exit 1; }
    done
fi

# ── Install ───────────────────────────────────────────────────────────────────
echo "[*] Installing files ($([ "$NEW_LUCI" -eq 1 ] && echo 'modern v21+' || echo 'legacy pre-v21') layout)..."

# alsa-inputs-json helper — same path on both layouts
mkdir -p /usr/libexec
cp alsa-inputs-json /usr/libexec/alsa-inputs-json
chmod 755 /usr/libexec/alsa-inputs-json

if [ "$NEW_LUCI" -eq 1 ]; then
    # JS view module
    mkdir -p "$VIEW_DIR"
    cp audio_inputs.js "${VIEW_DIR}/audio_inputs.js"
    chmod 644 "${VIEW_DIR}/audio_inputs.js"

    # Menu registration (type: view)
    mkdir -p "$MENU_DIR"
    cp menu.json "${MENU_DIR}/luci-app-audio-inputs.json"
    chmod 644 "${MENU_DIR}/luci-app-audio-inputs.json"

    # RPCd ACL — grants file.exec on alsa-inputs-json
    mkdir -p "$ACL_DIR"
    cp acl.json "${ACL_DIR}/luci-app-audio-inputs.json"
    chmod 644 "${ACL_DIR}/luci-app-audio-inputs.json"
else
    # Lua controller
    mkdir -p "$CTRL_DIR"
    cp audio_inputs.lua "${CTRL_DIR}/audio_inputs.lua"
    chmod 644 "${CTRL_DIR}/audio_inputs.lua"

    # Lua/HTM view
    mkdir -p "$VIEW_DIR"
    cp audio_inputs.htm "${VIEW_DIR}/audio_inputs.htm"
    chmod 644 "${VIEW_DIR}/audio_inputs.htm"
fi

# ── Cache + reload ────────────────────────────────────────────────────────────
echo "[*] Clearing LuCI cache..."
rm -f  /tmp/luci-indexcache
rm -rf /tmp/luci-modulecache/

if [ "$NEW_LUCI" -eq 1 ]; then
    # Restart rpcd so the new ACL is picked up immediately
    echo "[*] Restarting rpcd..."
    /etc/init.d/rpcd restart 2>/dev/null || true
fi

[ -x /etc/init.d/uhttpd ] && { echo "[*] Reloading uhttpd..."; /etc/init.d/uhttpd reload 2>/dev/null || true; }

# ── Cleanup ───────────────────────────────────────────────────────────────────
cd /; rm -rf "$TMPDIR"

LAN_IP=$(uci get network.lan.ipaddr 2>/dev/null || echo '<router-ip>')
echo "[*] Done. Open: http://${LAN_IP} -> Status -> Audio Inputs"
