#!/bin/sh
#
# hALSAmrec LuCI/CGI installer (Lightened Edition)
# CLI + CGI + LuCI — full stack, single installer.
#
# GPL v3 — see <https://www.gnu.org/licenses/>
#

set -e
PATH=/usr/sbin:/usr/bin:/sbin:/bin
PACKAGES="rpcd luci-base alsa-utils usbutils kmod-usb-audio kmod-usb-storage block-mount kmod-fs-exfat"

echo "[*] Updating package lists and installing dependencies..."
opkg update >/dev/null 2>&1 || true
opkg install $PACKAGES || echo "WARNING: Some packages could not be installed."

echo "[*] Setting up directories and backups..."
mkdir -p /usr/sbin /etc/init.d /etc/hotplug.d/block /etc/hotplug.d/usb /usr/libexec/rpcd \
         /usr/share/rpcd/acl.d /usr/share/luci/menu.d /www/luci-static/resources/view/autorecorder \
         /www/cgi-bin

backup_file() { [ -e "$1" ] && [ ! -e "${1}.bak-autorecorder" ] && cp -p "$1" "${1}.bak-autorecorder" || true; }

for f in /usr/sbin/recorder /usr/sbin/autorecorderctl /etc/init.d/autorecorder \
    /etc/hotplug.d/block/49-autorecorder /etc/hotplug.d/usb/49-autorecorder /usr/libexec/rpcd/autorecorder \
    /usr/share/rpcd/acl.d/autorecorder.json /usr/share/luci/menu.d/autorecorder.json \
    /www/luci-static/resources/view/autorecorder/main.js /www/cgi-bin/cm; do
    backup_file "$f"
done

echo "[*] Installing recorder daemon..."
cat > /usr/sbin/recorder <<'EOF_RECORDER'
#!/bin/sh
# hALSAmrec recorder daemon — GPL v3
PATH=/usr/sbin:/usr/bin:/sbin:/bin
MNT=/tmp/mnt
recorder=""

cleanup() {
    [ -n "$recorder" ] && { kill "$recorder" 2>/dev/null || true; wait "$recorder" 2>/dev/null || true; recorder=""; }
    grep -qs " $MNT " /proc/mounts && umount -l "$MNT" 2>/dev/null || true
}

trap : SIGHUP
trap 'cleanup; kill $dummy 2>/dev/null || true; exit 0' INT TERM

sleep 2147483647 &
dummy=$!

find_audio_device() {
    command -v arecord >/dev/null 2>&1 || return 1
    arecord -l 2>/dev/null | awk '/^[[:space:]]*card[[:space:]]+[0-9]+:/ {
        match($0,/card[[:space:]]+[0-9]+/); c=substr($0,RSTART,RLENGTH); sub(/.* /,"",c)
        match($0,/device[[:space:]]+[0-9]+/); d=substr($0,RSTART,RLENGTH); sub(/.* /,"",d)
        if(c!="" && d!="") {print c":"d; exit}
    }'
}

find_single_exfat() {
    c=0; f=""
    while read -r _ _ _ n _; do
        case "$n" in sd*|mmcblk*|nvme*) ;; *) continue ;; esac
        d="/dev/$n"; [ -b "$d" ] || continue
        if dd if="$d" bs=1 skip=3 count=5 2>/dev/null | grep -q 'EXFAT'; then
            c=$((c + 1)); f="$d"
        fi
    done < /proc/partitions
    [ "$c" -eq 1 ] && echo "$f"
}

get_num() { echo "$arecord_out" | awk -v l="$1" 'index($0,l":")==1 {gsub(/[^0-9]+/," "); n=split($0,a); for(i=n;i>=1;i--) if(a[i]!="") {print a[i]; exit}}'; }
get_fmt() { echo "$arecord_out" | awk '/^FORMAT:/ {sub(/^FORMAT:[ \t]*/,""); gsub(/[\[\]]/,""); n=split($0,a); for(i=n;i>=1;i--) if(a[i]!="") {print a[i]; exit}}'; }
valid() { case "$1" in ''|*[!0-9]*) return 1;; esac; }

