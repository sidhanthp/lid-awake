#!/bin/sh
set -eu

label=app.lidawake.LidAwake.power-monitor
helper_path=/Library/PrivilegedHelperTools/app.lidawake.LidAwake.power-monitor
plist_path=/Library/LaunchDaemons/app.lidawake.LidAwake.power-monitor.plist
support_dir="/Library/Application Support/Lid Awake (Public Build)"
active_file="$support_dir/override-active"
baseline_file="$support_dir/baseline"
status_file="$support_dir/status"
effective_file="$support_dir/effective"

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

restart_monitor() {
    /bin/launchctl enable "system/$label" >/dev/null 2>&1 || return 1
    if ! service_loaded; then
        /bin/launchctl bootstrap system "$plist_path" >/dev/null 2>&1 || return 1
    fi
    /bin/launchctl kickstart -k "system/$label" >/dev/null 2>&1 || return 1
}

publish_failure() {
    current=$(read_effective) || current=unknown
    write_value "$effective_file" "$current" || true
    write_value "$status_file" error || true
}

if service_loaded; then
    if ! /bin/launchctl bootout "system/$label" >/dev/null 2>&1; then
        echo "The background monitor could not be stopped safely. It remains installed and will handle the saved setting." >&2
        exit 1
    fi
fi

active=0
if [ -e "$active_file" ]; then
    if [ -r "$active_file" ]; then
        active=$(/bin/cat "$active_file") || active=invalid
    else
        active=invalid
    fi
elif [ -e "$baseline_file" ]; then
    active=invalid
fi
case "$active" in
    0) ;;
    1)
        if [ ! -r "$baseline_file" ]; then
            publish_failure
            restart_monitor || true
            echo "The saved sleep setting is missing, so the helper and recovery files were preserved." >&2
            exit 1
        fi
        baseline=$(/bin/cat "$baseline_file") || baseline=invalid
        case "$baseline" in
            0|1) ;;
            *)
                publish_failure
                restart_monitor || true
                echo "The saved sleep setting is invalid, so the helper and recovery files were preserved." >&2
                exit 1
                ;;
        esac

        current=$(read_effective) || current=unknown
        if [ "$current" = unknown ]; then
            publish_failure
            restart_monitor || true
            echo "The current sleep setting could not be read, so the helper and recovery files were preserved." >&2
            exit 1
        fi
        if [ "$current" != "$baseline" ] && ! /usr/bin/pmset -a disablesleep "$baseline" >/dev/null 2>&1; then
            publish_failure
            restart_monitor || true
            echo "The saved sleep setting could not be restored, so the helper and recovery files were preserved." >&2
            exit 1
        fi
        actual=$(read_effective) || actual=unknown
        if [ "$actual" != "$baseline" ]; then
            publish_failure
            restart_monitor || true
            echo "The saved sleep setting could not be verified, so the helper and recovery files were preserved." >&2
            exit 1
        fi
        if ! write_value "$active_file" 0; then
            publish_failure
            restart_monitor || true
            echo "The sleep setting was restored, but the helper could not record that recovery. The helper and recovery files were preserved." >&2
            exit 1
        fi
        ;;
    *)
        publish_failure
        restart_monitor || true
        echo "The helper state is invalid, so the helper and recovery files were preserved." >&2
        exit 1
        ;;
esac

if ! /bin/launchctl disable "system/$label" >/dev/null 2>&1; then
    publish_failure
    restart_monitor || true
    echo "The sleep setting is restored, but macOS could not disable the helper. The helper and recovery files were preserved." >&2
    exit 1
fi
/bin/rm -f "$plist_path" "$helper_path"
/bin/rm -rf "$support_dir"
