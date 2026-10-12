#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
    echo "Usage: install-helper.sh <monitor-base64> <launch-daemon-base64>" >&2
    exit 64
fi

monitor_base64=$1
plist_base64=$2
helper_path=/Library/PrivilegedHelperTools/app.lidawake.LidAwake.power-monitor
plist_path=/Library/LaunchDaemons/app.lidawake.LidAwake.power-monitor.plist
label=app.lidawake.LidAwake.power-monitor
support_dir="/Library/Application Support/Lid Awake (Public Build)"
active_file="$support_dir/override-active"
baseline_file="$support_dir/baseline"
status_file="$support_dir/status"
effective_file="$support_dir/effective"
temporary=$(/usr/bin/mktemp -d /tmp/LidAwake.XXXXXX)

cleanup() {
    /bin/rm -rf "$temporary"
}
trap cleanup EXIT HUP INT TERM

write_value() {
    path=$1
    value=$2
    temporary_value="$path.tmp.$$"
    if ! printf '%s\n' "$value" > "$temporary_value"; then
        return 1
    fi
    /usr/sbin/chown root:wheel "$temporary_value" || return 1
    /bin/chmod 644 "$temporary_value" || return 1
    /bin/mv -f "$temporary_value" "$path" || return 1
}

read_effective() {
    output=$(/usr/bin/pmset -g everything 2>/dev/null) || return 1
    printf '%s\n' "$output" | /usr/bin/awk '
        $0 == "System-wide power settings:" { in_system = 1; next }
        in_system && /^INVOKE:/ { exit }
        in_system && $0 == "Currently in use:" { saw_current = 1; next }
        in_system && $1 == "SleepDisabled" {
            count++
            if ($2 == "0" || $2 == "1") value = $2
            else invalid = 1
        }
        END {
            if (!in_system || !saw_current || invalid || count > 1) exit 1
            if (count == 1) print value
            else print "0"
        }
    '
}

service_loaded() {
    /bin/launchctl print "system/$label" >/dev/null 2>&1
}

stop_monitor() {
    if service_loaded; then
        /bin/launchctl bootout "system/$label" >/dev/null 2>&1 || return 1
    fi
}

start_monitor() {
    /bin/launchctl enable "system/$label" >/dev/null 2>&1 || return 1
    if ! service_loaded; then
        /bin/launchctl bootstrap system "$plist_path" >/dev/null 2>&1 || return 1
    fi
    /bin/launchctl kickstart -k "system/$label" >/dev/null 2>&1 || return 1
}

restore_baseline() {
    if [ ! -e "$active_file" ]; then
        [ ! -e "$baseline_file" ] || return 1
        return 0
    fi
    [ -r "$active_file" ] || return 1
    active=$(/bin/cat "$active_file") || return 1
    case "$active" in
        0) return 0 ;;
        1) ;;
        *) return 1 ;;
    esac

    [ -r "$baseline_file" ] || return 1
    baseline=$(/bin/cat "$baseline_file") || return 1
    case "$baseline" in
        0|1) ;;
        *) return 1 ;;
    esac

    current=$(read_effective) || return 1
    if [ "$current" != "$baseline" ]; then
        /usr/bin/pmset -a disablesleep "$baseline" >/dev/null 2>&1 || return 1
    fi
    actual=$(read_effective) || return 1
    [ "$actual" = "$baseline" ] || return 1
    write_value "$active_file" 0
}

publish_failure() {
    current=$(read_effective) || current=unknown
    write_value "$effective_file" "$current" || true
    write_value "$status_file" error || true
}

failed_start() {
    reason=$1
    if ! stop_monitor; then
        publish_failure
        echo "$reason The monitor could not be stopped safely, so its recovery files were preserved." >&2
        exit 1
    fi

    if restore_baseline && /bin/launchctl disable "system/$label" >/dev/null 2>&1; then
        /bin/rm -f "$plist_path" "$helper_path"
        /bin/rm -rf "$support_dir"
        echo "$reason" >&2
        exit 1
    fi

    publish_failure
    if ! start_monitor; then
        echo "$reason Sleep restoration could not be confirmed; the helper and recovery files were preserved, but macOS could not restart the monitor." >&2
    else
        echo "$reason Sleep restoration could not be confirmed; the helper and recovery files were preserved and the monitor was restarted to retry." >&2
    fi
    exit 1
}

printf '%s' "$monitor_base64" | /usr/bin/base64 -D > "$temporary/monitor.sh"
printf '%s' "$plist_base64" | /usr/bin/base64 -D > "$temporary/daemon.plist"
/usr/bin/plutil -lint "$temporary/daemon.plist" >/dev/null

/bin/mkdir -p /Library/PrivilegedHelperTools /Library/LaunchDaemons "$support_dir"
/usr/sbin/chown root:wheel /Library/PrivilegedHelperTools /Library/LaunchDaemons "$support_dir"
/bin/chmod 755 /Library/PrivilegedHelperTools /Library/LaunchDaemons "$support_dir"
/usr/bin/install -o root -g wheel -m 755 "$temporary/monitor.sh" "$helper_path"
/usr/bin/install -o root -g wheel -m 644 "$temporary/daemon.plist" "$plist_path"

if [ ! -e "$active_file" ] && [ -e "$baseline_file" ]; then
    echo "The saved helper state is missing. Existing recovery files were preserved." >&2
    exit 1
fi
if [ ! -e "$active_file" ]; then
    write_value "$active_file" 0
fi
if [ ! -e "$status_file" ]; then
    write_value "$status_file" starting
fi
if [ ! -e "$effective_file" ]; then
    write_value "$effective_file" unknown
fi

if ! stop_monitor; then
    echo "The existing monitor could not be stopped safely. Its files were preserved." >&2
    exit 1
fi
if ! /bin/launchctl enable "system/$label"; then
    failed_start "macOS could not enable the background monitor."
fi
if ! /bin/launchctl bootstrap system "$plist_path"; then
    failed_start "macOS could not start the background monitor."
fi
if ! /bin/launchctl kickstart -k "system/$label"; then
    failed_start "macOS could not start the background monitor."
fi