first=1
while :; do
    [ "$first" -eq 1 ] && first=0 || wait ${recorder:-$dummy} 2>/dev/null || true
    
    audio_dev=$(find_audio_device || true)
    disk=$(find_single_exfat || true)

    if [ -n "$recorder" ] && [ ! -e "/proc/$recorder" ]; then recorder=""; cleanup; fi
    if [ -z "$audio_dev" ] || [ -z "$disk" ]; then cleanup; sleep 2; continue; fi
    [ -n "$recorder" ] && continue

    card=${audio_dev%%:*}; dev=${audio_dev##*:}
    valid "$card" || continue; valid "$dev" || continue

    mkdir -p "$MNT"
    grep -qs " $MNT " /proc/mounts || mount "$disk" "$MNT" || continue

    avail=$(df -k "$MNT" 2>/dev/null | awk 'NR==2{print $4}')
    if ! valid "$avail" || [ "$avail" -le 102400 ]; then cleanup; sleep 5; continue; fi

    arecord_out=$(arecord -D "hw:${card},${dev}" --dump-hw-params 2>&1 || true)
    max_ch=$(get_num CHANNELS); valid "$max_ch" || max_ch=1
    max_rate=$(get_num RATE); valid "$max_rate" || max_rate=48000
    [ "$max_rate" -gt 48000 ] && max_rate=48000
    bitfmt=$(get_fmt); [ -n "$bitfmt" ] || bitfmt=S16_LE
    b_time=$(get_num BUFFER_TIME); b_size=$(get_num BUFFER_SIZE)

    outfile="${MNT}/$(date +%s)_${max_ch}-${max_rate}-${bitfmt}.raw"
    
    CMD="arecord -D hw:${card},${dev} -c $max_ch --file-type=raw -f $bitfmt -r $max_rate"
    if valid "$b_time" && valid "$b_size"; then
        $CMD --buffer-time="$b_time" --buffer-size="$b_size" > "$outfile" 2>/dev/null &
    else
        $CMD > "$outfile" 2>/dev/null &
    fi
    recorder=$!
done
EOF_RECORDER
chmod 0755 /usr/sbin/recorder

echo "[*] Installing control CLI..."
cat > /usr/sbin/autorecorderctl <<'EOF_CTL'
#!/bin/sh
PATH=/usr/sbin:/usr/bin:/sbin:/bin
RECORDER=/usr/sbin/recorder
INIT=/etc/init.d/autorecorder

pid_list() {
    pgrep -f "$RECORDER" 2>/dev/null | tr '\n' ' ' || \
    for p in /proc/[0-9]*; do tr '\0' ' ' < "$p/cmdline" 2>/dev/null | grep -q "$RECORDER" && echo "${p#/proc/}"; done
}
is_running() { [ -n "$(pid_list)" ]; }

cmd=$(echo "$1" | tr 'a-z' 'A-Z')
case "$cmd" in
    START) is_running && { echo "Already running"; exit 0; }
           $INIT start >/dev/null 2>&1; sleep 2
           is_running && echo "Started successfully" || { echo "Failed to start"; exit 1; } ;;
    STOP)  is_running || { echo "Already stopped"; exit 0; }
           $INIT stop >/dev/null 2>&1; sleep 2
           is_running && { echo "Failed to stop"; exit 1; } || echo "Stopped successfully" ;;
    STATUS) pids=$(pid_list); [ -n "$pids" ] && echo "RUNNING (PID: $pids)" || echo "STOPPED" ;;
    PROBE) is_running && { echo "WARNING: recorder running, stop first!"; exit 1; }
           command -v arecord >/dev/null || { echo "arecord not installed"; exit 1; }
           dev=$(arecord -l 2>/dev/null | awk '/^ *card +[0-9]+:/ {match($0,/card +[0-9]+/); c=substr($0,RSTART,RLENGTH); sub(/.* /,"",c); match($0,/device +[0-9]+/); d=substr($0,RSTART,RLENGTH); sub(/.* /,"",d); if(c!=""&&d!="") {print c","d; exit}}')
           [ -n "$dev" ] && arecord -D "hw:$dev" --dump-hw-params 2>&1 || { echo "No device found"; arecord -l 2>&1; } ;;
    *) echo "Usage: $0 START|STOP|STATUS|PROBE"; exit 1 ;;
