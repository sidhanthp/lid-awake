#!/bin/sh
set -u

state_file=${1:-}
pmset=/usr/bin/pmset
awk=/usr/bin/awk
ioreg=/usr/sbin/ioreg
sleep_bin=/bin/sleep
support_dir="/Library/Application Support/Lid Awake (Public Build)"
baseline_file="$support_dir/baseline"
active_file="$support_dir/override-active"
pending_sleep_file="$support_dir/pending-lid-sleep"
status_file="$support_dir/status"
effective_file="$support_dir/effective"
last_target=
last_mode=
cycles=0
last_power_source=
pending_cancelled=0

write_value() {
    path=$1
    value=$2
    temporary="$path.tmp.$$"
    if ! printf '%s\n' "$value" > "$temporary"; then
        return 1
    fi
    /usr/sbin/chown root:wheel "$temporary" || return 1
    /bin/chmod 644 "$temporary" || return 1
    /bin/mv -f "$temporary" "$path" || return 1
}

read_effective() {
    output=$("$pmset" -g everything 2>/dev/null) || return 1
    printf '%s\n' "$output" | "$awk" '
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

read_lid_state() {
    output=$("$ioreg" -r -k AppleClamshellState -d 4 2>/dev/null) || return 1
    state=$(printf '%s\n' "$output" | "$awk" -F ' = ' '/"AppleClamshellState" =/ { gsub(/["[:space:]]/, "", $2); print $2; exit }')
    case "$state" in
        Yes) printf 'closed\n' ;;
        No) printf 'open\n' ;;
        *) return 1 ;;
    esac
}

read_power_source() {
    output=$("$pmset" -g batt 2>/dev/null) || return 1
    source=$(printf '%s\n' "$output" | "$awk" -F "'" '/Now drawing from/ { print $2; exit }')
    case "$source" in
        "AC Power"|"Battery Power") printf '%s\n' "$source" ;;
        *) return 1 ;;
    esac
}

publish() {
    state=$1
    effective=$2
    write_value "$effective_file" "$effective" || true
    write_value "$status_file" "$state" || true
}

