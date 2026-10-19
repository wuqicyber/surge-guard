#!/bin/sh
set -eu

if [ "$(id -u)" -eq 0 ]; then
    printf '%s\n' 'Run this script as your normal user, without sudo.' >&2
    exit 1
fi
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
guard_bin=/Library/PrivilegedHelperTools/surge-guard
user_dir="$HOME/Library/Application Support/SurgeGuard"

if [ ! -x "$project_dir/.build/release/surge-gate" ] || [ ! -x "$guard_bin" ]; then
    printf '%s\n' 'Build both executables and install the system guard first. See README.' >&2
    exit 1
fi
case "$("$guard_bin" --help)" in
    *swiftbar*) ;;
    *) printf '%s\n' 'Upgrade the system guard before installing the new user companion.' >&2; exit 1 ;;
esac
if [ "$#" -gt 1 ]; then
    printf '%s\n' 'Usage: scripts/install-user.sh [--menu-only | SWIFTBAR_PLUGIN_DIRECTORY]' >&2
    exit 1
fi

"$project_dir/.build/release/surge-gate" install
install -m 700 "$project_dir/integrations/swiftbar/surge-guard.5s.sh" "$user_dir/bin/surge-guard-menu"
if [ "${1:-}" = --menu-only ]; then
    printf '%s\n' 'User service and menu renderer installed. Call the renderer with --section from your existing plugin.'
    exit 0
fi
plugin_dir=${1:-$(/usr/bin/defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)}
if [ -z "$plugin_dir" ] || [ ! -d "$plugin_dir" ]; then
    printf '%s\n' 'No SwiftBar plugin directory found. The user service is installed; pass a plugin directory to install the menu.'
    exit 0
fi
plugin="$plugin_dir/surge-guard.5s.sh"
if [ -f "$plugin" ]; then
    mkdir -p "$user_dir/backups"
    cp -p "$plugin" "$user_dir/backups/surge-guard.$(date +%Y%m%d-%H%M%S).sh"
fi
install -m 700 "$project_dir/integrations/swiftbar/surge-guard.5s.sh" "$plugin"
printf 'SwiftBar plugin installed: %s\n' "$plugin"
printf '%s\n' 'Refresh SwiftBar. For one combined menu, use --menu-only instead and follow README.'
