#!/bin/bash
# This script runs as the user. Only fixed system/installed commands use sudo.
set -euo pipefail
guard_bin=/Library/PrivilegedHelperTools/surge-guard
label=io.github.surge-guard
action=${1:---help}
if [ "$#" -gt 1 ]; then printf '%s\n' 'Expected one action.' >&2; exit 2; fi
case "$action" in
    --help) printf '%s\n' 'Actions: restart, start, unlock, backup, rollback, restore-policy, logs, follow-logs, audit-logs, audit-requests, doctor, open-surge'; exit 0 ;;
    restart|start|unlock|backup|rollback|restore-policy|logs|follow-logs|audit-logs|audit-requests|doctor|open-surge) ;;
    *) printf '%s\n' 'Unknown recovery action.' >&2; exit 2 ;;
esac
if [ "$(id -u)" -eq 0 ]; then printf '%s\n' 'Run this menu action as your normal user.' >&2; exit 1; fi
if [ "$action" = open-surge ]; then exec /usr/bin/open -a Surge; fi

service_pid() {
    local service_text query_status pid
    if service_text=$(sudo -n /bin/launchctl print "system/$label" 2>&1); then
        pid=$(printf '%s\n' "$service_text" | /usr/bin/awk '/^[[:space:]]*pid =/ {print $3}')
        case "$pid" in
            '')
                if [[ "$service_text" = *'state = running'* ]]; then
                    printf '%s\n' 'Cannot confirm the running guard PID; refusing recovery.' >&2
                    return 1
                fi ;;
            *[!0-9]*|0) printf '%s\n' 'Invalid guard PID; refusing recovery.' >&2; return 1 ;;
        esac
        printf '%s\n' "$pid"
    else
        query_status=$?
        if [ "$query_status" -eq 113 ] && [[ "$service_text" = *'Could not find service'* ]]; then return 0; fi
        printf 'Cannot inspect guard service (status %s); refusing recovery: %s\n' "$query_status" "$service_text" >&2
        return 1
    fi
}
wait_exit() {
    old_pid=$1
    [ -n "$old_pid" ] || return 0
    attempts=0
    while sudo -n /bin/kill -0 "$old_pid" 2>/dev/null; do
        attempts=$((attempts + 1))
        if [ "$attempts" -ge 20 ]; then
            printf '%s\n' 'Previous guard did not exit within 20s. Refusing to clear rules while it can reapply them.' >&2
            return 1
        fi
        /bin/sleep 1
    done
}

modern=0
case "$action" in
    unlock|logs|follow-logs|audit-logs|audit-requests) ;; # Independent actions must never invoke a broken/hung guard binary.
    *)
        help_text=$("$guard_bin" --help 2>/dev/null || true)
        case "$help_text" in *restore-policy*) modern=1 ;; esac
        case "$action" in
            backup|rollback|restore-policy)
                if [ "$modern" -ne 1 ]; then
                    printf '%s\n' 'The installed legacy guard has no trusted backup/rollback commands. Upgrade only after this recovery menu is present.' >&2
                    exit 1
                fi ;;
        esac ;;
esac
printf 'surge-guard · %s\n' "$action"
case "$action" in
    restart|start) printf '%s\n' 'Connections may briefly reset. Protection remains armed. Waiting for the actual result; do not click repeatedly.' ;;
    unlock) printf '%s\n' 'WARNING: this explicitly removes surge-guard protection until Start guard or next boot. Other PF anchors remain unchanged.' ;;
    rollback) printf '%s\n' 'Restores the previous binary, service and policy. An older version may have fewer protection checks. Connections may reset.' ;;
    restore-policy) printf '%s\n' 'Restores the policy saved before the last change. Its allowed routes may differ.' ;;
esac
sudo -v
if [ "$action" = logs ] || [ "$action" = follow-logs ] || [ "$action" = audit-logs ] || [ "$action" = audit-requests ]; then
    renderer="$HOME/Library/Application Support/SurgeGuard/bin/surge-guard-ui"
    if [ ! -x "$renderer" ]; then printf '%s\n' 'Reinstall the user menu renderer to format logs.' >&2; exit 1; fi
    tail_args=(-n 200)
    if [ "$action" = follow-logs ]; then tail_args+=(-F); fi
    log_path=/private/var/db/surge-guard/events.log
    if [ "$action" = audit-logs ]; then log_path=/private/var/db/surge-guard/packet-audit/events.log; fi
    if [ "$action" = audit-requests ]; then log_path=/private/var/db/surge-guard/packet-audit/requests.log; fi
    # Only the fixed tail command is privileged; the formatter stays unprivileged.
    sudo /usr/bin/tail "${tail_args[@]}" "$log_path" | "$renderer" format-logs
    exit 0
fi
if [ "$action" = unlock ]; then
    # Independent of the guard executable, policy, renderer and network.
    old_pid=$(service_pid)
    if sudo -n /bin/launchctl print "system/$label" >/dev/null 2>&1; then
        sudo -n /bin/launchctl bootout "system/$label"
    fi
    wait_exit "$old_pid"
    sudo -n /sbin/pfctl -a "$label" -F rules
    rules=$(sudo -n /sbin/pfctl -a "$label" -sr)
    [ -z "$rules" ] || { printf '%s\n' 'ERROR: guard rules are still present.' >&2; exit 1; }
    printf '%s\n' 'Verified: guard service stopped and its anchor empty. Protection is OFF. Use Start guard to re-arm.'
    exit 0
fi
if [ "$modern" -eq 1 ]; then exec sudo "$guard_bin" "$action"; fi

# Legacy support lets recovery be installed BEFORE upgrading the root daemon.
case "$action" in
    doctor) exec sudo "$guard_bin" status ;;
    start) sudo "$guard_bin" start ;;
    restart)
        old_pid=$(service_pid)
        if [ -n "$old_pid" ]; then
            sudo -n /bin/launchctl kill SIGTERM "system/$label"
        else
            sudo "$guard_bin" start
        fi ;;
esac
attempts=0
while [ "$attempts" -lt 20 ]; do
    new_pid=$(service_pid)
    if [ -n "$new_pid" ] && [ "$new_pid" != "${old_pid:-}" ]; then
        rules=$(sudo -n /sbin/pfctl -a "$label" -sr)
        if "$guard_bin" check >/dev/null 2>&1 && [ -z "$rules" ]; then
            printf 'Legacy service recovered: pid=%s, readiness passed, guard anchor empty. Routing checks are not supported by this version.\n' "$new_pid"
            sudo "$guard_bin" status
            exit 0
        fi
    fi
    attempts=$((attempts + 1))
    /bin/sleep 1
done
printf '%s\n' 'Recovery did not reach ALLOWED within 20s. Inspect logs/diagnostics; use Emergency remove block if connectivity is urgently needed.' >&2
exit 1
