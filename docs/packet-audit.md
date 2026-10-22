# Continuous packet evidence

The socket sampler cannot cover short-lived traffic between its samples. The
optional independent recorder uses the system `tcpdump` on **`pktap,all`**, including
physical, loopback and tunnel interfaces. It records packet observations even
while Surge or the guard is restarting. Its installer does not restart the guard,
load PF rules, change routing or enable Surge's own HTTP/body capture features.

**This is evidence collection, not enforcement or a no-bypass certificate.**
There is no automatic proof that an unmatched packet bypassed Surge. Capture
loss, offload/OS visibility, absent process metadata, polling/retention gaps and
incomplete startup/shutdown all limit attribution. Even zero reported drops does
not prove full coverage. The status field `no_bypass_verified` stays false.

## Install and manage

Build/check first and install the independent SwiftBar recovery renderer as the
normal user. Installing this recorder requires local administrator authentication:

```sh
scripts/check.sh
scripts/install-user.sh --recovery-only
sudo .build/release/surge-guard audit-install --megabytes 256 --timezone UTC
"$HOME/Library/Application Support/SurgeGuard/bin/surge-guard-ui" audit-status --json
```

Omit `--timezone` for the system zone. Choose any supported IANA zone for local
audit event/preview display; event timestamps remain UTC. Existing settings are
retained on update unless explicitly supplied. Capacities are 256, 1024 or 4096 MB.
The default is eight files of about 32,000,000 bytes each, plus final-record and
pcap-ng metadata overhead. This is a rolling window, not indefinite retention.
Old files are overwritten. Power loss can lose buffered or unfinished records.
Reducing capacity changes newly written segments; existing larger segments remain
until the ring overwrites them, so total retained bytes can temporarily exceed the
new capacity. Coverage scans still accept those older segments, bounded by the
largest supported segment (512,000,000 bytes plus 65,536 bytes of overhead) and
the per-file scan timeout.

Each packet retains **only the first 256 captured bytes**, with available PKTAP
metadata. Those bytes can include payload after the headers. Captures, request
snapshots and event logs remain root-only under
`/private/var/db/surge-guard/packet-audit/`; never publish them or commit them.
The system `libpcap` reads timestamps offline; no extra package is installed.

The installed helper is `/Library/PrivilegedHelperTools/surge-guard-audit` and its
job is `io.github.surge-guard.audit`. Install/update backs up only this recorder's
previous binary, plist and configuration, waits for its actual lock release and
attempts rollback on failure. No guard files, policy or PF state are replaced.
It verifies a fresh running capture and statistics, not complete packet coverage.

```sh
sudo /Library/PrivilegedHelperTools/surge-guard-audit audit-stop
sudo /Library/PrivilegedHelperTools/surge-guard-audit audit-start
sudo /Library/PrivilegedHelperTools/surge-guard-audit audit-uninstall
```

Stop disables automatic startup and unloads the recording job; it stays stopped
across boots until `audit-start` (or an explicit audit installation) re-enables it.
Before restarting recording during an investigation, preserve the relevant closed
ring files privately: a new capture run can reuse the first segment immediately.
Uninstall removes the service/binary and retains private evidence. Neither action
unlocks networking. The recorder child rejoins the supervisor's process group so
launchd can reap it after a supervisor crash. Forced cleanup affects its own
capture child only. The supervisor publishes its own process-group ID before
starting the child; stop waits for that group even if the child PID was never
published. A replacement supervisor is checked again after lock release.
New snapshots also record the supervisor's native birth time. Stop rechecks it
while waiting so a reused PID does not make an unrelated process group appear
to be an old recorder. A missing leader still requires waiting for surviving
group members; legacy snapshots without birth evidence retain conservative waiting.
Older snapshots with only a capture PID are also checked independently, even when
the supervisor group has drained; older children may belong to a separate group.
Diagnostic lines are bounded and consumed with backpressure. The PF daemon is
independent and is never force-restarted.

## What is retained

- `traffic.pcapng0` through `traffic.pcapng7`: actual captured packet prefixes and
  available interface, direction, process/PID and other native metadata. The same
  communication may appear on several interfaces; do not sum it as unique egress.
- `events.log` plus `.1`: starts/stops, capture statistics loss/failure, guard state
  observations, request-query failures/recovery and rolling-request history gaps.
- `requests.log` plus `.1`: new/changed Surge request metadata, including process,
  endpoints, policy, completion/error and lifetime byte counts at observation.
  URL/query strings, headers and bodies are excluded. Byte-only updates do not
  flood the event log; the latest filtered batch is in `requests-snapshot.json`.
