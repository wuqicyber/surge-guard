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
| Wrong group, unlisted node when a list is configured, DIRECT result, or Direct/Global mode | Blocked | No route-condition bypass |
| Group-only policy with a changed proxy in the same group, or another allowlisted proxy when a list is configured | Allowed; parsed route change appears in logs | Group-only matching and optional node restriction |
| CLI fails, hangs, user logs out, or rule result expires | Blocked; specific reason recorded | Query failure and freshness |
| Invalid/missing installed policy | Blocked; no readiness-only fallback | Configuration failure |
| Old boot/PID or stale status/PF audit | Menu reports unknown/stopped; Gate does not restore apps | No cached green status |
| Turn Enhanced Mode off | Blocked; measure actual latency | Toggle path |
| Graceful Surge update begins disconnecting | Native tunnel event triggers blocking before remaining probes | Early-disconnect subscription; record rule-load and old-state-cleanup times separately |
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

For early-disconnect acceptance, correlate the native tunnel status with the
`readiness_loss_blocked` event and a physical-interface capture. Test graceful
disconnect and abrupt loss separately; an early graceful callback does not prove
the crash path has no gap. Record actual packet behavior through rule loading
and state cleanup. A successful notification subscription, parser test or new
binary installation is not live no-bypass acceptance.

## Egress observation

For egress logging acceptance, use the read-only `observe-egress --json` command
first. With separately authorized traffic to a controlled endpoint, confirm a
non-Surge interface's byte increments are recorded with process/PID and scope;
normal Surge-owned egress and loopback are excluded. Check system-extension and
LAN/unknown-UDP classifications without treating them as implicitly approved.
Confirm receive-only records are labeled, local endpoints remain visible and
wildcard UDP peers stay unknown even on local port 5353. Neither interface labels
nor counters should be displayed as proof of an actual packet path or bypass.
Confirm repeated connections are deduplicated, a summary appears within five
minutes, and command failure/recovery does not change PF or gate policy. Do not
generate a bypass or bind a physical interface on an unsaved production session
merely to pass this test. Packet captures and process-exit timing acceptance
remain separate from parser/unit tests and a successful background sample.

For the updated logs, check that receive-to-send activity and a PF revision change
are not hidden by dedup. A start/end state match with an intervening revision
change must still be a mixed tracking window. Verify caps and coverage gaps remain
visible; manual samples must not claim continuous firewall-state tracking.

During a separately authorized block scenario, compare `pf_block_traffic` with
read-only `sudo pfctl -a io.github.surge-guard -s labels`. Match the own rule label,
in/out packet and byte totals and block ID. Confirm a final pre-allow read and
subsequent gate transition are distinct. Do not treat a counter as a per-process
packet trace. A missing label, malformed output or decreasing count must produce
an evidence gap/failure, not a zero-hit claim or an allow/block policy change.
Unit fixtures cannot establish live counter accuracy or complete packet coverage.

## Continuous recorder (separate opt-in)

Read [the recorder contract](packet-audit.md). Install it only after the independent
recovery menu is available. Confirm actual PKTAP packets contain expected physical
and VIF interface/direction metadata, known-process traffic and unknown ownership
without silently filtering the unknowns. Check that starting/stopping this job
does not restart the guard or mutate PF. Verify fresh job/PID/boot-bound status
and configured event/preview time zone.

During an authorized controlled Surge restart, preserve packet/request/event
time lines and verify recorder continuity separately from guard block latency.
Do not generate an intentional bypass on an unsaved production session merely
to pass this test. Confirm Surge CLI calls occur as the console user after UID
drop and that absent Surge/session/query errors record gaps rather than stopping
the PF gate or claiming an all-clear.

Exercise capture-buffer loss, child exit/supervisor crash, incomplete statistics,
disk write failure, stop/re-arm, update rollback and ring wrap. A recovered source
must retain earlier gap flags. After crash, launchd must reap the capture child;
the new session records a gap. Compare actual retained packet timestamps with
`audit-coverage`, including truncated/live files and overwritten history. Review
sleep, power loss, early boot and high-rate traffic separately. Offline fixtures
and zero reported drops do not establish full packet coverage or no bypass.

## Persistent TCP mode

