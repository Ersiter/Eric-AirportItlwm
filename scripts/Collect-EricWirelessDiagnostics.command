#!/bin/bash

# Eric wireless diagnostics for Wi-Fi, AirDrop, Instant Hotspot and Bluetooth.
export LC_ALL=C COPYFILE_DISABLE=1
umask 077

if [ "$(/usr/bin/uname -s)" != Darwin ]; then
    echo "Run this collector on the affected Mac."
    exit 1
fi
if [ "$(/usr/bin/id -u)" -ne 0 ]; then
    echo "Administrator access is used to read wireless diagnostics."
    exec /usr/bin/sudo /bin/bash "$0" "$@"
fi

case "${1:-}" in
    --bluetooth) focus=bluetooth ;;
    "")
        printf '1. Wi-Fi\n2. AirDrop or Instant Hotspot\n3. Bluetooth device discovery\nChoose [1-3]: '
        IFS= read -r answer || exit 1
        case "$answer" in
            1) focus=wifi ;;
            2) focus=continuity ;;
            3) focus=bluetooth ;;
            *) echo "Choose 1, 2 or 3."; exit 1 ;;
        esac ;;
    *) echo "Usage: $0 [--bluetooth]"; exit 1 ;;
esac
base="$(cd -- "$(dirname "$0")" && pwd)" || exit 1
if [ ! -w "$base" ]; then
    echo "Move this command to a writable folder and try again."
    exit 1
fi
work="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/EricWirelessDiagnostics.XXXXXX")" || exit 1
stream_pid=
timeline_pid=
mdns_pid=
mdns_drop_pid=

stop_recording() {
    local pid
    local pids=()
    for pid in "$stream_pid" "$timeline_pid" "$mdns_pid" "$mdns_drop_pid"; do
        [ -n "$pid" ] && pids+=("$pid")
    done
    if [ "${#pids[@]}" -gt 0 ]; then
        /bin/kill "${pids[@]}" 2>/dev/null
        /bin/sleep 1
        for pid in "${pids[@]}"; do
            if /bin/kill -0 "$pid" 2>/dev/null; then
                /bin/kill -KILL "$pid" 2>/dev/null
            fi
            wait "$pid" 2>/dev/null
        done
    fi
    stream_pid=
    timeline_pid=
    mdns_pid=
    mdns_drop_pid=
}
trap 'stop_recording; /bin/rm -r -- "$work"' EXIT
trap 'exit 130' INT TERM

bounded() {
    (ulimit -f 512; "$@")
}
# Darwin ships Perl on the supported systems. Carry the deadline through exec.
deadline() {
    /usr/bin/perl -e 'alarm shift; exec @ARGV or die "$ARGV[0]: $!"' "$@"
}
stamp() {
    /bin/date '+%Y-%m-%d %H:%M:%S %z'
}

boot_build="$(/usr/bin/sw_vers -buildVersion)"
os_version="$(/usr/bin/sw_vers -productVersion)"
(
    ulimit -f 256
    echo "Collector revision: 12"
    echo "Report: $focus"
    stamp
    /usr/bin/sw_vers
    /usr/bin/uname -m -r
    /usr/sbin/sysctl kern.bootargs kern.boottime hw.model
    echo
    echo '[Loaded kext version and UUID]'
    /usr/bin/kmutil showloaded 2>&1 | /usr/bin/grep -iE 'Index|AirportItlwm|itlwm|Lilu|BlueToolFixup|BTLEAdvFixup|IntelBT|BrcmPatchRAM|IO80211|IOSkywalk|IOBluetooth'
    echo
    echo '[Boot source]'
    /usr/sbin/ioreg -p IODeviceTree -r -n chosen -d 1 -l -w 0 2>/dev/null |
        /usr/bin/grep -E '"(boot-path|boot-file|boot-device-path|boot-uuid)"'
    /usr/sbin/nvram opencore-version 2>/dev/null || :
    echo
    echo '[Wi-Fi PCI identity]'
    /usr/sbin/ioreg -p IOService -r -c IOPCIDevice -d 1 -l -w 0 2>/dev/null |
        /usr/bin/awk '
            function emit() { if (wireless) { print node; printf "%s", props } }
            /\+-o / { emit(); node=$0; props=""; wireless=0 }
            /"class-code" = <[[:xdigit:]][[:xdigit:]]800200>/ { wireless=1 }
            /"(vendor-id|device-id|subsystem-id|subsystem-vendor-id|class-code|IOName|model)"/ {
                props=props $0 "\n"
            }
            END { emit() }
        '
    echo
    echo '[System framework versions]'
    for name in IO80211Family IOSkywalkFamily IOBluetoothFamily; do
        printf '%s ' "$name"
        /usr/bin/plutil -extract CFBundleVersion raw -o - "/System/Library/Extensions/$name.kext/Contents/Info.plist" 2>/dev/null || echo unavailable
    done
    echo
    echo '[Adjacent package files]'
    for bundle in "$base"/AirportItlwm*.kext "$base"/BlueToolFixup.kext; do
        info="$bundle/Contents/Info.plist"
        [ -f "$info" ] || continue
        printf '%s ' "$(basename "$bundle")"
        /usr/bin/plutil -extract CFBundleVersion raw -o - "$info" 2>/dev/null || :
        binary="$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "$info" 2>/dev/null)"
        [ -n "$binary" ] && /usr/bin/shasum -a 256 "$bundle/Contents/MacOS/$binary" | /usr/bin/awk '{ print $1 }'
    done
) > "$work/environment.txt" 2>&1

