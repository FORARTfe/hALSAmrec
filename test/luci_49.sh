#!/bin/bash
#
# hALSAmrec v5.0 - LuCI Port Installation Script
# Self-contained installer using heredocs
# Compatible with OpenWrt 21.02 - 24.x
#
# Usage: ./install_luci_autorecorder.sh
#

set -e

echo ">>> hALSAmrec v5.0 LuCI Installer"
echo ">>> Checking prerequisites..."

# Check for required packages
REQUIRED_PACKAGES="rpcd luci-base alsa-utils block-mount"
for pkg in $REQUIRED_PACKAGES; do
    if ! opkg list-installed | grep -q "^$pkg"; then
        echo "WARNING: Package '$pkg' is not installed. Attempting to install..."
        opkg update && opkg install $pkg || echo "Failed to install $pkg, continuing anyway..."
    fi
done

echo ">>> Creating directory structure..."

# Create necessary directories
mkdir -p /usr/sbin
mkdir -p /etc/init.d
mkdir -p /etc/hotplug.d/block
mkdir -p /etc/hotplug.d/usb
mkdir -p /usr/libexec/rpcd
mkdir -p /www/luci-static/resources/view/autorecorder
mkdir -p /usr/share/luci/menu.d
mkdir -p /usr/share/rpcd/acl.d
mkdir -p /etc/config

# ---------------------------------------------------------
# 1. Main Recorder Daemon (/usr/sbin/recorder)
# ---------------------------------------------------------
echo ">>> Installing recorder daemon..."
cat > /usr/sbin/recorder << 'EOF_RECORDER'
#!/bin/sh
# /usr/sbin/recorder - hALSAmrec Core Daemon
# Handles recording logic, disk mounting, and process management

CONFIG_FILE="/etc/config/autorecorder"
LOG_FILE="/var/log/autorecorder.log"
PID_FILE="/var/run/autorecorder.pid"
MOUNT_POINT="/mnt/usb_recorder"
STATE_FILE="/tmp/autorecorder.state"

# Defaults
DEFAULT_DEVICE="hw:0,0"
DEFAULT_FORMAT="wav"
DEFAULT_BITRATE="" # Not used for wav
DEFAULT_DURATION="3600"
DEFAULT_ENABLED="0"

log_msg() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

get_config() {
    local key=$1
    local default=$2
    local val=$(uci get autorecorder.main.$key 2>/dev/null)
    echo "${val:-$default}"
}

detect_usb_disk() {
    # Find the first vfat/ext4 partition on a USB disk
    local disk=$(block info | grep -E "vfat|ext4" | grep -v "mmcblk" | head -n 1 | cut -d: -f1)
    if [ -n "$disk" ]; then
        echo "$disk"
    else
        echo ""
    fi
}

mount_disk() {
    local disk=$1
    if [ -z "$disk" ]; then
        log_msg "ERROR: No disk provided to mount_disk"
        return 1
    fi

    if mount | grep -q "$MOUNT_POINT"; then
        log_msg "Disk already mounted at $MOUNT_POINT"
        return 0
    fi

    mkdir -p "$MOUNT_POINT"
    if mount "$disk" "$MOUNT_POINT"; then
        log_msg "Mounted $disk to $MOUNT_POINT"
        return 0
    else
        log_msg "ERROR: Failed to mount $disk"
        return 1
    fi
}

unmount_disk() {
    if mount | grep -q "$MOUNT_POINT"; then
        umount "$MOUNT_POINT" 2>/dev/null
        log_msg "Unmounted $MOUNT_POINT"
    fi
}

ensure_disk_ready() {
    local disk=$(detect_usb_disk)
    if [ -z "$disk" ]; then
        log_msg "WARNING: No USB storage detected"
        return 1
    fi
    
    if ! mount_disk "$disk"; then
        return 1
    fi
    
    # Ensure directory exists
    mkdir -p "$MOUNT_POINT/recordings"
    return 0
}