while :; do
    cycles=$((cycles + 1))
    enabled=0
    if [ -n "$state_file" ] && [ -r "$state_file" ]; then
        IFS= read -r enabled < "$state_file" || enabled=0
    fi

    pending_sleep=0
    if [ "$enabled" != "1" ]; then
        if [ -e "$pending_sleep_file" ]; then
            # Persist cancellation first so a failed remove cannot turn into a
            # stale sleep request if the user enables the feature again.
            pending_cancelled=1
            write_value "$pending_sleep_file" cancelled || true
            if /bin/rm -f "$pending_sleep_file"; then
                pending_cancelled=0
            fi
        else
            pending_cancelled=0
        fi
    else
        if [ "$pending_cancelled" = "1" ]; then
            if [ ! -e "$pending_sleep_file" ]; then
                pending_cancelled=0
            else
                write_value "$pending_sleep_file" cancelled || true
                /bin/rm -f "$pending_sleep_file" && pending_cancelled=0
            fi
        fi
        if [ "$pending_cancelled" != "1" ] && [ -e "$pending_sleep_file" ]; then
            pending_value=
            if [ -r "$pending_sleep_file" ]; then
                IFS= read -r pending_value < "$pending_sleep_file" || pending_value=
            fi
            if [ "$pending_value" = "1" ]; then
                pending_sleep=1
            else
                /bin/rm -f "$pending_sleep_file" || true
            fi
        fi
    fi

    active=0
    if [ -e "$active_file" ]; then
        if [ -r "$active_file" ]; then
            IFS= read -r active < "$active_file" || active=invalid
        else
            active=invalid
        fi
    elif [ -e "$baseline_file" ]; then
        active=invalid
    fi
    case "$active" in
        0|1) ;;
        *)
            publish error unknown
            last_target=
            last_mode=error
            "$sleep_bin" 2
            continue
            ;;
    esac
    baseline=
    if [ -r "$baseline_file" ]; then
        IFS= read -r baseline < "$baseline_file" || baseline=
    fi
    if [ "$enabled" != "1" ] && [ "$active" != "1" ] && [ -n "$baseline" ]; then
        /bin/rm -f "$baseline_file"
        baseline=
    fi

    power_source=
    if [ "$enabled" = "1" ] || [ "$active" = "1" ] || [ "$pending_sleep" = "1" ]; then
        power_source=$(read_power_source) || power_source=
    fi
    if [ "$enabled" = "1" ] && [ "$last_power_source" = "AC Power" ] && [ "$power_source" = "Battery Power" ]; then
        pending_sleep=1
        # Persist the unplug event before advancing the source tracker. If this
        # write fails, the AC -> battery transition will be detected again.
        if write_value "$pending_sleep_file" 1; then
            last_power_source="Battery Power"
        fi
    elif [ "$power_source" = "AC Power" ]; then
        last_power_source="AC Power"
        if [ "$pending_sleep" = "1" ] && /bin/rm -f "$pending_sleep_file"; then
            pending_sleep=0
        fi
    elif [ "$power_source" = "Battery Power" ]; then
        last_power_source="Battery Power"
    fi

    if [ "$enabled" = "1" ] && [ -z "$baseline" ]; then
        baseline=$(read_effective) || baseline=
        if [ -n "$baseline" ] && ! write_value "$baseline_file" "$baseline"; then
            baseline=
        fi
        if [ -z "$baseline" ]; then
            publish error unknown
            last_target=
            last_mode=error
            "$sleep_bin" 2
            continue
        fi
    fi
    case "$baseline" in
        0|1) ;;
        *)
            if [ "$enabled" = "1" ] || [ "$active" = "1" ]; then
                publish error unknown
                last_target=
                last_mode=error
                "$sleep_bin" 2
                continue
            fi
            baseline=0
            ;;
    esac

    target=
    mode=off
    if [ "$enabled" = "1" ]; then
        case "$power_source" in
            "AC Power") target=1; mode=on ;;
            "Battery Power") target=0; mode=battery ;;
            *)
                if [ "$active" = "1" ]; then
                    target=$baseline
                    mode=unknown-restore
                else
                    mode=unknown
                fi
                ;;
        esac
    elif [ "$active" = "1" ]; then
        target=$baseline
        mode=restore
    fi

    check_now=0
    if [ -n "$target" ]; then
        if [ "$target" != "$last_target" ] || [ "$mode" != "$last_mode" ] || [ $((cycles % 30)) -eq 0 ]; then
            check_now=1
        fi
    elif [ "$mode" != "$last_mode" ] || [ $((cycles % 30)) -eq 0 ]; then
        check_now=1
    fi
    if [ "$pending_sleep" = "1" ] && [ "$power_source" = "Battery Power" ]; then
        check_now=1
    fi

    if [ "$check_now" = "1" ]; then
        current=$(read_effective) || current=
        if [ -z "$current" ]; then
            publish error unknown
            last_target=
            last_mode=$mode
        elif [ -z "$target" ]; then
            if [ "$mode" = "unknown" ]; then
                publish unknown "$current"
            else
                publish off "$current"
            fi
            last_target=
            last_mode=$mode
        else
            if [ "$current" != "$target" ]; then
                if [ "$target" != "$baseline" ] && [ "$active" != "1" ]; then
                    if ! write_value "$active_file" 1; then
                        publish error "$current"
                        last_target=
                        last_mode=$mode
                        "$sleep_bin" 2
                        continue
                    fi
                    active=1
                fi
                if ! "$pmset" -a disablesleep "$target" >/dev/null 2>&1; then
                    publish error "$current"
                    last_target=
                    last_mode=$mode
                    "$sleep_bin" 2
                    continue
                fi
                current=$(read_effective) || current=
            fi

            if [ "$current" != "$target" ]; then
                publish error "${current:-unknown}"
                last_target=
                last_mode=$mode
            else
                if [ "$target" = "$baseline" ] && [ "$active" = "1" ]; then
                    if ! write_value "$active_file" 0; then
                        publish error "$current"
                        last_target=
                        last_mode=$mode
                        "$sleep_bin" 2
                        continue
                    fi
                fi

                case "$mode" in
                    on) publish active "$current" ;;
                    battery) publish battery "$current" ;;
                    off|restore) publish off "$current" ;;
                    unknown-restore|unknown) publish unknown "$current" ;;
                esac
                if [ "$pending_sleep" = "1" ] && [ "$power_source" = "Battery Power" ] && [ "$current" = "0" ]; then
                    lid_state=$(read_lid_state) || lid_state=unknown
                    case "$lid_state" in
                        open)
                            if /bin/rm -f "$pending_sleep_file"; then
                                pending_sleep=0
                            else
                                publish error "$current"
                                last_target=
                                last_mode=error
                                "$sleep_bin" 2
                                continue
                            fi
                            ;;
                        closed)
                            # Re-read both inputs just before sleep so a quick
                            # reconnect or lid opening does not trigger stale sleep.
                            final_power_source=$(read_power_source) || final_power_source=unknown
                            if [ "$final_power_source" = "AC Power" ]; then
                                if /bin/rm -f "$pending_sleep_file"; then
                                    pending_sleep=0
                                fi
                                last_target=$target
                                last_mode=$mode
                                continue
                            fi
                            if [ "$final_power_source" != "Battery Power" ]; then
                                publish error "$current"
                                last_target=
                                last_mode=error
                                "$sleep_bin" 2
                                continue
                            fi
                            final_lid_state=$(read_lid_state) || final_lid_state=unknown
                            if [ "$final_lid_state" = "open" ]; then
                                if /bin/rm -f "$pending_sleep_file"; then
                                    pending_sleep=0
                                fi
                                last_target=$target
                                last_mode=$mode
                                continue
                            fi
                            if [ "$final_lid_state" != "closed" ]; then
                                publish error "$current"
                                last_target=
                                last_mode=error
                                "$sleep_bin" 2
                                continue
                            fi
                            if ! "$pmset" sleepnow >/dev/null 2>&1; then
                                publish error "$current"
                                last_target=
                                last_mode=error
                                "$sleep_bin" 2
                                continue
                            fi
                            if /bin/rm -f "$pending_sleep_file"; then
                                pending_sleep=0
                            fi
                            ;;
                        *)
                            # Keep the persisted request and retry on the next
                            # monitor cycle if ioreg cannot determine lid state.
                            publish error "$current"
                            last_target=
                            last_mode=error
                            "$sleep_bin" 2
                            continue
                            ;;
                    esac
                fi
                last_target=$target
                last_mode=$mode
            fi
        fi
    fi

    "$sleep_bin" 2
done