esac
EOF_CTL
chmod 0755 /usr/sbin/autorecorderctl

echo "[*] Installing Init and Hotplug..."
cat > /etc/init.d/autorecorder <<'EOF_INIT'
#!/bin/sh /etc/rc.common
START=99
STOP=1
USE_PROCD=1
start_service() { procd_open_instance; procd_set_param command /usr/sbin/recorder; procd_set_param stdout 1; procd_set_param stderr 1; procd_set_param reload_signal SIGHUP; procd_close_instance; }
reload_service() { procd_send_signal autorecorder; }
EOF_INIT
chmod 0755 /etc/init.d/autorecorder

for h in block usb; do
    cat > /etc/hotplug.d/$h/49-autorecorder <<EOF
#!/bin/sh
logger -t autorecorder "$h hotplug triggered"
service autorecorder reload
EOF
    chmod 0755 /etc/hotplug.d/$h/49-autorecorder
done

echo "[*] Installing CGI endpoint..."
cat > /www/cgi-bin/cm <<'EOF_CGI'
#!/bin/sh
echo -e "Content-type: text/plain\n"
[ "$REQUEST_METHOD" = "GET" ] || { echo "Error: Method not allowed"; exit 1; }
tmp="${QUERY_STRING##*cmnd=}"; CMND=$(echo "${tmp%%&*}" | tr 'a-z' 'A-Z')
case "$CMND" in
    START|STOP|STATUS|PROBE) /usr/sbin/autorecorderctl "$CMND" ;;
    *) echo "Usage: /cgi-bin/cm?cmnd=START|STOP|STATUS|PROBE" ;;
esac
EOF_CGI
chmod 0755 /www/cgi-bin/cm
ln -sf /www/cgi-bin/cm /www/cgi-bin/controlweb_cgi

echo "[*] Installing RPCD backend..."
cat > /usr/libexec/rpcd/autorecorder <<'EOF_RPCD'
#!/bin/sh
. /usr/share/libubox/jshn.sh
CTL=/usr/sbin/autorecorderctl
pids=$($CTL STATUS | grep -o 'PID: [0-9 ]*' | cut -d' ' -f2-)
reply() {
    out=$($CTL "$1" 2>&1); rc=$?; pids=$($CTL STATUS | grep -o 'PID: [0-9 ]*' | cut -d' ' -f2-); json_init
    [ "$rc" -eq 0 ] && json_add_boolean success 1 || json_add_boolean success 0
    [ -n "$pids" ] && json_add_boolean running 1 || json_add_boolean running 0
    json_add_string message "$out"; [ -n "$pids" ] && json_add_string pid "$pids"
    [ "$1" = "PROBE" ] && json_add_string output "$out"; json_dump
}
case "$1" in
    list) echo '{"status":{},"start":{},"stop":{},"probe":{}}' ;;
    call) case "$2" in
            status) json_init; if [ -n "$pids" ]; then json_add_boolean running 1; json_add_string status "RUNNING"; json_add_string text "RUNNING (PID: $pids)"; else json_add_boolean running 0; json_add_string status "STOPPED"; json_add_string text "STOPPED"; fi; json_dump ;;
            start|stop|probe) reply "$(echo "$2" | tr 'a-z' 'A-Z')" ;;
            *) json_init; json_add_boolean success 0; json_add_string error "Unknown"; json_dump ;;
          esac ;;
    *) exit 1 ;;
esac
EOF_RPCD
chmod 0755 /usr/libexec/rpcd/autorecorder