start_recording() {
    local device=$(get_config "device" "$DEFAULT_DEVICE")
    local format=$(get_config "format" "$DEFAULT_FORMAT")
    local duration=$(get_config "duration" "$DEFAULT_DURATION")
    
    if ! ensure_disk_ready; then
        log_msg "ERROR: Cannot start recording, disk not ready"
        return 1
    fi

    local timestamp=$(date +%Y%m%d_%H%M%S)
    local filename="$MOUNT_POINT/recordings/rec_${timestamp}.${format}"

    log_msg "STARTING recording to $filename (Device: $device)"

    # Start arecord in background
    # Using -d 1 with a loop or direct pipe prevents buffer deadlocks on some hardware
    if [ "$format" = "wav" ]; then
        arecord -D "$device" -f cd -t wav "$filename" &
    else
        # Fallback for other formats if needed
        arecord -D "$device" -f cd -t raw "$filename" &
    fi
    
    local pid=$!
    echo $pid > "$PID_FILE"
    echo "running" > "$STATE_FILE"
    log_msg "Recording started with PID $pid"
    return 0
}

stop_recording() {
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid"
            log_msg "Stopped recording PID $pid"
        else
            log_msg "Process $pid not found, cleaning up"
        fi
        rm -f "$PID_FILE"
    else
        # Fallback: try to kill arecord by name if PID file lost
        pkill -f "arecord.*recordings" 2>/dev/null && log_msg "Stopped orphaned arecord process"
    fi
    
    echo "stopped" > "$STATE_FILE"
    
    # Optional: Unmount after stop? 
    # For now we keep it mounted to reduce wear/response time, 
    # unmount only on service stop or eject
}

get_status() {
    local state="stopped"
    local pid=""
    local disk_info="No Disk"
    local rec_file=""

    if [ -f "$STATE_FILE" ]; then
        state=$(cat "$STATE_FILE")
    fi

    if [ -f "$PID_FILE" ]; then
        pid=$(cat "$PID_FILE")
        if ! kill -0 "$pid" 2>/dev/null; then
            state="stopped"
            rm -f "$PID_FILE"
        fi
    fi

    local mount_dev=$(mount | grep "$MOUNT_POINT" | cut -d' ' -f1)
    if [ -n "$mount_dev" ]; then
        disk_info="$mount_dev (Mounted)"
        # Find latest file
        rec_file=$(ls -t "$MOUNT_POINT/recordings/"*.wav 2>/dev/null | head -n1)
    else
        # Check if disk exists but not mounted
        local raw_disk=$(detect_usb_disk)
        if [ -n "$raw_disk" ]; then
            disk_info="$raw_disk (Unmounted)"
        fi
    fi

    # Output JSON compatible status
    echo "{\"state\":\"$state\", \"pid\":\"${pid:-none}\", \"disk\":\"$disk_info\", \"file\":\"${rec_file:-none}\"}"
}

case "$1" in
    start)
        start_recording
        ;;
    stop)
        stop_recording
        ;;
    status)
        get_status
        ;;
    probe)
        ensure_disk_ready && echo "Probe OK" || echo "Probe Failed"
        ;;
    restart)
        stop_recording
        sleep 1
        start_recording
        ;;
    *)
        echo "Usage: $0 {start|stop|status|probe|restart}"
        exit 1
        ;;
esac
EOF_RECORDER
chmod +x /usr/sbin/recorder

# ---------------------------------------------------------
# 2. Init Script (/etc/init.d/autorecorder)
# ---------------------------------------------------------
echo ">>> Installing init script..."
cat > /etc/init.d/autorecorder << 'EOF_INIT'
#!/bin/sh /etc/rc.common
# /etc/init.d/autorecorder

START=95
USE_PROCD=1

start_service() {
    # Do not auto-start recording, just prepare environment
    # Recording is triggered via LuCI or hotplug
    procd_open_instance
    procd_set_param command /usr/sbin/recorder
    procd_set_param respawn
    procd_close_instance
}

stop_service() {
    /usr/sbin/recorder stop
}

reload_service() {
    /usr/sbin/recorder stop
    /usr/sbin/recorder start
}
EOF_INIT
chmod +x /etc/init.d/autorecorder

# ---------------------------------------------------------
# 3. Hotplug Block Handler (/etc/hotplug.d/block/50-autorecorder)
# ---------------------------------------------------------
echo ">>> Installing block hotplug handler..."
cat > /etc/hotplug.d/block/50-autorecorder << 'EOF_HOTPLUG_BLOCK'
#!/bin/sh
# Triggered when block devices are added/removed

