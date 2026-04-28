#!/bin/sh
#
# luci-app-audio-inputs installer
# Runs directly on the OpenWrt router (no scp/rsync needed):
#
#   wget -qO- https://raw.githubusercontent.com/YOUR/REPO/main/install.sh | sh
#
# GPL v3 — https://www.gnu.org/licenses/

set -e

REPO="FORARTfe/hALSAmrec"
BASE_URL="https://raw.githubusercontent.com/${REPO}/main/luci-app-audio-inputs-v2"
TMPDIR="/tmp/audio-inputs-install.$$"

# ── Version detection (identical logic to halsamrec installer) ──────────────
detect_version() {
    [ -f /etc/openwrt_release ] || { NEW_LUCI=1; return; }
    VER=$(grep DISTRIB_RELEASE /etc/openwrt_release | cut -d'"' -f2)
    case "$VER" in
        SNAPSHOT|r[0-9]*) NEW_LUCI=1 ;;
        *) MAJOR=$(echo "$VER" | cut -d'.' -f1)
           [ "$MAJOR" -ge 21 ] 2>/dev/null && NEW_LUCI=1 || NEW_LUCI=0 ;;
    esac
    echo "[*] OpenWrt ${VER} — $([ "$NEW_LUCI" -eq 1 ] && echo modern || echo legacy) LuCI layout"
}
detect_version

# ── Dependencies ─────────────────────────────────────────────────────────────
echo "[*] Checking dependencies..."
if [ "$NEW_LUCI" -eq 1 ]; then
    opkg list-installed | grep -q "^luci-compat " || {
        echo "[*] Installing luci-compat..."
        opkg update && opkg install luci-compat
    }
fi
opkg list-installed | grep -q "^alsa-utils " || {
    echo "[*] Installing alsa-utils..."
    opkg update 2>/dev/null; opkg install alsa-utils
}

# ── Download ──────────────────────────────────────────────────────────────────
echo "[*] Downloading files..."
mkdir -p "$TMPDIR" && cd "$TMPDIR"

wget -q -O alsa-inputs-json \
    "${BASE_URL}/usr/libexec/alsa-inputs-json"
wget -q -O audio_inputs.lua \
    "${BASE_URL}/usr/lib/lua/luci/controller/status/audio_inputs.lua"
wget -q -O audio_inputs.htm \
    "${BASE_URL}/usr/lib/lua/luci/view/status/audio_inputs.htm"
[ "$NEW_LUCI" -eq 1 ] && wget -q -O menu.json \
    "${BASE_URL}/usr/share/luci/menu.d/luci-app-audio-inputs.json"

for f in alsa-inputs-json audio_inputs.lua audio_inputs.htm; do
    [ -s "$f" ] || { echo "[!] Download failed: $f"; cd /; rm -rf "$TMPDIR"; exit 1; }
done

# ── Install ───────────────────────────────────────────────────────────────────
echo "[*] Installing..."

mkdir -p /usr/libexec
cp alsa-inputs-json /usr/libexec/alsa-inputs-json
chmod 755 /usr/libexec/alsa-inputs-json

mkdir -p /usr/lib/lua/luci/controller/status
cp audio_inputs.lua /usr/lib/lua/luci/controller/status/audio_inputs.lua
chmod 644 /usr/lib/lua/luci/controller/status/audio_inputs.lua

mkdir -p /usr/lib/lua/luci/view/status
cp audio_inputs.htm /usr/lib/lua/luci/view/status/audio_inputs.htm
chmod 644 /usr/lib/lua/luci/view/status/audio_inputs.htm

if [ "$NEW_LUCI" -eq 1 ] && [ -s menu.json ]; then
    mkdir -p /usr/share/luci/menu.d
    cp menu.json /usr/share/luci/menu.d/luci-app-audio-inputs.json
    chmod 644 /usr/share/luci/menu.d/luci-app-audio-inputs.json
fi

# ── Cache + reload ────────────────────────────────────────────────────────────
echo "[*] Clearing LuCI cache..."
rm -f  /tmp/luci-indexcache
rm -rf /tmp/luci-modulecache/
[ -x /etc/init.d/uhttpd ] && { echo "[*] Reloading uhttpd..."; /etc/init.d/uhttpd reload 2>/dev/null || true; }

# ── Cleanup ───────────────────────────────────────────────────────────────────
cd /; rm -rf "$TMPDIR"

LAN_IP=$(uci get network.lan.ipaddr 2>/dev/null || echo '<router-ip>')
echo "[*] Done. Open: http://${LAN_IP} → Status → Audio Inputs"
