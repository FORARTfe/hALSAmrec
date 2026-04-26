#!/bin/sh
#
# hALSAmrec LuCI app installer
# by FORART (https://forart.it/), 2025-26
# GPL v3 — see <https://www.gnu.org/licenses/>

set -e

REPO="FORARTfe/hALSAmrec"
BASE_URL="https://raw.githubusercontent.com/${REPO}/main/luci-app-halsamrec"
TMPDIR="/tmp/hALSAmrec-luci-install.$$"

# ---------------------------------------------------------------------------
# Version detection
#
# OpenWrt 21.02 was the first release to ship the JS-based LuCI as default.
# From that point the Lua controller loader is provided by luci-compat, and
# menu entries must also be declared in /usr/share/luci/menu.d/ as JSON —
# entry() calls alone are not picked up by the new menu engine.
#
# Version string formats found in /etc/openwrt_release:
#   19.07.x  21.02.x  22.03.x  23.05.x  24.10.x  SNAPSHOT  r<commit>
# ---------------------------------------------------------------------------
detect_version() {
    if [ ! -f /etc/openwrt_release ]; then
        echo "[!] /etc/openwrt_release not found — assuming modern layout."
        NEW_LUCI=1
        return
    fi

    VER=$(grep DISTRIB_RELEASE /etc/openwrt_release | cut -d'"' -f2)

    case "$VER" in
        SNAPSHOT|r[0-9]*)
            # Development builds track main — always modern
            NEW_LUCI=1
            ;;
        *)
            # Major component is the 2-digit year: 19, 21, 22, 23, 24 …
            MAJOR=$(echo "$VER" | cut -d'.' -f1)
            if [ "$MAJOR" -ge 21 ] 2>/dev/null; then
                NEW_LUCI=1
            else
                NEW_LUCI=0
            fi
            ;;
    esac

    if [ "$NEW_LUCI" -eq 1 ]; then
        echo "[*] Detected OpenWrt ${VER} — using modern LuCI layout."
    else
        echo "[*] Detected OpenWrt ${VER} — using legacy Lua LuCI layout."
    fi
}

detect_version

# ---------------------------------------------------------------------------
# Installation paths
#
# Controller and view paths are identical in both layouts; luci-compat
# teaches the new loader to read them.  The menu.d path is new-only.
# ---------------------------------------------------------------------------
CTRL_DIR="/usr/lib/lua/luci/controller"
VIEW_DIR="/usr/lib/lua/luci/view/halsamrec"
MENU_DIR="/usr/share/luci/menu.d"          # only used when NEW_LUCI=1

# ---------------------------------------------------------------------------
# Dependency installation
#
# New layout: luci-compat pulls in luci-base transitively.
# Old layout: luci-base is sufficient.
# ---------------------------------------------------------------------------
echo "[*] Checking LuCI dependencies..."
if [ "$NEW_LUCI" -eq 1 ]; then
    if ! opkg list-installed | grep -q "^luci-compat "; then
        echo "[*] Installing luci-compat (required for Lua controllers on 21.02+)..."
        opkg update
        opkg install luci-compat
    else
        echo "[*] luci-compat already installed."
    fi
else
    if ! opkg list-installed | grep -q "^luci-base "; then
        echo "[*] Installing luci-base..."
        opkg update
        opkg install luci-base
    else
        echo "[*] luci-base already installed."
    fi
fi

# ---------------------------------------------------------------------------
# Download
# ---------------------------------------------------------------------------
echo "[*] Downloading LuCI app files from ${REPO}..."
mkdir -p "$TMPDIR"
cd "$TMPDIR"

wget -q -O halsamrec.lua "${BASE_URL}/luasrc/controller/halsamrec.lua"
wget -q -O devices.htm   "${BASE_URL}/luasrc/view/halsamrec/devices.htm"

# Guard against silent wget failures (some busybox builds write 0-byte
# files on 404 when invoked with -q instead of returning non-zero).
for f in halsamrec.lua devices.htm; do
    [ -s "$f" ] || {
        echo "Error: failed to download ${f} — aborting."
        cd /; rm -rf "$TMPDIR"; exit 1
    }
done

# ---------------------------------------------------------------------------
# Install controller and view
# Note: 'install' is not part of busybox by default; use cp + chmod.
# ---------------------------------------------------------------------------
echo "[*] Installing controller..."
mkdir -p "$CTRL_DIR"
cp halsamrec.lua "$CTRL_DIR/halsamrec.lua"
chmod 644 "$CTRL_DIR/halsamrec.lua"

echo "[*] Installing view..."
mkdir -p "$VIEW_DIR"
cp devices.htm "$VIEW_DIR/devices.htm"
chmod 644 "$VIEW_DIR/devices.htm"

# ---------------------------------------------------------------------------
# Modern layout only: install menu.d JSON descriptor.
#
# On 21.02+, the LuCI menu engine reads JSON from menu.d at startup.
# entry() in the Lua controller handles URL routing and access control,
# but the menu entry itself will not appear without this file.
#
# "type": "template" tells the loader to render a Lua .htm template,
# which requires luci-compat to be present (guaranteed above).
# ---------------------------------------------------------------------------
if [ "$NEW_LUCI" -eq 1 ]; then
    echo "[*] Installing menu descriptor..."
    mkdir -p "$MENU_DIR"
    cat > "$MENU_DIR/luci-app-halsamrec.json" << 'EOF'
{
    "admin/alsa": {
        "title": "ALSA",
        "order": 40
    },
    "admin/alsa/devices": {
        "title": "Audio Devices",
        "order": 10,
        "action": {
            "type": "template",
            "path": "halsamrec/devices"
        }
    }
}
EOF
    chmod 644 "$MENU_DIR/luci-app-halsamrec.json"
fi

# ---------------------------------------------------------------------------
# NOT installed (intentionally):
#   root/etc/init.d/halsamrec-luci — no-op; LuCI loads by filesystem
#     presence, not init state.
#   root/etc/config/halsamrec — hw:0,0 is hard-coded in the controller;
#     no code path reads this UCI file.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Cache invalidation
# Must run after all files are in place.
# ---------------------------------------------------------------------------
echo "[*] Clearing LuCI cache..."
rm -f  /tmp/luci-indexcache
rm -rf /tmp/luci-modulecache/

# 'reload' sends SIGHUP — flushes workers without dropping active sessions.
if [ -x /etc/init.d/uhttpd ]; then
    echo "[*] Reloading uhttpd..."
    /etc/init.d/uhttpd reload 2>/dev/null || true
fi

echo "[*] Cleaning up..."
cd /; rm -rf "$TMPDIR"

LAN_IP=$(uci get network.lan.ipaddr 2>/dev/null || echo '<your-ip>')
echo "[*] LuCI app installed."
echo "    Navigate to: http://${LAN_IP} → ALSA → Audio Devices"