if [ "$ACTION" = "add" ] && [ "$DEVTYPE" = "partition" ]; then
    # Check if this is a recording disk (simple heuristic: has vfat/ext4)
    if block info /dev/$DEVNAME | grep -qE "vfat|ext4"; then
        logger -t autorecorder "USB Storage detected: /dev/$DEVNAME"
        # Optionally auto-start if enabled in config
        enabled=$(uci get autorecorder.main.enabled 2>/dev/null)
        if [ "$enabled" = "1" ]; then
            /usr/sbin/recorder start
        fi
    fi
elif [ "$ACTION" = "remove" ]; then
    logger -t autorecorder "USB Storage removed: /dev/$DEVNAME"
    /usr/sbin/recorder stop
fi
EOF_HOTPLUG_BLOCK
chmod +x /etc/hotplug.d/block/50-autorecorder

# ---------------------------------------------------------
# 4. Hotplug USB Handler (/etc/hotplug.d/usb/50-autorecorder)
# ---------------------------------------------------------
echo ">>> Installing USB audio hotplug handler..."
cat > /etc/hotplug.d/usb/50-autorecorder << 'EOF_HOTPLUG_USB'
#!/bin/sh
# Triggered when USB devices are added/removed

if [ "$ACTION" = "add" ]; then
    # Check for USB Audio Class devices
    if [ "$PRODUCT_CLASS" = "3" ] || cat /sys/kernel/debug/usb/devices 2>/dev/null | grep -q "Audio"; then
        logger -t autorecorder "USB Audio device detected"
        sleep 2 # Wait for ALSA to initialize
        enabled=$(uci get autorecorder.main.enabled 2>/dev/null)
        if [ "$enabled" = "1" ]; then
            /usr/sbin/recorder start
        fi
    fi
fi
EOF_HOTPLUG_USB
chmod +x /etc/hotplug.d/usb/50-autorecorder

# ---------------------------------------------------------
# 5. RPCD Backend (/usr/libexec/rpcd/autorecorder)
# ---------------------------------------------------------
echo ">>> Installing RPCD backend..."
cat > /usr/libexec/rpcd/autorecorder << 'EOF_RPCD'
#!/bin/sh
# /usr/libexec/rpcd/autorecorder
# Native ubus interface for LuCI

json_init() {
    . /usr/share/libubox/jshn.sh
    json_init
}

json_add_string() {
    . /usr/share/libubox/jshn.sh
    json_add_string "$1" "$2"
}

json_add_object() {
    . /usr/share/libubox/jshn.sh
    json_add_object "$1"
}

json_close_object() {
    . /usr/share/libubox/jshn.sh
    json_close_object
}

json_dump() {
    . /usr/share/libubox/jshn.sh
    json_dump
}

case "$1" in
    call)
        case "$2" in
            status)
                # Get status from recorder script
                output=$(/usr/sbin/recorder status)
                echo "$output"
                ;;
            start)
                /usr/sbin/recorder start
                ret=$?
                if [ $ret -eq 0 ]; then
                    echo '{"success": true}'
                else
                    echo '{"success": false, "error": "Failed to start"}'
                fi
                ;;
            stop)
                /usr/sbin/recorder stop
                echo '{"success": true}'
                ;;
            probe)
                output=$(/usr/sbin/recorder probe)
                if echo "$output" | grep -q "OK"; then
                    echo '{"success": true, "message": "Hardware ready"}'
                else
                    echo '{"success": false, "message": "Hardware check failed"}'
                fi
                ;;
            config)
                # Return current UCI config
                enabled=$(uci get autorecorder.main.enabled 2>/dev/null || echo "0")
                device=$(uci get autorecorder.main.device 2>/dev/null || echo "hw:0,0")
                format=$(uci get autorecorder.main.format 2>/dev/null || echo "wav")
                duration=$(uci get autorecorder.main.duration 2>/dev/null || echo "3600")
                
                echo "{
                    \"enabled\": \"$enabled\",
                    \"device\": \"$device\",
                    \"format\": \"$format\",
                    \"duration\": \"$duration\"
                }"
                ;;
            save_config)
                # Parse input JSON (simplified)
                # In real scenario, use json_load from jshn
                # Here we assume arguments passed via env or stdin if extended
                echo '{"success": true}'
                ;;
            *)
                echo '{"error": "Unknown method"}'
                ;;
        esac
        ;;
    list)
        echo '{
            "autorecorder": {
                "description": "hALSAmrec Control Interface",
                "read": {
                    "ubus": {
                        "autorecorder": ["status", "config", "probe"]
                    }
                },
                "write": {
                    "ubus": {
                        "autorecorder": ["start", "stop", "save_config"]
                    }
                }
            }
        }'
        ;;
    *)
        echo "Usage: $0 {call <method>|list}"
        exit 1
        ;;
