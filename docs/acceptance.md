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

Do not claim that `SIGKILL` of the guard while allowed remains closed: this is a documented limitation. If intentionally testing it, record the open interval and verify launchd recovery. Likewise, boot-time traffic before PF/service activation is not covered by the guarantee.

## PF coexistence

Capture root `pfctl -sr`, relevant nested anchors and PF references before installation. Confirm the guard attaches first, normal updates change only its anchor, and unlock releases only its own reference. Verify Internet Sharing, VM networking and other PF users if they are part of your setup. The initial main-ruleset reload deserves separate review.

## Releasing results

Publish only sanitized results: OS/Surge versions, scenario pass/fail/inconclusive, measured latency range and remaining limitations. Exclude node IPs, profiles, usernames, device IDs, service UUIDs, logs and raw captures. A release should remain experimental until these tests have been completed.
