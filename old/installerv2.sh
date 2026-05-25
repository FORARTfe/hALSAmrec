#!/bin/sh
#
# hALSAmrec installer v2
# by FORART (https://forart.it/), 2025-26
# GPL v3 — see <https://www.gnu.org/licenses/>

set -e

BASE_URL="https://raw.githubusercontent.com/FORARTfe/hALSAmrec/tree/main/old/v2"
TMPDIR="/tmp/hALSAmrec-install.$$"
PACKAGES="alsa-utils kmod-usb-storage block-mount kmod-usb3 kmod-usb-audio usbutils kmod-fs-exfat"

echo "[*] Updating package lists..."
opkg update

echo "[*] Installing required packages..."
opkg install $PACKAGES

echo "[*] Downloading latest script version..."
mkdir -p "$TMPDIR"
cd "$TMPDIR"

for f in recorder initscript hotplug controlweb_cgi; do
    wget -q "${BASE_URL}/${f}"
done

# ---------------------------------------------------------------------------
# Install scripts
# Note: 'install' is not part of busybox by default; use cp + chmod.
# ---------------------------------------------------------------------------
echo "[*] Installing scripts..."
cp recorder           /usr/sbin/recorder           && chmod 755 /usr/sbin/recorder
cp initscript         /etc/init.d/autorecorder      && chmod 755 /etc/init.d/autorecorder

mkdir -p /etc/hotplug.d/block /etc/hotplug.d/usb
cp hotplug /etc/hotplug.d/block/autorecorder        && chmod 644 /etc/hotplug.d/block/autorecorder
cp hotplug /etc/hotplug.d/usb/autorecorder          && chmod 644 /etc/hotplug.d/usb/autorecorder

echo "[*] Enabling service..."
/etc/init.d/autorecorder enable

echo "[*] Setting up CGI web interface..."
mkdir -p /www/cgi-bin
cp controlweb_cgi /www/cgi-bin/cm                   && chmod 755 /www/cgi-bin/cm

LAN_IP=$(uci get network.lan.ipaddr 2>/dev/null || echo '<your-ip>')
echo "[*] Web interface ready. Available commands:"
for cmd in START STOP STATUS PROBE; do
    echo "- http://${LAN_IP}/cgi-bin/cm?cmnd=${cmd}"
done

echo "[*] Cleaning up..."
cd /; rm -rf "$TMPDIR"
echo "[*] Installation complete!"

echo ""
printf "A reboot is recommended. Reboot device now? [y/N]: "
read answer
case "$answer" in
    [yY]*) echo "Rebooting..."; reboot ;;
    *)     echo "Please reboot manually when ready." ;;
esac