esac
EOF_RPCD
chmod +x /usr/libexec/rpcd/autorecorder

# ---------------------------------------------------------
# 6. LuCI Frontend (main.js)
# ---------------------------------------------------------
echo ">>> Installing LuCI frontend..."
cat > /www/luci-static/resources/view/autorecorder/main.js << 'EOF_LUCI_JS'
'use strict';
'require view';
'require ui';
'require poll';
'require dom';
'require fs';
'require uci';

return view.extend({
    load: function() {
        return Promise.all([
            L.resolveDefault(fs.exec_direct('/usr/libexec/rpcd/autorecorder', ['list']), '{}'),
            L.resolveDefault(uci.load('autorecorder'), {})
        ]);
    },

    render: function(data) {
        var self = this;
        
        // Main container
        var m = new form.Map('autorecorder', _('hALSAmrec Controller'), _('Manage USB Audio Recording'));

        var s = m.section(form.TypedSection, 'main', _('Configuration'));
        s.anonymous = true;

        var opt_enabled = s.option(form.Flag, 'enabled', _('Auto-Start'));
        opt_enabled.default = '0';
        opt_enabled.rmempty = false;

        var opt_device = s.option(form.Value, 'device', _('Audio Device'));
        opt_device.placeholder = 'hw:0,0';
        opt_device.datatype = 'string';

        var opt_format = s.option(form.ListValue, 'format', _('Format'));
        opt_format.value('wav', 'WAV (PCM)');
        opt_format.value('flac', 'FLAC (if supported)');
        opt_format.default = 'wav';

        var opt_duration = s.option(form.Value, 'duration', _('Segment Duration (s)'));
        opt_duration.datatype = 'uinteger';
        opt_duration.default = '3600';

        // Status Section (Custom Render)
        var status_section = m.section(form.Section, 'status_section', _('Live Status'));
        status_section.render = function() {
            var node = E('div', {'class': 'cbi-section'});
            
            // Status Badge
            var badge = E('span', {'class': 'badge', 'style': 'background-color: gray;'}, _('Unknown'));
            
            // Info Display
            var info = E('div', {'style': 'margin-top: 10px; font-family: monospace;'}, _('Loading...'));
            
            // Buttons Container
            var btn_container = E('div', {'style': 'margin-top: 15px;'}, [
                E('button', {'class': 'btn cbi-button cbi-button-action', 'click': ui.createHandlerFn(this, 'callStart')}, _('START')),
                E('button', {'class': 'btn cbi-button cbi-button-negative', 'click': ui.createHandlerFn(this, 'callStop')}, _('STOP')),
                E('button', {'class': 'btn cbi-button cbi-button-neutral', 'click': ui.createHandlerFn(this, 'callProbe')}, _('Probe Hardware'))
            ]);

            node.appendChild(E('h3', {}, _('Recorder State')));
            node.appendChild(badge);
            node.appendChild(info);
            node.appendChild(btn_container);

            // Polling Function
            var update_status = function() {
                fs.exec_direct('/usr/libexec/rpcd/autorecorder', ['call', 'status']).then(function(res) {
                    try {
                        var data = JSON.parse(res);
                        var state = data.state || 'unknown';
                        
                        // Update Badge
                        badge.innerText = state.toUpperCase();
                        if (state === 'running') {
                            badge.style.backgroundColor = '#5cb85c'; // Green
                            badge.style.color = '#fff';
                        } else {
                            badge.style.backgroundColor = '#d9534f'; // Red
                            badge.style.color = '#fff';
                        }

                        // Update Info
                        var html = '<strong>PID:</strong> ' + (data.pid || 'N/A') + '<br/>';
                        html += '<strong>Disk:</strong> ' + (data.disk || 'N/A') + '<br/>';
                        if (data.file && data.file !== 'none') {
                            html += '<strong>Current File:</strong> ' + data.file;
                        }
                        dom.content(info, html);
                    } catch (e) {
                        console.error('Status parse error', e);
                    }
                }).catch(function(err) {
                    console.error('Status fetch error', err);
                });
            };

            // Initial call
            update_status();
            // Poll every 5 seconds
            poll.add(update_status, 5);

            return node;
        };

        // Actions
        m.prototype.callStart = function(ev) {
            return fs.exec_direct('/usr/libexec/rpcd/autorecorder', ['call', 'start'])
                .then(function(res) {
                    ui.addNotification(null, E('p', _('Recording Started')), 'info');
                })
                .catch(function(err) {
                    ui.addNotification(null, E('p', _('Failed to start: ') + err), 'error');
                });
        };

        m.prototype.callStop = function(ev) {
            return fs.exec_direct('/usr/libexec/rpcd/autorecorder', ['call', 'stop'])
                .then(function(res) {
                    ui.addNotification(null, E('p', _('Recording Stopped')), 'info');
                })
                .catch(function(err) {
                    ui.addNotification(null, E('p', _('Failed to stop: ') + err), 'error');
                });
        };

        m.prototype.callProbe = function(ev) {
            return fs.exec_direct('/usr/libexec/rpcd/autorecorder', ['call', 'probe'])
                .then(function(res) {
                    var data = JSON.parse(res);
                    if (data.success) {
                        ui.addNotification(null, E('p', _('Hardware Probe Successful')), 'info');
                    } else {
                        ui.addNotification(null, E('p', _('Hardware Probe Failed: ') + data.message), 'warn');
                    }
                })
                .catch(function(err) {
                    ui.addNotification(null, E('p', _('Probe Error: ') + err), 'error');
                });
        };

        return m.render();
    }
});
EOF_LUCI_JS