wifi_interfaces="$(/usr/sbin/networksetup -listallhardwareports 2>/dev/null |
    /usr/bin/awk '/Hardware Port: (Wi-Fi|AirPort)/ { getline; print $2 }')"

registry_state() {
    /usr/sbin/ioreg -p IOService -l -w 0 2>/dev/null |
        /usr/bin/grep -aE '"(AirportItlwm-[^"]+|AWDL[^"]*|ITLAWDL[^"]*|BTLEAdv[^"]*|BluetoothFirmwareVersion|WCLScanLast[^"]*)"[[:space:]]*=' |
        /usr/bin/cut -c 1-2500
}
snapshot() {
    stamp
    echo '[Wi-Fi and AWDL]'
    echo '[Driver properties]'
    registry_state
    if [ "$1" = after ]; then
        deadline 8 /usr/bin/wdutil info
    fi
    for interface in $wifi_interfaces awdl0 llw0; do
        deadline 3 /sbin/ifconfig -v "$interface"
        /usr/sbin/netstat -nI "$interface" -b
    done
    if [ "$focus" = continuity ] && /sbin/ifconfig awdl0 >/dev/null 2>&1; then
        echo '[Group memberships on awdl0]'
        deadline 3 /usr/sbin/netstat -ng -I awdl0 -v
    fi
    echo '[IPv6 neighbours, routes and AirDrop connections on awdl0/llw0]'
    /usr/sbin/ndp -an 2>&1 | /usr/bin/grep -E 'Neighbor|awdl0|llw0'
    /usr/sbin/netstat -rn -f inet6 2>&1 | /usr/bin/grep -E 'awdl0|llw0'
    /usr/sbin/ndp -np 2>&1 | /usr/bin/grep -A2 -E 'awdl0|llw0'
    /usr/sbin/netstat -an -p tcp 2>&1 | /usr/bin/grep -E '\.8770 '
    /usr/sbin/netstat -s -p tcp 2>&1 | /usr/bin/grep -E 'retransmit timeouts|connection requests|embryonic|listen queue'
    [ "$1" = before ] && return 0
    echo '[Bluetooth controller]'
    deadline 12 /usr/sbin/system_profiler -timeout 10 -detailLevel basic SPBluetoothDataType
}
save_snapshot() {
    local phase="$1" limit="$2" pid elapsed=0
    set -m
    (set +m; bounded snapshot "$phase") > "$work/$phase.txt" 2>&1 &
    pid=$!
    set +m
    while /bin/kill -0 "$pid" 2>/dev/null && [ "$elapsed" -lt "$limit" ]; do
        /bin/sleep 1
        elapsed=$((elapsed + 1))
    done
    if /bin/kill -0 "$pid" 2>/dev/null; then
        kill -KILL -- "-$pid" 2>/dev/null
        echo "Snapshot time limit reached. Partial output retained." >> "$work/$phase.txt"
    fi
    wait "$pid" 2>/dev/null
}
kernel_lines() {
    /sbin/dmesg 2>&1 | /usr/bin/grep -aiE 'itlwm|awdl|BlueToolFixup|btlfx|IntelBT|ibtfw|BTLEAdv|\[advsets\]|\[rpa\]|\[pagein\]|permission|not permitted' |
        /usr/bin/tail -n 900
}

echo "Eric Wireless Diagnostics. Reports can contain network and device names. Send them privately."
printf 'Describe the problem and, for AirDrop, the sending device: '
IFS= read -r problem
printf '%s\n' "$problem" > "$work/attempt.txt"
echo "Saving initial interface state..."
save_snapshot before 5
bounded kernel_lines > "$work/kernel-before.txt" 2>&1

