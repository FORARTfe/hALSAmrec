#!/bin/sh
#
# hALSAmrec installer script v2 by FORART (https://forart.it/), 2025
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or (at
# your option) any later version.

# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
#

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
wget -q https://raw.githubusercontent.com/FORARTfe/hALSAmrec/main/controlweb_cgi

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

echo "[*] Setting up CGI web interface..."
mkdir -p /www/cgi-bin
mv controlweb_cgi /www/cgi-bin/cm
chmod 755 /www/cgi-bin/cm

echo "[*] Enabling autorecorder service..."
/etc/init.d/autorecorder enable

echo "[*] Web interface ready! No firewall changes needed."
echo "  Start: http://$(uci get network.lan.ipaddr 2>/dev/null || echo '<your-ip>')/cgi-bin/cm?cmnd=Power%20ON"
echo "  Stop:  http://$(uci get network.lan.ipaddr 2>/dev/null || echo '<your-ip>')/cgi-bin/cm?cmnd=Power%20OFF"
echo "  Status: http://$(uci get network.lan.ipaddr 2>/dev/null || echo '<your-ip>')/cgi-bin/cm?cmnd=Status"

echo "[*] Cleaning up..."
cd /
rm -rf "$TMPDIR"

echo "[*] Installation complete."
