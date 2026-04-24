#!/bin/sh
#
# hALSAmrec LuCI app installer
# by FORART (https://forart.it/), 2025-26
# GPL v3 — see <https://www.gnu.org/licenses/>

set -e

REPO="FORARTfe/hALSAmrec"
BASE_URL="https://raw.githubusercontent.com/${REPO}/main/luci-app-halsamrec"
TMPDIR="/tmp/hALSAmrec-luci-install.$$"

# LuCI installation paths
CTRL_DIR="/usr/lib/lua/luci/controller"
VIEW_DIR="/usr/lib/lua/luci/view/halsamrec"

# ---------------------------------------------------------------------------
# Dependency check: luci-base provides XHR, the template engine, and the
# LuCI controller loader. Without it the app cannot function at all.
# ---------------------------------------------------------------------------
echo "[*] Checking LuCI dependency..."
if ! opkg list-installed | grep -q "^luci-base "; then
    echo "[*] Installing luci-base..."
    opkg update
    opkg install luci-base
fi

# ---------------------------------------------------------------------------
# Download
# Note: files are fetched from their repo paths and renamed to flat names
# in TMPDIR to simplify install commands.
# ---------------------------------------------------------------------------
echo "[*] Downloading LuCI app files from ${REPO}..."
mkdir -p "$TMPDIR"
cd "$TMPDIR"

wget -q -O halsamrec.lua  "${BASE_URL}/luasrc/controller/halsamrec.lua"
wget -q -O devices.htm    "${BASE_URL}/luasrc/view/halsamrec/devices.htm"

# Verify downloads are non-empty before touching the live filesystem
for f in halsamrec.lua devices.htm; do
    [ -s "$f" ] || { echo "Error: failed to download $f — aborting."; cd /; rm -rf "$TMPDIR"; exit 1; }
done

# ---------------------------------------------------------------------------
# Install
#
# NOT installed (intentionally):
#   root/etc/init.d/halsamrec-luci — no-op procd script; LuCI loads
#     controllers by filesystem presence, not init state. Installing it
#     would only create a ghost service entry with no effect.
#   root/etc/config/halsamrec — UCI config; the controller hardcodes
#     hw:0,0 directly and no code path reads this file. Skipping saves
#     a pointless flash write.
# ---------------------------------------------------------------------------
echo "[*] Installing controller..."
mkdir -p "$CTRL_DIR"
install -m 644 halsamrec.lua "$CTRL_DIR/halsamrec.lua"

echo "[*] Installing view..."
mkdir -p "$VIEW_DIR"
install -m 644 devices.htm "$VIEW_DIR/devices.htm"

# ---------------------------------------------------------------------------
# Cache invalidation — mandatory.
# LuCI indexes controllers at first load and caches the result in tmpfs.
# Without this step the new menu entry is invisible until next reboot.
# ---------------------------------------------------------------------------
echo "[*] Clearing LuCI cache..."
rm -f  /tmp/luci-indexcache
rm -rf /tmp/luci-modulecache/

# Reload the HTTP server so the cleared cache takes effect immediately
# without requiring a browser hard-refresh against a stale worker.
if [ -x /etc/init.d/uhttpd ]; then
    echo "[*] Reloading uhttpd..."
    /etc/init.d/uhttpd reload 2>/dev/null || true
fi

echo "[*] Cleaning up..."
cd /; rm -rf "$TMPDIR"

LAN_IP=$(uci get network.lan.ipaddr 2>/dev/null || echo '<your-ip>')
echo "[*] LuCI app installed."
echo "    Navigate to: http://${LAN_IP} → Audio Devices"
echo "    (Main menu bar, not under Services)"