- `audit-status.json` in the public state directory: recent collector health,
  counters, configured capacity/zone and persistent gap flags for this session.
  It contains no request/packet endpoints. Readers verify boot, PID/job and age.

Both event streams use the existing current/previous 1 MiB rotation and private
writer locks. State/request snapshots are atomically replaced, not appended.
Capture counter reset/wrap records both old and new counts and marks statistical
continuity unknown while continuing raw recording; it does not force a capture gap.
Request queries run in the console user's session **after dropping privileges**.
The root recorder never executes the user-owned Surge CLI as root. A missing user
session or unavailable Surge is a recorded source gap, not a permission to allow
networking. Repeated query failures have bounded reminders rather than tick logs.

Surge request queries are roughly one second apart. A non-overlapping recent
window or changed Surge PID is recorded as a potential history gap. Overlap is
useful evidence, not proof that Surge exposes every packet/protocol. A DIRECT
request can still be handled by Surge. Proxy multiplexing and missing metadata
prevent a simple one-packet-to-one-request completeness claim.

## Investigate retained traffic

SwiftBar separately shows recorder health, gap warnings, preview/range/log actions
and start/stop controls. It never turns an active recorder into a green no-bypass
claim. Capture/request recovery does not clear prior session gap flags.

```sh
# Normal user; metadata only, no target HTTP request:
.build/release/surge-guard audit-request-sample

# Root; scan actual packet timestamps in every retained file:
sudo /Library/PrivilegedHelperTools/surge-guard-audit audit-coverage

# Root; first 25 records in each retained file, at most 200 total:
sudo /Library/PrivilegedHelperTools/surge-guard-audit audit-preview

# Full retained individual file, native metadata; potentially large/private:
sudo /usr/sbin/tcpdump -n -q -tttt -k INPD \
  -r /private/var/db/surge-guard/packet-audit/traffic.pcapng0
```

Coverage reports per-file earliest/latest **observed packet timestamps**, partial
read errors and files that changed during reading, including a ring filename
replaced with another inode while the old descriptor remained readable. A range does not prove there
are no gaps between its endpoints. A scan is bounded in size/time; malformed,
truncated, oversized, unsafe or actively changing files cannot be reported as
complete. Request/event logs can rotate before packet files: inspect both sources'
retained timestamps. A preview is explicitly not a full traffic list.

The generic libpcap range reader can reject a macOS pcap-ng file containing
different link types across interfaces. If `audit-coverage` reports that error,
its partial timestamps are not the file's full retained range. The system
`tcpdump` command above can still decode those captures, including PKTAP metadata.

Use the capture, request and guard time lines together. Keep unknown attribution
unknown; lack of a matching request never suffices to call a packet bypass.
The audit does not automatically block on data loss or unknown attribution.
Strict fail-closed enforcement is a different system-filtering requirement and
is not supplied by this external recorder.

## Daily use and suspicious-only capture

Continuous full-interface recording is not required for PF protection. Prefer it
for bounded acceptance/debugging windows, then stop it; keep ordinary event logs
and passive socket observations. Stopping loses retrospective packet evidence
for later incidents, but does not weaken firewall rules.

PKTAP metadata filters can select interface (`if`), direction (`dir`), process
name/PID and effective process name/PID. For example, the system tcpdump metadata
expression `dir=out and if=en and proc!=Surge` selects candidates on en-prefixed
interfaces. It is not a bypass detector: names do not verify signatures or socket
GIDs, attribution may be absent, PIDs change, additional physical/bridge interfaces
need coverage, and a single physical packet does not encode its previous tunnel
path. Retain unknown attribution; do not hide all process names equal to Surge
when claiming trusted-process exclusion. The metadata filter has no GID keyword.

PF rule logging, where the OS supports a usable pflog capture interface, records
matches on rules with logging enabled. A block record is a prevented attempt,
not a packet that escaped; it cannot reveal traffic that bypassed that rule.
Syntax acceptance alone does not establish usable pflog capture on a particular
Mac. This project has not enabled or validated pflog and does not alter PF for
evidence collection.

The existing recorder deliberately keeps its all-interface contract for tracing
both sides of a transition. A future separate suspicious-egress recorder should
retain only bounded physical outbound candidates with explicitly unverified
attribution, validated interface coverage and drop statistics. It must not call
them confirmed leaks or silently change the existing audit's coverage.

Primary references: [Apple tcpdump manual](https://github.com/apple-oss-distributions/tcpdump/blob/main/tcpdump/tcpdump.1),
[Recording a Packet Trace](https://developer.apple.com/documentation/network/recording-a-packet-trace),
[libpcap statistics semantics](https://github.com/the-tcpdump-group/libpcap/blob/master/pcap_stats.3pcap).