predicate='process IN {"bluetoothd","wifid","airportd","wifip2pd","sharingd","rapportd","nearbyd","eapolclient","IPConfiguration"} OR (process == "kernel" AND (eventMessage CONTAINS[c] "itlwm" OR eventMessage CONTAINS[c] "awdl" OR eventMessage CONTAINS[c] "btlfx" OR eventMessage CONTAINS[c] "BlueToolFixup" OR eventMessage CONTAINS[c] "IntelBT" OR eventMessage CONTAINS[c] "[advsets]" OR eventMessage CONTAINS[c] "[rpa]" OR eventMessage CONTAINS[c] "[pagein]"))'
if [ "$focus" = continuity ]; then
    predicate="$predicate"' OR (process == "mDNSResponder" AND (eventMessage CONTAINS[c] "awdl0" OR eventMessage CONTAINS[c] "_airdrop._tcp"))'
fi
printf 'Start: %s\n' "$(stamp)" >> "$work/attempt.txt"
(ulimit -f 3072; exec /usr/bin/log stream --level info --style compact --predicate "$predicate") > "$work/live.txt" 2>&1 &
stream_pid=$!
(
    ulimit -f 384
    while :; do
        stamp
        for interface in $wifi_interfaces awdl0; do
            /usr/sbin/netstat -nI "$interface" -b 2>&1 | /usr/bin/tail -n 2
        done
        registry_state | /usr/bin/grep -aE 'Listener|Peer|AirDrop|Frame|Data|AWDL(FwGroup|Rx(Group|Dropped)|Listen(Rx|ByChan)|Roc(Started|Ended|Rx|LastUs))|Status|Error|Scan|Join|Associate|Country|WCL' |
            /usr/bin/cut -c 1-250
        /bin/sleep 5
    done
) > "$work/timeline.txt" 2>&1 &
timeline_pid=$!

if [ "$focus" = continuity ]; then
    (
        ulimit -f 128
        while ! /sbin/ifconfig awdl0 >/dev/null 2>&1; do
            /bin/sleep 1
        done
        exec /usr/sbin/tcpdump -p -ni awdl0 -evl -s 0 -c 256 'udp port 5353'
    ) > "$work/awdl-mdns.txt" 2>&1 &
    mdns_pid=$!
    (
        ulimit -f 128
        exec /usr/sbin/tcpdump -ni droptap -l -k ID -c 128 \
            -Q 'if=awdl0 and dir=in' 'udp dst port 5353'
    ) > "$work/awdl-mdns-drops.txt" 2>&1 &
    mdns_drop_pid=$!
fi

echo "Recording now."
case "$focus" in
    bluetooth) echo "Open System Settings > Bluetooth. Put a nearby device in pairing mode and wait about 30 seconds." ;;
    continuity) echo "Try one AirDrop transfer or join the iPhone hotspot once." ;;
    wifi) echo "Open the Wi-Fi list and reproduce the problem once." ;;
esac
echo "Press Enter after the result, or wait up to 120 seconds."
IFS= read -r -t 120 unused
echo "Recording finished. Saving the final snapshot and ZIP..."
stop_recording
printf 'End: %s\n' "$(stamp)" >> "$work/attempt.txt"
save_snapshot after 25
bounded kernel_lines > "$work/kernel-after.txt" 2>&1

if [ "$focus" = continuity ]; then
    # ioreg renders each firmware trace as one long line.
    /usr/sbin/ioreg -p IOService -l -w 0 2>/dev/null |
        /usr/bin/grep -aE '"AirportItlwm-Hotspot(Tx|Rx149)"[[:space:]]*=' > "$work/hotspot-frames.txt"
fi

patch_predicate='eventMessage CONTAINS[c] "[advsets]" OR eventMessage CONTAINS[c] "[rpa]" OR eventMessage CONTAINS[c] "[pagein]" OR eventMessage CONTAINS[c] "BlueToolFixup" OR eventMessage CONTAINS[c] "enableExtendedAdvertising" OR eventMessage CONTAINS[c] "support for extended scans"'
bounded deadline 15 /usr/bin/log show --last boot --info --style compact --predicate "$patch_predicate" > "$work/patches.txt" 2>&1

if [ "$focus" = wifi ] && ! /usr/bin/grep -qi "com.zxystd.AirportItlwm" "$work/environment.txt"; then
    load_predicate='eventMessage CONTAINS[c] "AirportItlwm" OR eventMessage CONTAINS[c] "IO80211Family" OR eventMessage CONTAINS[c] "IOSkywalkFamily"'
    bounded deadline 15 /usr/bin/log show --last boot --info --style compact --predicate "$load_predicate" > "$work/kext-load.txt" 2>&1