Upgrade the guard, fixed launcher and SurgeGate with the old policy first.
Run the installed launcher `--check` as the console user; it must report the
normal UID and dedicated effective GID without opening Surge. Verify recovery
and keep a private copy of the previous policy before enabling `persistent_tcp`.
Existing route restrictions remain required until explicitly changed. For a
transit-only policy, apply `examples/persistent-tcp.json` after the binary upgrade;
this removes route-policy restrictions while retaining enhanced-mode and identity
checks. Unknown identities stay blocked.

With capture active, confirm the ready anchor is nonempty, contains the
dedicated group/VIF permissions and final TCP refusal, and uses interface-bound
states. Verify ordinary IPv4 TCP through the VIF, system-proxy requests, selected
proxy requests and Surge DIRECT. Compare own-label counters and socket group
attribution; group launch success alone is insufficient.

Continuously attempt fresh connections and maintain an established TCP stream
while normally quitting Surge and toggling Enhanced Mode. Correlate physical
packet observations, process metadata and peer responses; a captured outbound
packet without a response can be observed before filtering. Test abrupt loss
separately. During an explicitly authorized guard pause, repeat a normal Surge
quit to establish that blocking does not depend on the daemon reacting. Restore
the same daemon promptly, and verify fresh status and automatic SurgeGate recovery.

Test a manually launched ordinary-group Surge: networking must remain blocked
until Gate completes normal identity correction. Check policy changes, interface
replacement and migration of old states. IPv6 application TCP is default-blocked
in this implementation; do not claim IPv6 VIF functionality or UDP enforcement.
No Tailscale or other VPN exception exists. Update/reboot and early-boot ordering
remain separate acceptance scenarios.

## PF coexistence

Capture root `pfctl -sr`, relevant nested anchors and PF references before installation. Confirm the guard attaches first, normal updates change only its anchor, and unlock releases only its own reference. Verify Internet Sharing, VM networking and other PF users if they are part of your setup. The initial main-ruleset reload deserves separate review.

## Releasing results

Publish only sanitized results: OS/Surge versions, scenario pass/fail/inconclusive, measured latency range and remaining limitations. Exclude node IPs, profiles, usernames, device IDs, service UUIDs, logs and raw captures. A release should remain experimental until these tests have been completed.

## Ordinary-group startup and recovery

Keep the dedicated PF group fixed. With the native application bundle unchanged,
normally quit Surge and start it via LaunchServices as the console user. Hold
Gate recovery briefly to inspect the ordinary effective group. It must never
cause a PF exception for that group. Capture bounded public TCP probes and peer
responses while the wrong instance exists, then resume Gate and verify normal
termination, dedicated startup and fresh allowed status. A bounded guard pause
with an independent timed resume can isolate already-loaded PF enforcement from
a daemon-triggered full block. Record that interval separately; do not equate
post-resume full blocking with proof of the pre-resume interval. Real application
updates, power loss and early boot require separate tests.

## Update pause and recording lifecycle

With both services fresh, request `surge-gate update-pause` and require its
matching acknowledgement before starting the official updater. Restart only
SurgeGate and verify the same persisted pause is acknowledged by the new process,
with no automatic application launch or identity correction. Guard and its PF
rules must remain active. The menu must display pause duration, reason, current
Surge identity and the separate Guard state. Finish or cancel the official
updater before `update-resume`; verify fresh Gate status and the fixed group
before interpreting recovery as successful. A command timeout is not permission
to start updating. Malformed pause records must stop automatic recovery.

Separately test a normal Surge quit while paused: verify process absence, fresh
blocking, no automatic relaunch, and bounded TCP probes with physical packet
evidence. After resume, verify the dedicated identity and working positive
controls. Do not equate this simulation with an actual Sparkle upgrade, a hung
installer, a forced crash or a physical reboot.

Use full packet recording only for an authorized bounded investigation. Finish
offline review or preserve the relevant closed ring files before restarting
recording; an overlapping export and recorder restart can lose the test window.
`audit-stop` must remove the job, wait for the capture child to exit, and persist
the disabled launchd flag without changing Guard's PID or PF rules. Retained
files remain available. `audit-start` must explicitly re-enable the job and
produce fresh capture status. Record this intentional gap separately from a
Surge request-history gap. A stopped recorder is not disabled protection, and
neither a clean capture nor PF drop counters prove universal absence of bypass.
