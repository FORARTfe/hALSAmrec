#!/bin/sh
#
# hALSAmrec installer
# by FORART (https://forart.it/), 2025
# GPL v3 — see <https://www.gnu.org/licenses/>

set -e

REPO="FORARTfe/hALSAmrec"
BASE_URL="https://raw.githubusercontent.com/${REPO}/main"
TMPDIR="/tmp/hALSAmrec-install.$$"
PACKAGES="alsa-utils kmod-usb-storage block-mount kmod-usb3 kmod-usb-audio usbutils kmod-fs-exfat"

echo "[*] Updating package lists..."
opkg update

# opkg install is idempotent: packages already at current version are silently skipped.
# This replaces the per-package loop and fixes the dead error-path under set -e.
echo "[*] Installing required packages..."
opkg install $PACKAGES

echo "[*] Downloading latest files from ${REPO}..."
mkdir -p "$TMPDIR"
cd "$TMPDIR"

for f in recorder initscript hotplug controlweb_cgi; do
    wget -q "${BASE_URL}/${f}"
done

echo "[*] Installing scripts..."
install -m 755 recorder           /usr/sbin/recorder
install -m 755 initscript         /etc/init.d/autorecorder
mkdir -p /etc/hotplug.d/block /etc/hotplug.d/usb
install -m 644 hotplug            /etc/hotplug.d/block/autorecorder
install -m 644 hotplug            /etc/hotplug.d/usb/autorecorder

echo "[*] Enabling service..."
/etc/init.d/autorecorder enable

echo "[*] Setting up CGI web interface..."
mkdir -p /www/cgi-bin
install -m 755 controlweb_cgi     /www/cgi-bin/cm

LAN_IP=$(uci get network.lan.ipaddr 2>/dev/null || echo '<your-ip>')
echo "[*] Web interface ready:"
for cmd in START STOP STATUS PROBE; do
    echo "  ${cmd} - http://${LAN_IP}/cgi-bin/cm?cmnd=${cmd}"
done

echo "[*] Cleaning up..."
cd /; rm -rf "$TMPDIR"
echo "[*] Installation complete!"

echo ""
printf "A reboot is recommended. Reboot now? [y/N]: "
read answer
case "$answer" in
    [yY]*) echo "Rebooting..."; reboot ;;
    *)     echo "Please reboot manually when ready." ;;
esac
