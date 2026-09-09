# Surge Guard

**Experimental macOS network gate: allow networking while Surge Enhanced Mode is ready; block outgoing IP traffic otherwise.**

This is an independent, unofficial utility, not a Surge feature. It preserves Surge's existing proxy groups and `DIRECT` rules when ready. No router changes, node credentials, Surge profile access, or third-party runtime dependencies are needed. [简体中文](README.zh-CN.md)

**This is a reactive userspace guard, not a zero-leak VPN kill switch.** There are transition, early-boot and service-crash windows. Syntax/unit tests do not establish live leak protection. See [limitations](#limitations) and the [acceptance procedure](docs/acceptance.md) before installation.

## Behavior

| Condition | Desired state after the guard processes the change |
| --- | --- |
| Surge closed | Blocked |
| Surge open, Enhanced Mode off | Blocked |
| Surge starting or VIF not ready | Blocked |
| Signed Surge process + connected Surge extension + active VIF/IPv4 route + safe global IPv6 state | Allowed |
| Enhanced Mode stops or Surge exits | Blocked |
| Tailscale or another VPN is active without Surge | Blocked |
| Surge Enhanced Mode becomes ready again | Allowed |
| Ordinary guard shutdown | Leave blocked rules installed |

“Blocked” leaves Wi-Fi/Ethernet enabled. It permits loopback and a narrow set of DHCP/IPv6 link-configuration packets so the underlying network can recover. It blocks ordinary incoming and outgoing Internet/LAN traffic, including DNS, HTTP(S), QUIC and general ICMP, in both IP families. Blocking new inbound traffic also prevents other PF rules from creating fresh inbound states whose replies could bypass an outbound-only block. There is no general VPN-endpoint, APNs or captive-portal exception. Use the explicit `unlock` command for a captive portal when necessary.

“Allowed” removes only this utility's blocking rules. **It does not prove that every application uses Surge**, does not override Surge exclusions, and does not force traffic away from other VPNs while Surge is ready. Surge's `DIRECT` is intentionally supported. This is readiness gating, not continuous proxy-only enforcement.

## Requirements

- macOS 13 or newer; Swift 5.9+ to build (Xcode Command Line Tools).
- Surge Mac with Network Extension Enhanced Mode. Gateway VM alone is not supported.
- Administrator access to install/manage PF and the system service.
- A PF configuration containing the standard `anchor "com.apple/*"` attachment. Other custom filter rules preceding it require manual review.

The initial detection targets Surge's signed identity `com.nssurge.surge-mac` / team `YCKFLA6N72`, extension `com.nssurge.surge-mac.ne`, and VIF address `198.18.0.1`. Interface numbers and VPN service display names are not hardcoded. If Surge changes these identities/addresses, detection stays blocked until updated.

## Build and inspect (no network changes)

```sh
swift run surge-guard-tests
swift build -c release --product surge-guard
.build/release/surge-guard check
.build/release/surge-guard rules
```

`check` exits 0 when readiness checks pass, 1 otherwise. It reports only readiness; it does not claim the firewall is enabled. `rules` prints the blocking policy. Tests use `pfctl -n` only, never enable PF or disconnect a VPN.

## Install and start

Keep a local Terminal window open and save this recovery command first:

```sh
sudo /Library/PrivilegedHelperTools/surge-guard unlock
```

Then, from the source checkout:

```sh
sudo .build/release/surge-guard install
sudo /Library/PrivilegedHelperTools/surge-guard start
sudo /Library/PrivilegedHelperTools/surge-guard status
```

Installation writes a root-owned binary, LaunchDaemon, default-block anchor file and a clearly marked attachment in `/etc/pf.conf`. It saves the original configuration at `/private/etc/pf.conf.surge-guard.backup`. Install does not change live PF rules, but **the installed daemon will run at the next boot even if you have not run `start`**.

`start` attaches the rules to live PF and loads the service. The first attachment reloads the main `/etc/pf.conf` without a global flush; this can still replace dynamic rules in the main ruleset. Ordinary updates only change `io.github.surge-guard`. The utility refuses to run if its live attachment is not the first filter rule. Review existing PF integration before using it with other firewall software.

Startup briefly blocks and terminates pre-existing IP connections involving the Mac, even if Surge is already ready. Downloads, SSH and this machine's remote sessions can be interrupted. Perform installation and live testing locally, not over a connection that this utility will block.

## Recover or remove

```sh
# Stop the service, remove its live rules and release its own PF reference.
sudo /Library/PrivilegedHelperTools/surge-guard unlock

# Remove the installation permanently, preserving other pf.conf content.
sudo /Library/PrivilegedHelperTools/surge-guard uninstall
```

`unlock` is temporary: `start` or the next reboot re-arms the service. `uninstall` removes the installed binary, LaunchDaemon, anchor file and exact managed configuration block. It retains the original backup and an inert runtime lock directory. An empty live anchor call may remain until the next PF reload/reboot; it contains no rules. No automatic restoration from the old backup overwrites subsequent user changes.

If the binary is unavailable, run these commands in a **local** Terminal, in order:

```sh
sudo launchctl bootout system/io.github.surge-guard
sudo pfctl -a io.github.surge-guard -F rules
```

If `bootout` says the service is not found, continue with the second command. If it fails for another reason, resolve that first so a running guard cannot immediately reapply blocking. This emergency procedure leaves the PF enable reference in place; use the binary's `unlock` later for cleanup. Do not disable PF globally or flush other services' rules.

## Implementation

The daemon reads SystemConfiguration directly and verifies the running Surge code signature. It requires the primary service to belong to Surge, its Network Extension to be connected, its VIF to be up with the expected address, the IPv4 default route to select that VIF, and any global IPv6 primary interface to select the same VIF. It never runs Surge or its user-owned CLI as root.

SystemConfiguration notifications trigger immediate reconciliation. A validated Surge PID is cached and watched for exit. A 0.5-second timer covers missed readiness notifications, while full PF integrity is audited every five seconds and on network changes. It does not subscribe to raw route-query notifications, avoiding the `route get` / `route monitor` feedback loop. External system commands have bounded output and operation-specific timeouts. No shell strings or user-supplied commands are executed as root.

The guard reads back PF enablement, attachment and anchor content on forced and periodic audits. Unexpected changes trigger blocking before readiness is checked again. A PF failure logs an error, attempts to verify fail-closed rules, and exits so launchd can restart it. Failure to program PF is an error, **not a claim that the Mac is protected**. States involving local addresses are terminated on block transitions; a global `pfctl -Fa`/`-F states` is never used. PF ownership is tracked using `-E`/`-X` references.

Key events are written both to the unified log and a root-only, 1 MiB rotating file. Neither log records application traffic, destinations or packet contents:

```sh
sudo tail -n 100 /private/var/db/surge-guard/events.log
log show --last 1d --style compact \
  --predicate 'process == "surge-guard" AND eventMessage BEGINSWITH "surge-guard:"'
```

Boot initialization verifies and, if absent, attaches the managed PF anchor itself; it does not require Apple's PF loader to have run first. It then blocks before evaluating Surge. This makes initialization independent of daemon ordering, **not a guarantee of being the first process or preceding every boot-time packet**. Locks and PF reference tokens live in the root-owned `/private/var/db/surge-guard`; stale tokens are validated against the live PF reference list after reboot.

## Limitations

- The nominal timer interval is **not an upper bound** on block latency; scheduling, probes and PF operations add time. Apps may send packets between Surge stopping and the rule being applied.
- `RunAtLoad` does **not** order the service ahead of all early-boot networking. A static on-disk rule is not protection until PF is enabled and that rule is loaded.
- While allowed, the guard has an empty blocking anchor. `SIGKILL`, a hung process, kernel failure, or an unavailable launchd restart can leave it open. Ordinary signal cleanup does not fix this class of failure.
- Ready means the local Surge takeover is established, not that every proxy server or website is reachable. There is no Internet health-check dependency that could deadlock recovery.
- Apple does not support third-party VPN products relying on PF/routing changes as a stable integration API. OS upgrades and other Network Extensions require revalidation.
- No protection against an administrator intentionally altering the guard/PF, malware with root access, or applications bypassing Surge while the gate is allowed.
- DHCP and limited IPv6 link configuration are intentional exceptions; “blocked” does not mean absolutely no packets on the link.

For a hard guarantee that non-VPN traffic never exits, including the guard dying or before user services start, use a VPN/traffic-enforcement architecture designed to enforce that invariant. This project cannot add such a guarantee to Surge from an external status watcher.

## Verification status

The repository provides unit tests, native PF syntax validation, a release build workflow and read-only readiness diagnostics. **Live blocking, recovery, restart and sleep/wake acceptance must be run on the target Mac before relying on it.** A green CI check does not certify leakage behavior. See [docs/acceptance.md](docs/acceptance.md).

## References and license

Original implementation, MIT licensed. Architectural references (no source copied):

- [vpn-kill-switch/killswitch](https://github.com/vpn-kill-switch/killswitch): persistent PF rules.
- [subeax/killswitch-macos](https://github.com/subeax/killswitch-macos): scoped anchors and explicit exceptions.
- [Mullvad security design](https://github.com/mullvad/mullvadvpn-app/blob/main/docs/security.md): readiness states and link-configuration exemptions.
- [Surge Enhanced Mode](https://manual.nssurge.com/features/enhanced-mode.html).
- [Apple: Filter and tunnel network traffic with NetworkExtension](https://developer.apple.com/videos/play/wwdc2025/234/).

Surge is a separate commercial product; this project is not affiliated with or endorsed by its developer.
