#!/bin/sh
set -e

REPO="FORARTfe/hALSAmrec"
TMPDIR="/tmp/hALSAmrec-install.$$"

# Required packages
PACKAGES="alsa-utils kmod-usb-storage block-mount kmod-usb3 kmod-usb-audio usbutils kmod-fs-exfat"

echo "[*] Check/install required packages..."

# Update package lists
opkg update

# Iterate over each package
for pkg in $PACKAGES; do
    echo "Checking $pkg"
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

wget -q https://raw.githubusercontent.com/FORARTfe/hALSAmrec/main/test/recorder
wget -q https://raw.githubusercontent.com/FORARTfe/hALSAmrec/main/initscript
wget -q https://raw.githubusercontent.com/FORARTfe/hALSAmrec/main/hotplug
wget -q https://raw.githubusercontent.com/FORARTfe/hALSAmrec/main/test/controlweb_cgi

echo "[*] Installing scripts (requires root)..."
mv recorder /usr/sbin/recorder
chmod 755 /usr/sbin/recorder

mv initscript /etc/init.d/autorecorder
chmod 755 /etc/init.d/autorecorder

mkdir -p /etc/hotplug.d/block
mkdir -p /etc/hotplug.d/usb
mv hotplug /etc/hotplug.d/block/autorecorder
cp /etc/hotplug.d/block/autorecorder /etc/hotplug.d/usb/autorecorder
chmod 644 /etc/hotplug.d/block/autorecorder /etc/hotplug.d/usb/autorecorder

echo "[*] Enabling service..."
/etc/init.d/autorecorder enable

echo "[*] Setting up CGI web interface..."
mkdir -p /www/cgi-bin
mv controlweb_cgi /www/cgi-bin/cm
chmod 755 /www/cgi-bin/cm

echo "[*] Web interface ready, here's the available commands:"
echo "  Start - http://$(uci get network.lan.ipaddr 2>/dev/null || echo '<your-ip>')/cgi-bin/cm?cmnd=START"
echo "  Stop -  http://$(uci get network.lan.ipaddr 2>/dev/null || echo '<your-ip>')/cgi-bin/cm?cmnd=STOP"
echo "  Status - http://$(uci get network.lan.ipaddr 2>/dev/null || echo '<your-ip>')/cgi-bin/cm?cmnd=ABOUT"

echo "[*] Cleaning up..."
cd /
rm -rf "$TMPDIR"

echo "[*] Installation complete !"

# Ask the user if they want to reboot now
echo ""
echo "It is recommended to reboot your device to complete the installation."
printf "Do you want to reboot now? [y/N]: "
read answer
case "$answer" in
    [yY][eE][sS]|[yY])
        echo "Rebooting now..."
        reboot
        ;;
    *)
        echo "Reboot skipped. Please reboot manually for changes to take effect."
        ;;
esac
