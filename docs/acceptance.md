# Local acceptance procedure

Run from a local Terminal with administrative access and an offline copy of the recovery commands. These steps intentionally disrupt connections. Do not infer a pass from `check`, PF rule text, a cached page, or DNS failure alone.

## Establish a usable baseline

Before enabling the guard, verify each target/protocol works on the network and record whether IPv6 is available. Use your own controlled endpoints where possible. A test with no working baseline is inconclusive, not a pass.

Example fresh HTTPS requests that bypass proxy environment variables and DNS:

```sh
curl --noproxy '*' -4 --connect-timeout 2 --max-time 4 \
  --resolve 'one.one.one.one:443:1.1.1.1' https://one.one.one.one/ -o /dev/null

curl --noproxy '*' -6 --connect-timeout 2 --max-time 4 \
  --resolve 'one.one.one.one:443:[2606:4700:4700::1111]' https://one.one.one.one/ -o /dev/null
```

These third-party endpoints are examples, not dependencies of the guard. Use a LAN HTTP server as an additional check if available. Also establish an ongoing TCP transfer and a UDP stream to a controlled external host: already-established sessions must be checked separately from new connections.

## Scenarios

For each transition, record the time, `surge-guard check`, root `status`, logs, fresh connection results and existing TCP/UDP behavior. Capture the actual physical interfaces, including both Ethernet and Wi-Fi when present. A packet capture contains private data; keep it outside the public repository.

| Scenario | Expected after reconciliation | What it tests |
| --- | --- | --- |
| Surge closed, guard running | Fresh and established ordinary traffic stops | Closed application |
| Surge open, Enhanced Mode off | Still blocked | No UI/process-only false positive |
| Enhanced Mode starting | Blocked until all readiness checks pass | Startup state |
| Enhanced Mode ready | Existing Surge routing policy works | Proxy + DIRECT compatibility |
| Routes mode, all configured URL/group/node checks pass | Allowed after a recent user-session query | Policy gate |
| Wrong group, unlisted node, DIRECT result, or Direct/Global mode | Blocked | No route-condition bypass |
| Change to another allowlisted node | Allowed; parsed route change appears in logs | Successful decision audit |
| CLI fails, hangs, user logs out, or rule result expires | Blocked; specific reason recorded | Query failure and freshness |
| Invalid/missing installed policy | Blocked; no readiness-only fallback | Configuration failure |
| Old boot/PID or stale status/PF audit | Menu reports unknown/stopped; Gate does not restore apps | No cached green status |
| Turn Enhanced Mode off | Blocked; measure actual latency | Toggle path |
| Quit or force-quit Surge | Blocked; measure actual latency | Process/extension exit |
| Another VPN active, Surge off | Blocked | Wrong-tunnel rejection |
| Turn Surge Enhanced Mode back on | Fresh networking recovers | Recovery without DNS deadlock |
| Change Wi-Fi / attach Ethernet | Re-evaluate current interfaces | No fixed en0/utun assumption |
| Sleep and wake | Reconcile current state | Stale interface handling |
| Normal guard termination | Block left installed; launchd restarts | Shutdown cleanup |
| Manual `unlock` | Guard stops; its rules clear | Offline recovery |
| Reboot after `unlock` | Installed service re-arms after starting | Temporary unlock semantics |
| `uninstall`, then reboot | Guard does not return | Permanent removal |

## Companion and menu acceptance

Use a disposable/saved application session. Validate both light and dark menu
appearance, current reasons, diagnostics, retained-then-follow logs, policy draft
validation/application, normal restart and explicit temporary unlock. There must
be one Surge section, and no green protection label based only on a PID.

Before a system upgrade, confirm the independent recovery menu is installed and
works offline with the currently installed version. Back up files first. Test a
normal restart: a new PID and fresh PF status must be observed, or a timeout and
reason shown. Do not use repeated `kickstart -k`. Exercise delayed old-process
cleanup and an update failure in a controlled environment; verify automatic
restoration and retain both failure/rollback logs. Confirm separate version and
policy backups, restore commands, legacy capability warnings, and that an old
whole `pf.conf` is never restored. On explicit emergency removal, the previous
PID must be gone before anchor clearing; verify protection-off display and
Start/re-arm. Never silently use emergency removal to pass an upgrade test.

Verify the companion waits on recent system `allowed` status before each app
launch. Test bundle IDs, ordering, an absent app, failed launch retry and a changed
excluded-app setting. Confirm no lost pending apps. Verify periodic atomic
session checkpoints and recovery after a user-service restart. An app inventory
failure must retain the previous record rather than overwrite it with empty data.

On a saved/disposable session, test an app refusing normal quit or showing an
unsaved-document prompt. Ordered shutdown must abort without SIGKILL/pkill, keep
Surge until other apps finish, and retain the pre-shutdown session. Only request
OS shutdown after Surge exits and the firewall is verified blocked. Check cancelled
OS shutdown recovery and that snapshots cannot overwrite the retained session.

Test the legacy migration using copied local data, confirm original files remain,
and confirm only one companion LaunchAgent runs. Do not publish the legacy data.

Do not claim that `SIGKILL` of the guard while allowed remains closed: this is a documented limitation. If intentionally testing it, record the open interval and verify launchd recovery. Likewise, boot-time traffic before PF/service activation is not covered by the guarantee.

## PF coexistence

Capture root `pfctl -sr`, relevant nested anchors and PF references before installation. Confirm the guard attaches first, normal updates change only its anchor, and unlock releases only its own reference. Verify Internet Sharing, VM networking and other PF users if they are part of your setup. The initial main-ruleset reload deserves separate review.

## Releasing results

Publish only sanitized results: OS/Surge versions, scenario pass/fail/inconclusive, measured latency range and remaining limitations. Exclude node IPs, profiles, usernames, device IDs, service UUIDs, logs and raw captures. A release should remain experimental until these tests have been completed.