echo "[*] Installing LuCI frontend..."
cat > /www/luci-static/resources/view/autorecorder/main.js <<'EOF_LUCI_JS'
'use strict'; 'require view'; 'require rpc'; 'require poll'; 'require ui';
var cmd = (m) => rpc.declare({ object: 'autorecorder', method: m });
var callStatus = cmd('status'), callStart = cmd('start'), callStop = cmd('stop'), callProbe = cmd('probe');
return view.extend({
    render: function() {
        var b = E('span',{'class':'badge'}), t = E('pre',{'style':'white-space:pre-wrap; margin-top:1em'}),
            p = E('pre',{'style':'white-space:pre-wrap; margin-top:1em; display:none'}), btns = [];
        var ref = () => callStatus().then(d => {
            b.textContent = d.status || (d.running ? 'RUNNING' : 'STOPPED');
            b.style.cssText = 'color:#fff; background-color:' + (d.running ? '#37a237' : '#a93737');
            t.textContent = d.text || b.textContent;
        }).catch(e => { b.textContent = 'ERROR'; t.textContent = e; });
        var run = (fn, msg, sp) => {
            btns.forEach(x => x.disabled = true); p.style.display = 'none';
            return fn().then(r => {
                ui.addNotification(null, E('p',{},r.message||msg), r.success===false?'warning':'info');
                if(sp){ p.style.display=''; p.textContent=r.output||msg; } return ref();
            }).finally(() => btns.forEach(x => x.disabled = false));
        };
        var mkbtn = (cls, txt, fn, msg, sp) => {
            var btn = E('button',{'class':'btn cbi-button cbi-button-'+cls,'style':'margin-right:.5em',
            'click':(ev)=>{ev.preventDefault();return run(fn,msg,sp);}}, _(txt)); btns.push(btn); return btn;
        };
        ref(); poll.add(ref, 5);
        return E('div',{'class':'cbi-map'},[
            E('h2',{},_('hALSAmrec')), E('div',{'class':'cbi-map-descr'},_('Control the autorecorder daemon.')),
            E('div',{'class':'cbi-section'},[E('h3',{},_('Status')), b, t,
                E('div',{'style':'margin-top:1em'},[
                    mkbtn('action','START',callStart,'Started',false),
                    mkbtn('negative','STOP',callStop,'Stopped',false),
                    mkbtn('neutral','PROBE',callProbe,'Probed',true)
                ]), p
            ])
        ]);
    }
});
EOF_LUCI_JS
chmod 0644 /www/luci-static/resources/view/autorecorder/main.js

cat > /usr/share/luci/menu.d/autorecorder.json <<'EOF_MENU'
{"admin/system/autorecorder": {"title": "hALSAmrec", "action": {"type": "view", "path": "autorecorder/main"}, "depends": {"acl": ["luci-app-autorecorder"]}}}
EOF_MENU
chmod 0644 /usr/share/luci/menu.d/autorecorder.json

cat > /usr/share/rpcd/acl.d/autorecorder.json <<'EOF_ACL'
{"luci-app-autorecorder": {"description": "LuCI hALSAmrec", "read": {"ubus": {"autorecorder": ["status","probe"]}}, "write": {"ubus": {"autorecorder": ["start","stop"]}}}}
EOF_ACL
chmod 0644 /usr/share/rpcd/acl.d/autorecorder.json

echo "[*] Enabling and starting services..."
/etc/init.d/autorecorder enable >/dev/null 2>&1 || true
/etc/init.d/autorecorder start >/dev/null 2>&1 || true
service rpcd restart >/dev/null 2>&1 || true

LAN_IP=$(uci get network.lan.ipaddr 2>/dev/null || echo '<your-ip>')
echo -e "\n[*] Installation complete. Available endpoints:\n    http://${LAN_IP}/cgi-bin/cm?cmnd=START|STOP|STATUS|PROBE\n    LuCI: System -> hALSAmrec"
printf "\nA reboot is recommended. Reboot now? [y/N]: "
read -r answer
case "$answer" in [yY]*) reboot ;; *) echo "Please reboot manually." ;; esac