fi

if [ "$focus" = bluetooth ]; then
    /usr/bin/find /Library/Logs/DiagnosticReports -maxdepth 2 -type f -mtime -2 \
            -iname '*bluetoothd*.ips' -exec /usr/bin/stat -f '%m %N' {} + 2>/dev/null |
        /usr/bin/sort -rn | /usr/bin/head -n 3 | while IFS= read -r row; do
            report="${row#* }"
            printf '\n--- %s ---\n' "$(basename "$report")"
            /usr/bin/head -c 131072 "$report"
        done > "$work/bluetoothd-crashes.txt"
    /usr/bin/file /usr/sbin/bluetoothd > "$work/bluetoothd-binary.txt" 2>&1
else
    /usr/bin/find /Library/Logs/DiagnosticReports -maxdepth 2 -type f -mtime -2 \
            \( -name '*.panic' -o -name 'panic-full*.ips' \) -exec /usr/bin/stat -f '%m %N' {} + 2>/dev/null |
        /usr/bin/sort -rn | /usr/bin/head -n 3 | while IFS= read -r row; do
            report="${row#* }"
            if /usr/bin/grep -aqiE 'AirportItlwm|BlueToolFixup|IntelBTPatcher|IO80211AWDL' "$report"; then
                printf '\n--- %s ---\n' "$(basename "$report")"
                /usr/bin/head -c 131072 "$report"
            fi
        done > "$work/wireless-panics.txt"
fi

if [ "$focus" = bluetooth ] && [[ "$os_version" = 15.* ]]; then
    # Read the Intel slice without requiring Xcode or Command Line Tools.
    /usr/bin/perl - "$work/bluetoothd-x86_64.bin" >> "$work/bluetoothd-binary.txt" 2>&1 <<'PERL'
use strict;
use warnings;
my ($output) = @ARGV;
my $path = '/usr/sbin/bluetoothd';
open my $input, '<:raw', $path or die "$path: $!";
read($input, my $head, 8) == 8 or die 'Incomplete Mach-O header';
my ($magic, $count) = unpack('NN', $head);
my ($offset, $size);
if ($magic == 0xcffaedfe && unpack('V', substr($head, 4)) == 0x01000007) {
    ($offset, $size) = (0, -s $path);
} elsif (($magic == 0xcafebabe || $magic == 0xcafebabf) && $count <= 32) {
    my $width = $magic == 0xcafebabf ? 32 : 20;
    for (1 .. $count) {
        read($input, my $entry, $width) == $width or die 'Incomplete FAT table';
        next unless unpack('N', $entry) == 0x01000007;
        ($offset, $size) = unpack($width == 32 ? 'Q>Q>' : 'NN', substr($entry, 8));
        last;
    }
}
defined($size) && $size > 0 && $size <= 16777216 && $offset + $size <= -s $path
    or die 'No Intel slice within the diagnostic size budget';
seek($input, $offset, 0) or die "Seek: $!";
open my $out, '>:raw', $output or die "$output: $!";
my $left = $size;
while ($left > 0) {
    my $got = read($input, my $data, $left > 65536 ? 65536 : $left);
    $got or die 'Read failed before the end of the Intel slice';
    print {$out} $data or die "Write: $!";
    $left -= $got;
}
close $out or die "Close: $!";
print "x86_64 slice bytes: $size; file offset: $offset\n";
PERL
    if [ "$?" -eq 0 ]; then
        /usr/bin/shasum -a 256 "$work/bluetoothd-x86_64.bin" |
            /usr/bin/awk '{ print "x86_64 slice SHA256: " $1 }' >> "$work/bluetoothd-binary.txt"
    else
        /bin/rm -f -- "$work/bluetoothd-x86_64.bin"
    fi
fi

archive="$base/EricWirelessDiagnostics-$boot_build-$(/bin/date +%Y%m%d-%H%M%S)-${work##*.}.zip"
if ! /usr/bin/zip -q -9 -X -j "$archive" "$work"/*; then
    echo "Archive could not be written."
    exit 1
fi
bytes="$(/usr/bin/stat -f %z "$archive")"
if [ "$bytes" -ge 24000000 ]; then
    /bin/rm -f -- "$archive"
    echo "Diagnostics exceeded the 24 MB attachment budget."
    exit 1
fi
/bin/chmod 600 "$archive"
if [ -n "${SUDO_UID:-}" ]; then
    /usr/sbin/chown "$SUDO_UID:${SUDO_GID:-0}" "$archive"
fi
printf 'Send privately: %s (%s bytes)\n' "$archive" "$bytes"
