#!/bin/sh

set -e

# Define the list of packages to install (added exfat-fuse and exfat-utils)
PACKAGES="alsa-utils kmod-usb-storage block-mount kmod-usb3 moreutils kmod-usb-audio usbutils perlbase-time kmod-fs-exfat"

echo "Checking for and installing missing OpenWRT packages..."

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

echo "Package installation check complete."