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

wget -q https://raw.githubusercontent.com/FORARTfe/hALSAmrec/main/test/recorder
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

echo "[*] Creating web interface..."
cat > /usr/bin/recorder-web << 'EOF'
#!/bin/sh
# Simple web interface for recorder control

PORT=8080
PIDFILE=/var/run/recorder-web.pid

handle_request() {
    while IFS= read -r line; do
        case "$line" in
            GET*/cm?*) 
                QUERY="${line#*\?}"
                QUERY="${QUERY% HTTP/*}"
                break
                ;;
            "") break ;;
        esac
    done
    
    CMND=$(echo "$QUERY" | sed -n 's/.*cmnd=\([^&]*\).*/\1/p' | sed 's/%20/ /g')
    
    case "$CMND" in
        "Power ON")
            if pgrep -f '/usr/sbin/recorder' >/dev/null; then
                echo "Already running"
            else
                /etc/init.d/autorecorder start >/dev/null 2>&1
                sleep 2
                if pgrep -f '/usr/sbin/recorder' >/dev/null; then
                    echo "Started successfully"
                else
                    echo "Failed to start"
                fi
            fi
            ;;
        "Power OFF")
            if ! pgrep -f '/usr/sbin/recorder' >/dev/null; then
                echo "Already stopped"
            else
                /etc/init.d/autorecorder stop >/dev/null 2>&1
                sleep 2
                if ! pgrep -f '/usr/sbin/recorder' >/dev/null; then
                    echo "Stopped successfully"
                else
                    echo "Failed to stop"
                fi
            fi
            ;;
        "Status")
            if pgrep -f '/usr/sbin/recorder' >/dev/null; then
                PID=$(pgrep -f '/usr/sbin/recorder')
                echo "RUNNING (PID: $PID)"
            else
                echo "STOPPED"
            fi
            ;;
        *)
            echo "Unknown command: $CMND"
            ;;
    esac
}

case "$1" in
    start)
        if [ -f "$PIDFILE" ] && kill -0 $(cat "$PIDFILE") 2>/dev/null; then
            echo "Web interface already running"
            exit 1
        fi
        
        echo "Starting recorder web interface on port $PORT..."
        (while true; do
            (echo -e "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nAccess-Control-Allow-Origin: *\r\n\r\n$(handle_request)") | nc -l -p $PORT -q 1
        done) &
        
        echo $! > "$PIDFILE"
        echo "Web interface started (PID: $!)"
        ;;
    stop)
        if [ -f "$PIDFILE" ]; then
            PID=$(cat "$PIDFILE")
            if kill -0 "$PID" 2>/dev/null; then
                kill "$PID"
                rm -f "$PIDFILE"
                echo "Web interface stopped"
            else
                echo "Web interface not running"
                rm -f "$PIDFILE"
            fi
        else
            echo "Web interface not running"
        fi
        ;;
    status)
        if [ -f "$PIDFILE" ] && kill -0 $(cat "$PIDFILE") 2>/dev/null; then
            echo "Web interface running (PID: $(cat "$PIDFILE"))"
        else
            echo "Web interface not running"
        fi
        ;;
    *)
        echo "Usage: $0 {start|stop|status}"
        exit 1
        ;;
esac
EOF

chmod 755 /usr/bin/recorder-web

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
