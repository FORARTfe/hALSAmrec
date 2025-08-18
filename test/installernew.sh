#!/bin/sh
set -e

REPO="FORARTfe/hALSAmrec"
TMPDIR="/tmp/hALSAmrec-install.$$"

# Define the list of packages to install (removed moreutils and lsblk)
PACKAGES="alsa-utils kmod-usb-storage block-mount kmod-usb3 kmod-usb-audio usbutils kmod-fs-exfat"

echo "[*] Checking and install missing OpenWRT packages..."

# Update package lists
opkg update

# Iterate over each package
for pkg in $PACKAGES; do
    echo "Checking for package: $pkg"
    # Check if the package is already installed
    if opkg list-installed | grep -q "^$pkg -"; then
        echo "$pkg is already installed."
    else
        echo "$pkg is not installed. Attempting to install..."
        opkg install "$pkg"
        if [ $? -eq 0 ]; then
            echo "$pkg installed successfully."
        else
            echo "Error: Failed to install $pkg. Please check your internet connection or package availability."
        fi
    fi
done

echo "[*] Downloading latest files from $REPO..."
rm -rf "$TMPDIR"
mkdir -p "$TMPDIR"
cd "$TMPDIR"

wget -q https://raw.githubusercontent.com/FORARTfe/hALSAmrec/main/recorder
wget -q https://raw.githubusercontent.com/FORARTfe/hALSAmrec/main/initscript
wget -q https://raw.githubusercontent.com/FORARTfe/hALSAmrec/main/hotplug
wget -q https://raw.githubusercontent.com/FORARTfe/hALSAmrec/main/recorder-web

echo "[*] Moving files in place (requires root)..."
mv recorder /usr/sbin/recorder
chmod 755 /usr/sbin/recorder

mv initscript /etc/init.d/autorecorder
chmod 755 /etc/init.d/autorecorder

mkdir -p /etc/hotplug.d/block
mkdir -p /etc/hotplug.d/usb
mv hotplug /etc/hotplug.d/block/autorecorder
cp /etc/hotplug.d/block/autorecorder /etc/hotplug.d/usb/autorecorder
chmod 644 /etc/hotplug.d/block/autorecorder /etc/hotplug.d/usb/autorecorder

echo "[*] Enabling autorecorder service..."
/etc/init.d/autorecorder enable

echo "[*] Configuring firewall for web interface..."
uci add firewall rule
uci set firewall.@rule[-1].name='Allow-Recorder-Web'
uci set firewall.@rule[-1].src='lan'
uci set firewall.@rule[-1].dest_port='8080'
uci set firewall.@rule[-1].proto='tcp'
uci set firewall.@rule[-1].target='ACCEPT'
uci commit firewall
/etc/init.d/firewall reload

echo "[*] Starting web interface..."
/usr/bin/recorder-web start

echo "[*] Web interface commands:"
echo "  Start: http://$(uci get network.lan.ipaddr 2>/dev/null || echo '<your-ip>'):8080/cm?cmnd=Power%20ON"
echo "  Stop:  http://$(uci get network.lan.ipaddr 2>/dev/null || echo '<your-ip>'):8080/cm?cmnd=Power%20OFF"
echo "  Status: http://$(uci get network.lan.ipaddr 2>/dev/null || echo '<your-ip>'):8080/cm?cmnd=Status"

echo "[*] Cleaning up..."
cd /
rm -rf "$TMPDIR"

echo "[*] Installation complete."
