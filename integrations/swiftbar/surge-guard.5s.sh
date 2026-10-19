#!/bin/sh
# <xbar.title>Surge Guard</xbar.title>
# <xbar.desc>Surge readiness, routing policy, firewall and application startup.</xbar.desc>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>

if [ ! -x /Library/PrivilegedHelperTools/surge-guard ]; then
    printf '%s\n' '🟠 | size=13' '---' 'Surge Guard is not installed'
    exit 0
fi
exec /Library/PrivilegedHelperTools/surge-guard swiftbar "$@"
