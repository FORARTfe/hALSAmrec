#!/bin/sh
set -e

REPO="FORARTfe/hALSAmrec"
BRANCH="main"
TMPDIR="/tmp/hALSAmrec-install.$$"

# Required packages for OpenWRT - minimal and hardware/FS-aware
PACKAGES="alsa-utils kmod-usb-storage block-mount kmod-usb3 kmod-usb-audio usbutils lsblk"

echo "[*] Checking and installing missing OpenWRT packages..."
opkg update

for pkg in $PACKAGES; do
    if opkg list-installed | grep -q "^${pkg} -"; then
        echo "  - $pkg already installed."
    else
        echo "  - Installing $pkg ..."
        opkg install "$pkg" || { echo "Error: Could not install $pkg"; exit 1; }
    fi
done

echo "[*] Downloading latest files from $REPO:$BRANCH..."
rm -rf "$TMPDIR"
mkdir -p "$TMPDIR"
cd "$TMPDIR"

# Always fetch the latest scripts (test/recorder for advanced detection/logic)
wget -q "https://raw.githubusercontent.com/$REPO/$BRANCH/test/recorder" -O recorder || { echo "Failed to download recorder"; exit 1; }
wget -q "https://raw.githubusercontent.com/$REPO/$BRANCH/initscript" -O initscript || { echo "Failed to download initscript"; exit 1; }
wget -q "https://raw.githubusercontent.com/$REPO/$BRANCH/hotplug" -O hotplug || { echo "Failed to download hotplug"; exit 1; }

echo "[*] Installing scripts (requires root)..."
install -m 755 recorder /usr/sbin/recorder

install -m 755 initscript /etc/init.d/autorecorder

mkdir -p /etc/hotplug.d/block /etc/hotplug.d/usb
install -m 644 hotplug /etc/hotplug.d/block/autorecorder
cp /etc/hotplug.d/block/autorecorder /etc/hotplug.d/usb/autorecorder

echo "[*] Enabling autorecorder service..."
/etc/init.d/autorecorder enable

echo "[*] Cleaning up..."
cd /
rm -rf "$TMPDIR"

echo "[*] Installation complete."
echo "You can start the service with: /etc/init.d/autorecorder start"