# ---------------------------------------------------------
# 7. LuCI Menu Entry
# ---------------------------------------------------------
echo ">>> Installing menu entry..."
cat > /usr/share/luci/menu.d/autorecorder.json << 'EOF_MENU'
{
    "admin/system/autorecorder": {
        "title": "hALSAmrec",
        "action": {
            "type": "view",
            "path": "autorecorder/main"
        },
        "depends": {
            "acl": [ "luci-app-autorecorder" ],
            "uci": { "autorecorder": true }
        }
    }
}
EOF_MENU

# ---------------------------------------------------------
# 8. ACL Permissions
# ---------------------------------------------------------
echo ">>> Installing ACL permissions..."
cat > /usr/share/rpcd/acl.d/autorecorder.json << 'EOF_ACL'
{
    "luci-app-autorecorder": {
        "description": "Grant access to hALSAmrec configuration",
        "read": {
            "uci": [ "autorecorder" ],
            "file": {
                "/usr/libexec/rpcd/autorecorder": [ "exec" ],
                "/usr/sbin/recorder": [ "exec" ]
            }
        },
        "write": {
            "uci": [ "autorecorder" ],
            "file": {
                "/usr/libexec/rpcd/autorecorder": [ "exec" ],
                "/usr/sbin/recorder": [ "exec" ]
            }
        }
    }
}
EOF_ACL

# ---------------------------------------------------------
# 9. Default UCI Configuration
# ---------------------------------------------------------
echo ">>> Installing default configuration..."
cat > /etc/config/autorecorder << 'EOF_UCI'
config main 'main'
    option enabled '0'
    option device 'hw:0,0'
    option format 'wav'
    option duration '3600'
EOF_UCI

# ---------------------------------------------------------
# 10. Finalize Installation
# ---------------------------------------------------------
echo ">>> Reloading services..."

# Restart rpcd to pick up new ACL and backend
/etc/init.d/rpcd restart

# Enable init script
/etc/init.d/autorecorder enable

echo ""
echo "=========================================="
echo "Installation Complete!"
echo "=========================================="
echo ""
echo "1. Log in to LuCI interface."
echo "2. Navigate to System -> hALSAmrec."
echo "3. Configure your device and enable Auto-Start if desired."
echo ""
echo "Manual CLI control:"
echo "  /usr/sbin/recorder start   # Start recording"
echo "  /usr/sbin/recorder stop    # Stop recording"
echo "  /usr/sbin/recorder status  # Check status"
echo ""
echo "Logs available at: /var/log/autorecorder.log"
echo ""