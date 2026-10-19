# Surge Guard

A macOS network gate, application-startup companion and SwiftBar menu for Surge.

- **surge-guard** is a root LaunchDaemon. It blocks ordinary IP networking until
  Surge Enhanced Mode is ready, optionally requiring specific routing decisions.
- **surge-gate** is a normal-user LaunchAgent. It starts Surge, waits for recent
  verified firewall status, restores applications and checkpoints the session.
- **SwiftBar** reads the same status and provides diagnostics and management.

Public code and examples are generic. Domains, groups, proxy names and app lists
belong in each machine's local configuration. No proxy credentials are required.
[简体中文](README.zh-CN.md)

This is an independent, experimental utility. Enhanced Mode captures normal
application traffic through Surge; Surge may then select a proxy or DIRECT.
The external guard is **reactive readiness gating**, not proof that every packet
is forced through Surge. Transition, early-boot and guard-crash windows remain.
Read the [limits](#limits) and [acceptance procedure](docs/acceptance.md).

## Agent entry point

Start here when inspecting or deploying on another Mac:

1. Read this file and `AGENTS.md`. Inspect existing services/configuration before
   changing them. Keep local settings, logs and diagnostics out of Git.
2. Run the read-only build and condition checks below. A successful `check` is
   not evidence that the firewall service is installed or protecting the Mac.
3. Choose an explicit policy mode; validate and probe that local configuration.
4. Install the offline recovery menu **before** any privileged changes. Verify
   its entries exist, then update the system component and verify `status`.
   Install the user companion last. Do not run the user installer with sudo.
5. Use `doctor` and retained logs for failures. Record live tests separately from
   syntax/unit checks. Do not silently unlock networking to make a test pass.

No Trellis setup, Python runtime, package manager or third-party library is needed.

## Requirements and source map

macOS 13+, Swift 5.9+ / Xcode Command Line Tools, administrator access for PF, and
Surge Mac Network Extension Enhanced Mode. Routing checks require a Surge CLI
supporting `status --raw` and `rule explain` (Surge Mac 6.9+). Gateway VM alone
is not supported. SwiftBar is optional.

| Location | Responsibility |
| --- | --- |
| `Sources/SurgeGuardCore` | Configuration, signature/extension/VIF/route probes, bounded commands, PF, status and logs |
| `Sources/SurgeGuard` | System daemon, management CLI and menu renderer |
| `Sources/SurgeGate` | Native user-session companion; no Python or app wrapper |
| `integrations/swiftbar` | Thin portable plugin |
| `scripts/install-user.sh` | User companion and menu installer |
| `examples` | Generic policy and app configuration |
| `Tests/SurgeGuardTests` | Standalone non-mutating checks |

## Build and inspect — no network changes

```sh
scripts/check.sh
.build/release/surge-guard check --json
.build/release/surge-guard status --json
.build/release/surge-guard rules
```

The validation script builds both executables, runs tests and validates examples.
It never loads PF, quits apps or installs services. The command-line checks are
read-only. `status` can be `unknown` before the new daemon is installed.

## Choose the policy

The default preserves the original readiness-only behavior:

```json
{"version":1,"mode":"enhanced","route_checks":[]}
```

All six checks must pass: official signed Surge process, Surge's primary network
service, connected extension, expected active VIF, IPv4 default route through
that VIF, and no conflicting global IPv6 primary interface. Dynamic interface
numbers are supported. Surge's identity/address are checked, not a VPN name.

For additional routing conditions, copy and edit a local policy:

```sh
cp examples/routes.json policy.local.json
# Replace the example URL, exact group and allowed final proxy names.
.build/release/surge-guard validate policy.local.json
.build/release/surge-guard check --config policy.local.json --json
```

```json
{
  "version": 1,
  "mode": "routes",
  "route_checks": [
    {
      "url": "https://example.com",
      "required_group": "Residential",
      "allowed_final_policies": ["Residential A", "Residential B"]
    }
  ]
}
```

In `routes` mode, Enhanced Mode must be ready, outbound mode must be `rule`, and
**every** route check must match the exact rule-selected group, resolve that
group and end at an allowed proxy. Nested groups are supported. DIRECT/REJECT
results, empty allowlists, invalid JSON and failed/expired CLI queries fail closed.
Changing to another allowed node is logged. No group/node/domain is hardcoded.

Surge CLI rule evaluation does not make an HTTP request to the target. It checks
the current rule decision, not real egress geography, residential-IP status or
server reachability. Process/URL/protocol-specific rules can affect actual apps;
this version evaluates the configured URL's default request context.

At most eight URL checks are accepted. Unknown config fields and credentialed
URLs are rejected. Keep secrets out of URLs, query strings and policy names:
policy/status files are locally readable so the menu can inspect them.

## Install or update the system guard

Do this locally: starting/updating briefly blocks and resets existing connections.
Prepare recovery first, as your normal user:

```sh
scripts/install-user.sh --recovery-only
```

For a combined menu, replace its Surge renderer with the `--section` invocation
below. For a standalone menu, copy `integrations/swiftbar/surge-guard.5s.sh` into
SwiftBar's configured plugin directory. Confirm **Recovery and backups / 恢复与备份**
is visible before continuing. This menu supports the legacy guard, requires no
network access and keeps an independent emergency action when a binary fails.
Keep an offline recovery command as well:

```sh
sudo /Library/PrivilegedHelperTools/surge-guard unlock
```

Apply the chosen policy before installing; omit `configure` to use the default
on first install, or retain an existing policy on update:

```sh
sudo .build/release/surge-guard configure policy.local.json
sudo .build/release/surge-guard install
```

On a **fresh install**, load the service:

```sh
sudo /Library/PrivilegedHelperTools/surge-guard start
/Library/PrivilegedHelperTools/surge-guard status --json
sudo /Library/PrivilegedHelperTools/surge-guard doctor
```

Updating a loaded service saves a root-owned backup, stops it normally, waits up
to 20 seconds for its firewall lock to be released, then replaces and restarts
it. `bootout` returning is not evidence that the old process has exited. The new
service must publish fresh verified PF status within 20 seconds; when readiness
passed before the update, it must return to `allowed`. A failure attempts to
restore and restart the previous version. Errors remain errors even if rollback
succeeds. Do not run `unlock` as an update step. If rollback also fails, use the
independent emergency menu action. An installed but unloaded service starts next boot.
For a routes-mode update, the staged new helper first verifies user-session CLI
access before stopping the old daemon. A failed preflight aborts the update;
keep Surge running during that upgrade. This preflight does not change PF.

The PF attachment must be first among filter rules. The installer retains the
original `/private/etc/pf.conf.surge-guard.backup` and refuses edited managed
blocks. Initial attachment may reload the main ruleset; review custom PF users.
Ordinary reconciliation updates only `io.github.surge-guard`.

The menu provides normal restart with result verification, Start/re-arm, Backup,
Restore previous version/config, Restore previous policy, and Emergency remove
block. Privileged actions open Terminal and explain the impact before requesting
sudo. Emergency recovery waits for the previous PID to exit and clears only this
guard's anchor; it never disables PF globally. It explicitly turns protection off
until Start or next boot. A forced `kickstart -k` is not a normal restart path.

Update/manual backups live in `/private/var/db/surge-guard/backups/<id>` with root-only
access. Each `configure` separately saves the prior policy. Backups are retained;
restoration replaces only this tool's binary, LaunchDaemon, anchor file and/or
policy, never an entire old `pf.conf`. `rollback` can restore an older guard with
fewer checks, including a legacy enhanced-only version; review its capabilities.
The first installation has no previous version to restore. The user menu/config
backup is separate from these trusted root backups.

Root never executes the user-owned Surge CLI as root. A root-owned internal
helper enters the console user's bootstrap session, drops UID/GID/groups, then
queries Surge. The daemon keeps processing readiness while these bounded probes
run in the background. A session switch, network change or changed configuration
invalidates prior results. There is no inbound control socket or user-written
file that can command root PF operations.

## Install SurgeGate and SwiftBar

As your **normal user**, after the new system guard is installed:

```sh
scripts/install-user.sh
```

This installs the user binary and LaunchAgent, migrates the old `~/.surge_gate`
configuration if present, and installs a standalone plugin in SwiftBar's configured
plugin directory. Alternatively pass the plugin directory explicitly:

```sh
scripts/install-user.sh "$HOME/Documents/SwiftBar"
```

For an existing combined control-center plugin:

```sh
scripts/install-user.sh --menu-only
```

Replace its old Surge-specific rendering function with a call to:

```sh
"$HOME/Library/Application Support/SurgeGuard/bin/surge-guard-menu" --section
```

Do not keep both old and new Surge sections. No remote-service credentials or
other private projects are part of this plugin. Normal menu text follows the
system appearance; secondary/error colors have light and dark variants.
The companion is green only with fresh running/ready status, no pending apps
and a currently verified allowed network gate. Waiting/stale states are orange;
errors are red. The display name is `SurgeGuard` without a space.

### Application configuration

Edit `~/Library/Application Support/SurgeGuard/gate.json`, using `examples/gate.json`.

| Field | Meaning |
| --- | --- |
| `startup_apps` | Bundle IDs always started after protection is ready |
| `priority_order` | Ordering among startup/restored apps |
| `excluded_apps` | Apps excluded from session recovery and ordered quits |
| `restore_session` | Restore the recorded previous-session apps |
| `delay_between_apps_seconds` | Delay between successful launches, 0–30 |
| `quit_timeout_seconds` | Normal-quit timeout, 5–300; timeout aborts shutdown |

Find an app's Bundle ID in its `Contents/Info.plist`. Display names such as
“Terminal” are not stable across languages. The companion skips Finder and Surge
in ordinary restoration. Failed launches remain pending and retry. Session files
are atomically checkpointed every 30 seconds, including pending apps; hard power
loss can lose changes since the last durable checkpoint. App documents/windows
are left to each app's own recovery mechanism.

SurgeGate waits for fresh `allowed` daemon status, including recent PF verification.
It never falls back to proxy-port or arbitrary-utun guesses. A normal-user service
cannot stop other login items from starting; the system firewall gate is what
blocks their traffic until conditions pass. SurgeGate starts Surge, but does not
silently change its Enhanced Mode preference or routing choices.

Legacy original files are retained. The old `com.user.surgegate` login task is
unloaded, and its plist is renamed to `.migrated-backup`. Unknown legacy app names
are logged for manual conversion. Keep the old files until migration is verified.

### Ordered shutdown

Use SwiftBar → **SurgeGate** → the power section at the top (blue restart,
red shutdown), or:

```sh
"$HOME/Library/Application Support/SurgeGuard/bin/surge-gate" shutdown --action restart
# Or: --action shutdown
```

The running user service handles the request independently of the calling terminal.
It saves the session, requests normal application quits, waits, quits Surge last,
verifies the system guard is blocked, then requests macOS shutdown. Apps can show
unsaved-document dialogs; a refusal/timeout aborts. It never sends SIGKILL or
`pkill -f`, and does not change macOS global restore settings. OS Automation
permission may be required for the final system request. This mechanism is not a
hook for every Apple-menu shutdown, power loss or kernel failure.

## Status, diagnostics and commands

| Command | Privileges / meaning |
| --- | --- |
| `surge-guard check --json` | Normal user; fresh conditions; exit 0 ready, 1 not ready/error |
| `surge-guard status --json` | Normal user; recent daemon/PF snapshot; exit 0 if report produced |
| `surge-guard doctor` | Normal user summary; sudo adds live PF inspection |
| `surge-guard validate FILE` | Normal user; syntax/semantic validation only |
| `sudo surge-guard configure FILE` | Validate then atomically install policy; daemon reloads automatically |
| `sudo surge-guard logs [--follow] [--json]` | Last 200 readable events; optional follow or machine JSON Lines |
| `sudo surge-guard restart` | TERM cleanup blocks before launchd restarts the daemon |
| `sudo surge-guard backup` | Save installed binary, service, anchor file and policy |
| `sudo surge-guard rollback` | Restore the last update/manual backup, restart and verify |
| `sudo surge-guard restore-policy` | Restore the policy saved before the last configure |
| `sudo surge-guard unlock` | Remove this gate temporarily; start/reboot re-arms it |
| `surge-gate status [--json]` | Normal user; companion state, pending apps and freshness |
| `surge-gate logs` / `restart` / `edit-config` | Normal user companion management |

JSON uses snake_case. `check` includes `version`, `ready`, `mode`, `readiness`,
`reasons` and optional `session`. `status` includes `state`, `daemon_running`,
`reason` and optional `snapshot`. Inspect `state`, not the exit code alone.
States are `allowed`, `blocked`, `unlocked`, `stopped` and `unknown`.

Snapshots are root-owned, tied to the current boot/PID, and expire after eight
seconds without both status and PF audit freshness. Routing results expire after
three seconds from probe start. These are stale-result cutoffs, not packet-block
latency guarantees. The daemon polls readiness every 0.5s, routing at roughly 1s,
and audits PF every 5s. Scheduling and command operations add latency.

On disk, events are JSON Lines with time, event, level, PID, message and details.
`logs` renders readable records by default: local time with UTC offset, severity,
state, explained reason and expected/actual group/final node on separate lines.
`--follow` uses the same readable format; `--json` produces machine-readable JSON
Lines, including a JSON wrapper for old plain-text events. For example:

```text
2026-01-01 12:00:00 +00:00  [WARNING] BLOCKED / 已阻断
  原因 / message: 分流策略与配置不一致 [route_policy_mismatch]: https://example.com
  ✗ https://example.com
    预期 / expected group: Residential
    实际 / actual group: Other  最终节点 / final: Node C
  配置=routes  PF=blocked  pid=123  run=example
  event=gate_changed
```

Use `gate_changed`, `route_decision_changed`, `rule_probe_failed`, `pf_unverified`,
`configuration_loaded` and `manual_unlock` to follow a decision. Logs rotate at
1 MiB. App names/URLs/policies are local diagnostic data; do not publish raw logs.
See [troubleshooting](docs/troubleshooting.md).

## Managed files and removal

| Path | Owner / purpose |
| --- | --- |
| `/Library/PrivilegedHelperTools/surge-guard` | root / system binary |
| `/Library/LaunchDaemons/io.github.surge-guard.plist` | root / boot service |
| `/Library/Application Support/SurgeGuard/policy.json` | root, 0644 / local policy |
| `/Library/Application Support/SurgeGuard/status.json` | root, 0644 / recent status |
| `/private/var/db/surge-guard/events.log` | root, 0600 / private events |
| `~/Library/Application Support/SurgeGuard/` | user / companion, app settings, session, logs, draft |
| `~/Library/LaunchAgents/io.github.surge-guard.gate.plist` | user / login service |
| SwiftBar plugin directory / `surge-guard.5s.sh` | user / optional menu entry |

```sh
"$HOME/Library/Application Support/SurgeGuard/bin/surge-gate" uninstall
sudo /Library/PrivilegedHelperTools/surge-guard uninstall
```

Remove the installed SwiftBar plugin, or the one invocation in your combined menu.
Configuration, sessions, logs and the original PF backup are retained for recovery.
Only the managed PF block is removed; unrelated PF content is preserved.

If the binary is unavailable, in a local Terminal run:

```sh
sudo launchctl bootout system/io.github.surge-guard
sudo pfctl -a io.github.surge-guard -F rules
```

If the first command says the service is absent, continue; resolve other failures
before flushing so a live daemon cannot reapply its rules. Never globally disable
PF or flush another service's rules to recover this utility.

## Limits

- Blocked mode permits loopback and narrow DHCP/IPv6 link configuration; normal
  Internet/LAN traffic and DNS are blocked. This is not zero packets on the link.
- Allowed mode clears this guard's anchor and preserves Surge policies, including
  DIRECT. It does not independently exclude physical-interface binding, alternate
  VPNs or Surge exclusions. Default-route readiness is not an unbypassable tunnel.
- RunAtLoad cannot guarantee PF is enabled before the first boot-time packet.
  SIGKILL/hangs while allowed can leave it allowed until service recovery.
- A CLI policy name is not proof of residential-IP ownership or reachability.
- macOS/Surge updates, other VPNs, Internet Sharing and custom PF require retesting.
- An administrator/root attacker can alter this guard. It is not malware isolation.

[Verification record](docs/verification.md) distinguishes completed tests from
unperformed live scenarios. MIT license. Not affiliated with Surge.

Primary references: [Enhanced Mode](https://manual.nssurge.com/features/enhanced-mode.html),
[Surge CLI](https://manual.nssurge.com/tools/cli.html),
[NetworkExtension](https://developer.apple.com/documentation/networkextension).
