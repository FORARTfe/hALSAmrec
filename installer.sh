#!/bin/sh
set -e

REPO="FORARTfe/hALSAmrec"
TMPDIR="/tmp/hALSAmrec-install.$$"

# Define the list of packages to install
PACKAGES="alsa-utils kmod-usb-storage block-mount kmod-usb3 moreutils kmod-usb-audio usbutils perlbase-time kmod-fs-exfat"

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

echo "[*] Cleaning up..."
cd /
rm -rf "$TMPDIR"

echo "[*] Installation complete."
