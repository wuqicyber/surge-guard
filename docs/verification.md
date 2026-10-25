# Verification record — 2026-09-08

Environment: macOS 15.7.7, Apple Silicon, Swift 6.0.3, Surge Mac 6.9.1.

Completed without root privileges or changing networking:

- `swift run surge-guard-tests`: all test groups passed, including readiness combinations, PF configuration round trip/tamper rejection, live-output attachment ordering, route parsing, native PF syntax, command timeout/backpressure, separate stdout/stderr, literal argument handling and protected state-directory checks.
- `swift build -c release --product surge-guard`: passed.
- Release executable `check`: all six readiness conditions true with Surge Enhanced Mode active.
- Release executable `rules`: printed parseable PF policy.
- Build and live-readiness checks do not read a Surge profile or collect node credentials.

Completed with administrator authorization on the target Mac:

- Installed the root-owned binary, PF attachment/default-block file and system LaunchDaemon.
- Confirmed the daemon was running, PF enabled, the guard first among filter rules and the ready-state anchor empty.
- Verified `RunAtLoad` and `KeepAlive`; explicitly cleared the launchd disable override.
- With Enhanced Mode enabled, a fresh IPv4 HTTPS request succeeded (HTTP 200).
- Turned Enhanced Mode off. Readiness became false, and the same request timed out. The request used `--noproxy '*'` and `--resolve` so DNS failure or proxy environment variables could not explain the result.
- Turned Enhanced Mode back on. Readiness and HTTPS automatically recovered (HTTP 200).
- The service remained running with one launch/no recorded exit during the toggle test. Installed binary SHA-256 matched the tested release build.
- Earlier failed startup attempts exercised automatic recovery; the service was unloaded and its blocking rules removed before retrying.

Real-machine findings fixed before successful startup:

- macOS `/var/run` may be root:daemon and group-writable. State is stored under the protected `/private/var/db/surge-guard` instead.
- macOS `pfctl -sr` includes normalization (`scrub-anchor`) before filter rules. Ordering validation now distinguishes the two while still rejecting preceding allow/block filter rules.
- PF's ALTQ warnings use stderr. Command diagnostics are kept separate from structured stdout. PF enable-reference tokens are intentionally parsed from both streams.

Not performed / not established:

- Full application quit/force-quit, existing TCP/UDP transfer interruption, IPv6 transport, inbound acceptance, sleep/wake or actual reboot acceptance.
- Complete automated uninstall/reinstall acceptance or coexistence tests for every other PF user.
- Zero-packet transition latency or zero-leak early-boot protection. Neither is guaranteed by this architecture.

Initial development had no administrator access; the subsequent live test used the macOS administrator authorization dialog. No protection claim is made for the unperformed tests. The code remains experimental; complete [acceptance.md](acceptance.md) for the relevant use case before relying on it.

## Source verification — 2026-09-09

- Expanded readiness coverage from 32 to 64 combinations and added an IPv6-primary-interface safety gate.
- Cached the verified Surge PID with a native process-exit source; separated 0.5-second readiness fallback from five-second PF integrity audits.
- Added operation-specific PF mutation timeouts and command context to timeout errors.
- Added a root-only rotating event log at `/private/var/db/surge-guard/events.log` while retaining unified logging.
- `swift run surge-guard-tests`, release build and warnings-as-errors build passed. The new release reported all six readiness fields true on the target Mac without changing networking.
- The release binary was atomically installed over the running service. The old daemon first left block rules installed, then launchd started the new binary (`runs = 4`, last exit `0`) and the guard returned to `ALLOWED` without toggling Surge Enhanced Mode.
- Installed SHA-256: `73d31e78b805fffa8af366e823ed9e3a37c1284f6fc8d7a56ae4afe52f0af42d`.
- Post-update status: daemon loaded, PF enabled, managed anchor first, all six readiness fields true, live guard anchor empty. The private event log was created as `root:wheel` mode `0600` and recorded the `ALLOWED` transition.
- Live blocking and reboot acceptance were not repeated for this source revision.

## Configurable gate and native companion — 2026-10-19

Completed without administrator privileges or changing installed services:

- Standalone tests pass, including existing 64 readiness combinations/PF syntax,
  policy validation and fingerprints, nested group decisions, wrong/unlisted/
  direct targets, malformed responses, boot-bound freshness, stale PF audits,
  bundle-ID ordering/exclusions, preserved pending session data, and readable/
  machine/legacy log rendering. The real tail-to-render pipeline was exercised
  using a temporary fixture, including a final line without a newline.
- Both release executables build with warnings treated as errors. Generic
  examples validate, shell integrations parse, and help/rules/menu commands
  remain non-mutating. `install --help` displays help without entering install.
- A temporary private policy using the target Mac's current group and final
  proxy passed the unprivileged live condition check. Replacing the allowlist
  with an unlisted test node correctly failed without modifying Surge/PF.
- Invalid route configuration returned a machine-readable failure. The old
  installed daemon was correctly identified as running while new-schema PF
  status remained unknown, avoiding a false green protection claim.
- Public source/examples/docs were checked for machine-specific domains, node
  names and personal paths; local policy data was not added to the repository.

Not performed in this session:

- Privileged helper execution, system daemon update/restart, live PF transitions
  and actual installation/migration of the new user service/menu. `sudo -n`
  requires a password on the target machine.
- Native application quit/launch acceptance, refusal/unsaved-document prompts,
  real shutdown, reboot/power-loss recovery or sleep/wake acceptance.
- Live light/dark visual acceptance of the installed new menu.

These are source and read-only checks, not a new live protection certification.
The existing installed protection was left running. Follow `acceptance.md`
after authorized local deployment before relying on the new version.

## Update handoff incident and offline recovery — 2026-10-19

- Inspected the unified log after reported complete connectivity loss. The new
  query preflight succeeded, but the updater exited on an occupied firewall lock
  before the old daemon finished stopping about 0.3 seconds later. The old
  daemon left blocked rules and was not loaded again until a later manual start,
  which logged `ALLOWED`. The installed binary was never replaced in that attempt.
- Fixed the real lifecycle boundary: bounded lock-release wait, independent
  management-operation lock, trusted update/policy backups, startup verification
  and attempted automatic rollback. Restart uses TERM and waits for a new PID
  and verified PF status. No forced `kickstart -k` remains in this integration.
- Regression tests pass for delayed flock release, held-lock timeout, manifest
  destination/path restrictions, the actual offline action script with fake
  system commands (delayed exit, new restart PID, refusal to flush a live owner),
  renderer-absent fallback and rejection of PID/condition-only green status.
  Both release products build with warnings treated as errors; the full project
  check script passes. These fixtures do not use live sudo/PF operations.
- Installed only the user-side recovery renderer/action script and backed up
  the existing private combined plugin outside SwiftBar's scanned directory.
  Replaced its Surge section and legacy start/restart callers, preserving other
  services. Shell syntax passed; the isolated section renders the independent
  actions. The user's screenshot confirms the new orange/unknown section is
  visible. Its initial misleading missing-file error was replaced with an
  explanation of the old/new version mismatch. Legacy SurgeGate is identified
  as awaiting migration rather than reported as a running new companion.
- Confirmed the old system daemon is still running and does not publish the new
  status file. Fresh Enhanced Mode and configured rule checks pass. This is not
  a current privileged PF verification, and the menu does not claim one.

Not performed: privileged update/automatic rollback/backup-restore acceptance,
live emergency removal or restart, native companion migration, actual shutdown,
power-loss/sleep recovery or full light/dark visual interaction. The system
daemon and PF were not changed during this repair. Native UI inspection timed
out; rendered output and the supplied screenshot do not replace full visual QA.

## Successful system update and user migration — 2026-10-19

- The operator ran the fixed system installer locally. Its output records a
  verified query preflight, an update backup, startup with a new PID and
  `Verified: ALLOWED`. Subsequent read-only snapshots are fresh, in `routes`
  mode, with all Enhanced Mode and configured routing checks passing. The
  installed executable matched the release build from the recovery commit.
  This exercises a successful handoff; automatic rollback was not triggered.
- Installed the native user companion and migrated existing configuration.
  The first user installation exposed an existing-directory error because the
  offline recovery component had already created `bin`. Fixed directory setup
  to accept an existing safe directory, reject files/symlinks, stage the binary
  before stopping the service and wait for its lock on replacement. Added a
  focused directory regression check; the full check script passes.
- The new user LaunchAgent publishes fresh `ready` with zero pending apps.
  The old LaunchAgent is unloaded and its plist retained as a migration backup.
  Existing app priority names were converted to bundle IDs where resolvable;
  non-application/unknown legacy entries are logged and originals retained.
  The two existing local shutdown/restart command callers now invoke the native
  companion. Neither shutdown caller was executed.
- Repeated the user installer with its native service already running. It
  replaced/reloaded the companion successfully; the new launchd PID published
  fresh `ready`, zero pending apps and a nonempty session checkpoint. Existing
  applications remained running. This does not exercise launching an absent app
  or actual quit/shutdown behavior.
- Verified the installed SwiftBar version is 2.1.1 (597), matching the latest
  official stable release at inspection time. Its v2.1.1 menu updater clears
  actionless submenu actions; explicit primary light/dark colors keep this
  integration enabled. Added those colors to the guard, recovery and companion
  parent entries and refreshed the existing combined menu. References:
  [release](https://github.com/swiftbar/SwiftBar/releases/tag/v2.1.1),
  [menu implementation](https://github.com/swiftbar/SwiftBar/blob/v2.1.1/SwiftBar/MenuBar/MenuBarItem.swift#L975-L983).

Still unperformed: deliberate policy-failure/live traffic blocking, emergency
unlock/backup restoration/automatic rollback acceptance, actual application
quit/refusal and OS shutdown, power-loss/sleep recovery, and post-fix light/dark
visual interaction. No Surge toggles, system guard restart or PF changes were
issued by the agent during the user-companion migration.

## Menu naming, companion indicator and power controls — 2026-10-19

- Renamed the menu display to `SurgeGuard`. Added a structured companion status
  reader: green requires a running/fresh/ready companion, zero pending apps and
  a fresh allowed system gate. Focused cases reject green for stale/stopped,
  waiting, restoring, error, shutdown and blocked-gate states. All 22 standalone
  test groups and both warnings-as-errors release builds pass.
- Installed only the updated user renderer. Its isolated output shows green
  `SurgeGate`, blue restart and red shutdown with larger text at the top of the
  SurgeGate submenu; a separator divides power controls from management/logs.
  Confirmed both power commands are children of SurgeGate, not a separate root
  menu. The current primary status text also uses readable light/dark colors.
- Read both installed property lists and verified RunAtLoad/KeepAlive. This
  establishes automatic boot/login configuration, not actual reboot acceptance.
  No power command, system service restart or firewall mutation was executed.

## Readable bounded logs and persistent companion queries — 2026-10-19

- Observed an actual status publication race: a four-second read-only sample
  caught one 0600 snapshot and one EACCES failure. A separate temporary-file
  reproduction confirmed Foundation atomic publication under umask 077 could
  expose private permissions before its final permission restoration. The new
  shared writer applies mode/fsync before POSIX rename. A concurrent regression
  reads complete old/new contents and final modes through 150 rewrites.
- Diagnosed a second issue independently: the companion held 2,559 numeric
  descriptors and persistently reported stopped while the actual system guard
  remained fresh/allowed. Forty local command calls reproduced descriptor growth
  from 25 to 105. The shared command runner now explicitly closes unused stdin
  pipes and drained output readers, including failed launches. Query failures
  remain unknown and have a separate companion menu state.
- Backed up the user binary, plist and local session before deployment. Updated
  the user companion and combined-menu renderer; the existing system daemon
  remained running/allowed. The companion recognized already-running apps,
  returned to fresh ready with zero pending, and held four numeric descriptors
  over multiple observations through more than four minutes of polling.
- Both components use one bounded event-file writer: current and one previous
  file, each at most 1 MiB, with a private writer lock and ownership checks.
  Tests exercise repeated rotation, newest/previous retention, bounded size,
  private permissions, oversized records, wrong ownership and unsafe backup
  symlinks. The companion launchd stdout/stderr now point to `/dev/null`;
  logging failures use the macOS system log. Existing service.log is retained.
- Human logs now identify component/severity and explain state, cause, impact,
  remaining applications and recovery. JSON retains original errors and fields.
  Confirmed the installed companion prints the readable format. The real
  SwiftBar action script is tested with fake tools: only fixed tail reads get
  sudo, formatting stays unprivileged and reader failures propagate.
- The menu displays actual local snapshot publication time separately from PF
  audit age and notes these are menu-generation values. It explicitly states
  rule inspection sends no request to the target. All companion action icons
  use SwiftBar's native SF Symbol column with common 16×16 sizing; power controls
  remain in the SurgeGate submenu. The isolated installed menu renders both
  components green. The combined plugin was refreshed through SwiftBar's URL API.
- `scripts/check.sh` passes all 28 standalone groups, both release builds with
  warnings as errors, the stdin log-formatting smoke test and shell checks.

The updated system binary has **not** been installed in this phase: sudo still
requires an interactive password, and the installed executable differs from
the new build. The observed permission race therefore remains possible in the
running root writer until the operator installs the new system build. Native
and UI deployment alone cannot establish that the root writer was replaced.
No external target request, Surge toggle, PF change, app quit or OS power action
was performed during these checks. Long-duration, power-loss and disruptive
acceptance items above remain unperformed.

## Lowercase menu names and main-branch review — 2026-10-19

- Changed the SwiftBar labels, companion action labels, plugin metadata and
  recovery fallback/banner to `surge-guard` and `surge-gate`. Stable service
  labels, executable paths and stored configuration paths are unchanged.
- Built the release guard with warnings as errors. Updated only the user menu
  through `--recovery-only` and refreshed the combined plugin; the isolated
  installed output confirms both lowercase names with verified green status.
  Neither service was restarted for this display change.
- Re-read installation/recovery, configuration/rule validation, privilege drop,
  status freshness, bounded logging and companion launch/shutdown flows before
  merging. Re-ran `scripts/check.sh`: all 28 groups and release/shell checks pass.
  No new blocking code issue was found in that review. Remaining live acceptance
  and the pending system-binary installation described above still apply.

## Group-only routing with an optional final-node allowlist — 2026-10-19

- A route may now omit allowed_final_policies. Exact rule-selected group and
  resolved proxy checks remain required; a supplied list still restricts final
  nodes. Empty/null/malformed lists are rejected. Parser evaluation and daemon
  result binding share the final-policy check, retaining rejection of missing,
  DIRECT and REJECT results. Existing full-list configurations keep the same
  JSON encoding and policy fingerprint.
- All 29 standalone groups and warnings-as-errors release/shell checks pass.
  Added omission round-trip/fingerprint, changed proxy, wrong/unresolved group,
  direct/reject and invalid-list cases. Existing unlisted-node rejection remains.
- Prepared a private group-only draft after backing up the previous draft. Its
  normal-user validate and live rule-only check pass without target requests.
  The current installed full-list policy still passes, and its new-build query
  fingerprint matches the running daemon snapshot. The system policy/binary
  have not been replaced; this is not live group-only enforcement acceptance.
- Updated the user renderer through recovery-only installation. Older guards
  still require the list, so documentation now upgrades the binary with its
  existing policy before applying group-only JSON. Fresh installs can configure
  the new format before the first start. No PF changes or service restart were
  performed during these checks.

## Post-merge review and offline recovery hardening — 2026-10-19

- Verified that the operator has now installed the group-only system build:
  installed and local release hashes matched at review start, the fresh daemon
  fingerprint matches the private group-only configuration, all six readiness
  checks pass and the companion reports fresh ready with no pending apps.
  Earlier sections' pending root deployment describes their original phase,
  not the current machine state.
- Read the policy/parser/result-binding, freshness, command cleanup, installer,
  recovery, logging and user-session flows again. Found and reproduced two
  shell recovery gaps using fake tools: it called guard help even for independent
  actions, and unexpected service-query failures were treated as absence. The
  pre-fix regression failed both independence and no-flush assertions. The fixed
  script skips capability queries for emergency/log actions, rejects unknown
  inspections or a running job without a valid PID, and retains known-absent
  service recovery. No test invoked live sudo, PF or power operations.
- Live read-only observations: 246,810 status-file reads over four seconds
  produced no non-0644 mode, permission failure or incomplete JSON. The companion
  had four numeric descriptors after approximately 38 minutes of continuous
  operation. This is a sampled observation, not an exhaustive uptime guarantee.
- The companion recorded one real upstream CLI-unavailable transition to blocked
  and then ready approximately one second later. No deliberate Surge toggle was
  issued. This confirms a reported fail-closed transition and recovery; it is not
  controlled packet/latency acceptance. Human logs now summarize nested helper
  stderr into a clear CLI cause and paused-restoration state, while JSON retains
  the complete diagnostic record. Added root and companion rendering regressions.
- All 30 standalone groups, both warnings-as-errors release builds and shell
  checks pass. Backed up user components, updated the recovery helper/renderer
  and native log viewer through the user installer, and refreshed SwiftBar.
  System daemon control logic and the live policy were not changed by this review.
  The formatter change in the shared library is deployed in user-facing readers;
  the installed system executable remains the already-verified group-only build.

Private root PF/log inspection was unavailable without an interactive sudo
credential. The read-only daemon report supplies recent root-owned PF audit
results. Deliberate failure/traffic blocking, real emergency unlock, automatic
rollback, sleep, power loss and OS shutdown acceptance remain unperformed.

## Passive egress evidence and exit-event timing — 2026-10-19

- Inspected the guard's own events mirrored to the macOS unified log. A Surge
  update recorded unavailable extension/service readiness as blocked, followed by
  allowed only after the configured routing check passed. The inspected window
  contains no PF-unverified, reconciliation-failed or manual-unlock event. These
  state events cannot reconstruct individual historical flows or actual exit-to-
  packet-block latency. Repeated pending/blocked/allowed cycles were also seen;
  their underlying notification behavior is unchanged by this logging update.
- Added asynchronous fixed-system-command socket sampling, new-byte evidence,
  public/local/unknown destination classification, root-owned system-extension
  classification, bounded per-flow dedup and sample summaries. Neither evidence
  nor observation failure participates in the PF readiness decision. Millisecond
  event time, monotonic uptime and callback-to-verified-block timing preserve
  future diagnostic evidence without promising a fixed blocking deadline.
- All 31 standalone groups, both warnings-as-errors release builds and shell
  checks pass. Focused fixtures cover lifetime versus delta frames, quoted process
  names, IPv4 and both IPv6 endpoint formats, local/unknown/idle sockets, absent
  counters/interfaces, reused UDP tuples, malformed output, dedup/batch limits,
  machine JSON and human evidence/timing formatting. A real read-only sample
  exposed normal empty nettop counters; the fixture and parser now cover them.
- Ran the new release and installed user-renderer samples without external test
  requests. Both parse the real output, expose visibility gaps and distinguish
  independently running system-extension traffic from application candidates.
  Samples contained no records combining a public peer with a non-extension
  application during those intervals. Socket interface labels do not establish
  packet paths; this was not a historical or packet-level bypass audit.
- Updated the user renderer/recovery components using recovery-only installation,
  retaining its backup. The isolated combined-section output has the new manual
  egress action and both recovery entries. Refreshed SwiftBar without restarting
  either service. Existing private plugin content was not executed or published.
- Hosted checks using macos-14 remained queued during its announced October 19
  retirement brownout. Moved the existing job to macos-15 without changing its
  test/build steps; see the [runner retirement announcement](https://github.com/actions/runner-images/issues/13518).

The system daemon has not been replaced during this phase: non-interactive sudo
is unavailable and interactive administrator verification was not completed.
Background observer persistence, root process visibility, exit-event timing,
controlled bypass/traffic blocking and restart/rollback/power scenarios remain
unperformed. Installing only the user renderer does not enable background logs.

## Correct socket evidence wording — 2026-10-19

- The operator has since installed the preceding observer build. Before this
  correction its installed and local release hashes matched; fresh read-only
  status reported allowed with the configured routing check passing. Unified-log
  mirrors from the running daemon include observer summaries and activity events.
  This confirms the observer is running, not that packet paths were audited;
  complete private root event files were not read in this phase.
- Corrected misleading human wording shared by historical log rendering and the
  manual sample. The renderer identifies reported socket interfaces, shows both
  endpoints and distinguishes receive-only activity from sent-byte counters.
  Wildcard UDP peers stay unknown. Local UDP port 5353 is only an mDNS hint;
  neither the port nor the interface label proves a destination or packet path.
  Original machine JSON, counters, sampling and firewall decisions are unchanged.
- All 31 standalone groups, warnings-as-errors release builds and shell checks
  pass. A focused six-record generic fixture covers wildcard IPv4/IPv6 UDP,
  receive-only records, a high local port and qualified service-port hints. It
  rejects confirmed-bypass/public-direct wording and verifies JSON preservation.
- Updated only the user renderer/recovery components after backing them up and
  refreshed SwiftBar. Its isolated menu offers the renamed read-only connection
  sample; the installed UI hash matches the new release. A real installed-renderer
  sample shows unknown-peer receive-only records with local UDP port 5353, and
  the JSON command remains parseable. The new wording also renders old records
  without rewriting logs or replacing the running system daemon.

No service restart, PF mutation, external target request or intentional bypass
was performed. Packet capture/path verification, exit-to-block latency and the
previously listed disruptive/power acceptance scenarios remain unperformed.

## Native tunnel-loss subscription and priority blocking — 2026-10-19

- Read-only correlation of Surge's own disconnect/core-stop records with guard
  system-log mirrors showed the tunnel disconnected before the UI process exited.
  Watching UI exit alone therefore cannot cover the start of graceful teardown.
  Log timestamp differences are not measurements of escaped packets.
- Added native status subscription to the verified primary Surge service. Any
  non-connected/unknown status is a loss; callbacks from an obsolete subscription
  are ignored. Subscription/replacement errors use the existing fail-closed path.
  A known loss while allowed now blocks before remaining readiness/configuration
  probes and PF integrity queries, invalidates old routing results and publishes
  blocked status after verification. All existing reopening conditions remain.
- Added separate monotonic timing for loss receipt/observation, rule loading and
  final block/state cleanup. Existing states are still cleared using only the
  Mac's remembered addresses; no global PF state flush or unrelated rule changes
  were introduced. Human logs explicitly state the unmeasured event-delivery gap.
- All 32 standalone groups, both warnings-as-errors release builds and shell
  checks pass. Added connected versus disconnecting/disconnected/connecting/
  invalid-state cases and human/JSON stage-timing regressions. A standalone native
  read-only probe successfully subscribed to the current Surge service and
  received its connected status. Initial subscription state was asynchronous,
  so the guard retains blocking until a connected observation and full checks.
- Updated the user-side log renderer/recovery files with a backup and confirmed
  the isolated SwiftBar section retains both recovery and emergency entries.
  Fresh read-only readiness/rule and installed-daemon status checks still pass.
  This display update does not activate the new daemon callback path.

The new system binary has not been installed in this phase. No Surge disconnect,
guard restart, PF mutation, intentional bypass or packet-capture acceptance was
performed. Live reaction latency and old-state termination remain unverified.
Allowed mode still clears this guard's anchor; this change improves reactive
blocking and does not implement permanent packet-level no-bypass enforcement.
The strict zero-window requirement is not established by these checks.

## Traffic evidence and PF counter records — 2026-10-19

- Before this phase, the operator installed the preceding native tunnel-loss
  build. Read-only status still shows the same running daemon with all readiness
  checks and the local routing policy passing. This is not packet-path proof.
- Inspected a bounded recent window of the macOS guard-log mirror and ran new
  read-only socket samples. Parsed observations had unresolved remote peers,
  predominantly receive-only records with local UDP port 5353. No parsed record
  established public application bypass. Some long mirror records were truncated;
  non-interactive sudo could not read the complete private event files or live
  PF counters. No historical all-clear or complete blocking count was inferred.
- Split public sending candidates, public receive-only, system extensions,
  local/reserved and unknown peers. Public sending evidence gets priority under
  the existing batch cap. Dedup includes direction and firewall revision, so
  receive-to-send changes and activity across gate transitions are recorded again.
  Counts expose dedup/cap omissions. Samples retain command timing and conservative
  state-tracking boundaries; a revision change prevents attributing the whole
  interval to the final state. Manual/old records report tracking as unavailable.
- Added read-only own-anchor PF label-counter reads while blocked and before
  preparing to allow, with unique block IDs, in/out packet and byte counters,
  deltas and monotonic boundaries. Missing/ambiguous/malformed/decreasing counters
  generate evidence failures; reloads expose the missing tail. Baseline recovery
  cannot silently turn cumulative counts into new bytes. Logging does not change
  the rule text or treat observations as permission. Readiness and route freshness
  are rechecked after the optional pre-allow counter query.
- All 34 standalone groups, warnings-as-errors release builds, example validation
  and shell checks pass. Focused fixtures cover receive-to-send dedup (including
  unknown peers), state-context changes, priority/cap accounting, human/JSON
  evidence boundaries, own-label parsing, in/out deltas, duplicate/missing labels,
  invalid numbers, inconsistent totals, overflow and counter rollback.
- Ran a real release sample without target requests. Its JSON timing fields parse
  and the installed user formatter shows receive-only/unknown-peer evidence and
  unavailable manual state tracking. Updated only user renderer/recovery files
  with a local backup, checked the isolated menu and retained recovery/emergency
  actions. Private combined-plugin content was not executed or published.

The system daemon for this phase is not installed. No service restart, PF mutation,
Surge disconnect, external target request or packet capture was performed.
Live PF counter agreement, background transition association, blocking latency,
restart/rollback/power scenarios and packet-by-packet coverage remain unverified.
Counters omit any matches after the last read and before rule clearing; they do
not identify individual processes/endpoints and cannot establish strict zero bypass.

## Optional continuous packet recorder — 2026-10-20

- Added a separate opt-in packet collector and management commands. It uses fixed
  system PKTAP/tcpdump arguments covering all interfaces, a default 256 MB rolling
  ring, 256-byte packet prefixes and available native process/interface/direction
  metadata. Captures may include payload prefixes; all evidence stays private.
  It does not restart the guard or change its PF policy. It is not enabled by
  updating the existing guard or user renderer.
- Added filtered Surge request metadata alongside capture evidence. A root-owned
  helper enters the console session and drops privileges before querying the
  fixed Surge CLI. A real normal-user read-only sample parsed active/recent rows
  successfully and excluded URL/query/header/body fields. No external test request
  was made. Root bootstrap/drop-privilege execution remains untested in this phase.
- Added source failure/recovery, missing request-window overlap, changed Surge
  process, capture loss, stop/start and status transitions. Gap flags persist in
  the session. Recorder health never sets `no_bypass_verified`; there is no packet
  matcher that turns missing request metadata into a bypass verdict. Capture
  statistics, filtered metadata and bounded event streams are distinct evidence.
- All 38 standalone groups, warnings-as-errors release builds, examples and shell
  checks pass. New cases cover fixed all-interface/bounded capture arguments,
  partial statistics/drop counters, boot freshness, actual child process-group
  rejoining, native offline tcpdump ring naming/overshoot, libpcap pcap/pcap-ng
  timestamp ranges, truncated/unsafe files, metadata exclusion, request dedup and
  rolling/session gaps, configured log time zones and unprivileged audit bridges.
- A local normal-user capture attempt returned permission denied. No live packet
  collection, root audit service install/start/stop, rollback, crash cleanup,
  packet attribution, packet-drop injection, root IPC-session probe, guard restart,
  network rule change or intentional bypass was performed. These remain live
  acceptance work, not inferred passes. Prior read-only guard status remains
  verified allowed; the existing daemon was not replaced.

The recorder requires local administrator installation before recording starts.
Its packet/request buffers and retained files can have gaps or be overwritten;
finite captures and zero reported drops cannot establish complete historical
coverage, packet attribution or strict zero bypass. Power/sleep/early-boot and
high-load scenarios remain unverified.

## Authorized Surge CLI connectivity checks — 2026-10-20 UTC

Completed as the normal user on macOS 15.7.7 with Surge Mac 6.11.0 (12570):

- Inspected installed CLI help, status, effective configuration and rule
  explanations. Rule mode, Enhanced Mode and system proxy were enabled. The
  installed guard had one configured route check; its check/status JSON parsed
  successfully and reported ready/allowed before and after the active tests.
- Evaluated the configured URL with default, curl-process and UDP contexts,
  plus public HTTPS and DNS destination examples, without creating connections
  for the rule explanations. The configured target resolved through its required
  group, while other examples selected different proxies or DIRECT. These
  examples establish policy differences, not exhaustive routing coverage.
- The effective profile explicitly disabled encrypted-DNS following outbound
  mode, set unsupported-UDP behavior to REJECT, and disabled IPv6 VIF. Direct
  rules were present. Only sanitized findings are retained here; profile text,
  credentials, local targets, group names and node identities are excluded.
- Ran the selected final proxy's TCP test twice successfully. Its UDP test
  returned a JSON `error: Timeout` after about five seconds on both attempts.
  Both failing UDP commands exited zero, so the response payload, not just the
  CLI exit code, is necessary to interpret the result. The selected proxy had
  UDP relay explicitly enabled. A different currently selected proxy's UDP test
  succeeded with a reported receive time of 360 ms. This narrows the observed
  problem to the selected proxy's UDP path or connectivity to the test target;
  it does not identify the server-side cause or prove every UDP destination fails.
- Surge HTTP HEAD probes to example.com and www.cloudflare.com using current
  rules returned HTTP 200. An explicit selected-proxy probe to example.com also
  returned HTTP 200. A current-rule probe to www.baidu.com returned HTTP 200 with
  DIRECT. A Surge-owned DIRECT request is not evidence of bypassing Surge.
- During the two CLI test batches, 15 approximately one-second guard samples
  all reported allowed with the same daemon PID, including around the UDP
  failures. These discrete samples are not continuous state or packet tracking.
  They confirm that the current configured rule/readiness checks did not report
  the observed UDP test failure as a blocking condition.
- A separate fresh IPv4 curl HEAD request to one.one.one.one, with proxy
  environment bypassed and the destination pinned to 1.1.1.1, returned HTTP 200.
  Surge's request snapshot contained a matching curl PID and start time with
  byte counters and a non-DIRECT policy. Active/recent lists included the same
  request ID; this is one observed request, not two. No physical-interface
  binding or packet-path claim was made.
- The equivalent literal-IPv6 curl request failed immediately. The system had
  no IPv6 default route, so IPv6 transport/blocking acceptance is inconclusive.
  A successful IPv6 rule explanation does not supply a working IPv6 baseline.
- Final read-only checks still reported all six readiness conditions true and
  the configured routing result ready. Surge mode/features were unchanged.

No profile, policy, feature, PF rule or installed service was changed. Only this
sanitized verification record was added. Active tests sent small public test
requests and used Surge's configured policy-test targets; no bandwidth test ran.
Private per-test results are retained outside the repository with user-only
permissions. No full request history or credential-bearing profile was saved.

Not performed: Enhanced Mode disable/re-enable, Surge or guard termination/hang,
existing TCP/UDP interruption, physical-interface bypass, live packet capture,
privileged PF inspection, sleep/wake, reboot, or strict zero-window acceptance.
No source logic changed, so the full build/unit suite was not repeated. Successful
application requests and failed UDP probes are connectivity evidence, not proof
of complete traffic interception or fail-closed behavior during a Surge failure.

## Dedicated-egress feasibility, non-disruptive checks — 2026-10-20 UTC

The user authorized investigation of a persistent PF policy with a separate
Surge egress identity, then clarified that the running Surge must not be
interrupted while in use. The prepared disruptive experiment was never executed
and its temporary orchestration script was removed.

Performed:

- Confirmed the existing guard reported allowed, SurgeGate was running, and
  Surge Enhanced Mode and system proxy were enabled. The independent recovery
  renderer was installed, rendered its recovery section, and was referenced by
  an active SwiftBar plugin file.
- Using native administrator authentication for fixed read-only system commands,
  confirmed PF was enabled and this guard's live anchor was empty. This agrees
  with the current reactive allowed-mode implementation.
- Inspected Surge main/helper/extension identities and TCP sockets. The main
  application used the same effective user/group as ordinary user applications.
  The privileged snapshot reported 105 non-loopback TCP peer records on the
  main application; the helper and network extension had no TCP socket records
  in that snapshot. This is a momentary socket inventory, not a complete
  workload inventory or packet-path attribution.
- Current-rule and explicitly Surge-owned DIRECT HEAD requests to example.com
  returned HTTP 200. No mode, profile or routing policy was changed.
- A disposable unprivileged child could not change its effective group to an
  alternate existing group (`EPERM`). The parent and running applications were
  unaffected. This attempt did not test a privileged dedicated-group launcher.
- The native `pfctl -n` parser accepted a candidate TCP policy containing a
  numeric group match, tunnel-interface permission, interface-bound states and
  an outbound default refusal. Parse-only mode did not load any live rules;
  syntax acceptance does not establish matching or enforcement semantics.
- `scripts/check.sh` passed all 38 standalone test groups, release builds,
  example validation and shell checks. These checks did not mutate the live
  firewall or quit applications.
- Final checks retained the same Surge, guard and SurgeGate PIDs, with no stopped
  process state, guard allowed, and both Surge features still enabled. The
  proposed temporary group did not exist.

Not performed: temporary group creation, launching Surge under another identity,
Surge/Gate/guard suspension or termination, Enhanced Mode toggling, live PF rule
replacement, packet capture, failure-window measurements, helper/delegated egress
coverage, existing-connection interruption, IPv6 enforcement, update or reboot.
No binaries, services, configuration or firewall rules were installed or changed.
The dedicated-identity approach remains unvalidated; these checks must not be
reported as a successful persistent kill switch.

## Manual Global Proxy policy-block test — 2026-10-20 UTC

The user manually switched Rule → Global Proxy → Rule, with Enhanced Mode kept
on. No agent command changed Surge mode, loaded PF rules, restarted services or
quit applications. The installed routes-mode guard performed its ordinary
blocking and recovery. This exercises the existing policy gate, not the proposed
dedicated-egress identity or a Surge/tunnel failure.

Performed:

- Established successful fresh IPv4 HTTPS HEAD requests with DNS pinned and
  proxy environment variables bypassed, plus 219 successful HEAD responses over
  one established TLS socket before the mode change. Both used the normal
  routing path, without physical-interface binding.
- Sampled CLI mode and verified guard status approximately every 250 ms, fresh
  HTTPS requests approximately every second, and live PF rules/label counters/
  enabled state approximately every 1.07 seconds. Fixed read-only system PF
  commands used native administrator authentication in one continuous session.
  Raw samples remain private outside the repository.
- First observed Global Proxy at 08:48:25.203 UTC and blocked guard status at
  08:48:26.550, an observed separation of 1.347 seconds. The first blocked
  snapshot carried a publication time of 08:48:26.405. A PF sample spanning
  08:48:25.979–26.044 still found an empty anchor; the next, spanning
  08:48:27.048–27.106, found the blocking rule with PF enabled.
- A fresh request started at 08:48:25.230, after the first Global Proxy
  observation, and returned HTTP 200 at 08:48:25.842 before blocking. This
  demonstrates a policy-reaction interval. Enhanced Mode remained enabled, so
  this response is not evidence of bypassing Surge.
- The following 27 fresh requests timed out, including all 25 whose complete
  request intervals fell between the first observed blocked status and the
  first observed recovered status. The last sampled block-rule counter before
  recovery was 3,761 packets / 784,707 bytes: 1,499 inbound / 2,262 outbound.
  These are aggregate rule matches, not attribution to the test requests or a
  complete count through the subsequent rule removal.
- The established socket returned `BrokenPipeError` at 08:48:25.456, before the
  later empty-anchor sample. Its interruption therefore cannot establish that
  PF killed that connection; a mode-switch effect or another cause remains
  possible. The sampler did not reconnect it while Global/blocked.
- All sampled blocked snapshots reported `rule_probe_failed` with
  `Surge returned an incomplete rule explanation`, rather than
  `outbound_mode_is_proxy`. The installed parser/probe failed closed, but the
  reason displayed to the user did not directly identify Global Proxy mode.
- First observed Rule again at 08:48:51.933 and allowed status at
  08:48:53.541, separated by 1.608 seconds. Live PF was enabled with an empty
  anchor at 08:48:53.950. Fresh HTTPS recovered at 08:48:54.134; a new persistent
  socket had recovered at 08:48:54.032. Each then produced six successful
  responses before sampling ended.
- All 1,000 mode samples retained Enhanced Mode and system proxy enabled.
  Final independent checks confirmed Rule mode, guard allowed, and SurgeGate
  running/fresh. Surge, guard and SurgeGate retained their original PIDs.

Result: observed IPv4 fresh-request policy blocking and automatic recovery
passed for this one transition. Established-connection termination by PF is
inconclusive. Sample times and snapshot publication times are not the GUI
click-to-last-packet latency; PF reads are sequential, not an atomic packet trace.

Not performed: physical packet capture, Enhanced Mode disable/re-enable, Surge
or guard exit/hang/restart, dedicated-identity launch, persistent-rule deployment,
IPv6/UDP enforcement, update or reboot. This test does not establish zero-window
protection. Only this verification record changed; the earlier full check-suite
pass was not repeated for the documentation-only addition.

## Continuous recorder and normal-exit capture — 2026-10-20 UTC

The user authorized persistent 256 MB recording with display time zone
`Asia/Singapore`, and controlled normal Surge restarts for a dedicated effective
group feasibility test. No experimental PF policy was loaded. The existing
routes-mode guard remained running throughout.

Recorder installation and validation:

- The first installation rolled back correctly after failing its fresh-statistics
  check. Capture had actually started: native macOS tcpdump's live SIGINFO output
  puts all three counters on one `tcpdump:` line, while the parser recognized
  only the three-line termination format. Fixed the shared statistics parser,
  preserving both formats and clearing incomplete compact-frame state.
- Added cases for native single-line output, singular counts, nonzero drops,
  incomplete/misordered/invalid frames, stale baseline rejection and subsequent
  multiline output. `scripts/check.sh` passed all 38 check groups, release builds,
  example validation and shell/CLI checks. These checks do not test live blocking.
- Installed only the independent audit helper and launch daemon. Verified the
  existing offline recovery menu, configured capacity/time zone, fresh status,
  increasing live counters, root-owned private recording/configuration paths,
  and native packet metadata on physical, loopback and Surge VIF interfaces.
  Guard binary, configuration and PID were unchanged.
- The recorder and capture child retained their PIDs through both normal exits.
  Reported captured counters increased from 110,319 before the transitions to
  124,310 after them, with zero kernel-reported drops. Surge request queries
  correctly recorded unavailable/recovered and process-change history gaps.
  Zero reported drops and unchanged PIDs are not a completeness certificate.
- `audit-coverage` encountered a real mixed-link-type pcap-ng limitation in the
  generic libpcap reader, reporting an error after three records. Its partial
  range was not used as evidence of the full capture interval. Native system
  tcpdump decoded the file successfully and supplied the packet analysis below.

Dedicated-identity feasibility:

- A temporary root-owned native launcher dropped to the existing normal user's
  UID and a temporary effective GID before executing the official Surge binary.
  Surge retained that GID. Rule mode, Enhanced Mode, system proxy and the existing
  guard's allowed status recovered. Surge HTTP probes using current rules and
  explicit DIRECT, plus an ordinary-route IPv4 HTTPS request, returned HTTP 200.
- Normal termination restored Surge's original group and the user SurgeGate job.
  The temporary group and launcher were removed. Final status was allowed and
  the guard's own anchor empty, as expected for the existing implementation.
- An earlier attempt at 09:06 UTC had quit/restored ordinary Surge but never
  invoked the dedicated launcher because of a test-harness flag-check path error.
  That harness error was corrected and preflighted before this successful test;
  it is not evidence of Surge incompatibility. No packet recorder covered that
  earlier exit, so its bypass outcome remains unknown.

Observed packet behavior during the recorded test:

- A normal-user probe made 216 fresh TCP connection attempts at approximately
  50 ms intervals using ordinary routing, without proxy APIs or interface binding.
  Each socket closed after connect or a bounded timeout; no application payload
  was sent. Overall connect results alone were not treated as bypass evidence.
- Four probe connections had matching physical-interface outbound SYN,
  inbound SYN-ACK, outbound ACK and close packets, attributed to the probe PID
  and its recorded local ports. Their initial SYN timestamps were
  09:21:49.668385, 09:21:56.383097, 09:21:56.434370 and 09:21:56.485415 UTC.
  Each six-packet exchange had zero TCP payload. These are positive observations
  of ordinary test TCP reaching the peer directly during Surge shutdown.
- A pre-existing third-party file-sync helper also emitted two physical-interface
  TCP SYNs during the exits. The first received SYN-ACKs but no completed handshake
  was observed. The second completed a handshake at 09:21:56.433259 UTC, then sent
  three payload segments totaling 766 TCP bytes; the peer acknowledged all 766
  bytes at 09:21:56.534798. PID attribution was checked against the still-running
  executable, its parent application and its start time. VIF traffic for the same
  helper was present around the transitions. This establishes actual application
  traffic in the shutdown window; it does not identify file/chat content or
  distinguish TLS handshake bytes from application messages.
- The first readiness-loss log measured 34.1 ms from observation to rule loading
  and 271.0 ms to block verification. The confirmed direct probe exchange
  preceded that rule load. The second application's acknowledged payload
  preceded the 09:21:56.614 blocked transition record. These observations must
  not be presented as an exact failure-to-last-packet latency or maximum window.
- Surge-owned traffic, metadata with the just-exited Surge PIDs, unattributed
  packets and the user's excluded special VPN traffic were not silently counted
  as additional ordinary-application bypass. No absence-of-bypass conclusion
  was made for the remaining packets. Private packet evidence and process
  attribution remain outside the repository.

Result: the existing reactive gate has a demonstrated ordinary-TCP shutdown
window, including a real application's peer-acknowledged payload. The dedicated
effective-group launch/connectivity prerequisite passed. Persistent PF identity
enforcement has not been implemented or validated by this test.

Not performed: a dedicated-group PF socket-match test, persistent rules or
old-state handling under that policy, abrupt crash/hang, Enhanced Mode toggle,
update/reboot/early boot, IPv6/UDP enforcement or exhaustive attribution of all
captured traffic. Persistent audit recording remains enabled as requested.

## 2026-10-20 — Persistent TCP implementation and controlled transitions

This subsequent session implemented the persistent policy; the earlier
reactive-mode bypass results above remain valid for the earlier implementation.
The user authorized deployment, controlled normal Surge exits, and blocking
special VPN/Tailscale TCP without exceptions. UDP remains outside the added
ready-state restriction.

Implementation and non-disruptive checks:

- Added optional `persistent_tcp`, retaining legacy encoding/default behavior
  and all existing signature, tunnel, route and configured routing checks.
  Enabled readiness installs VIF-source and dedicated-group TCP permits with
  interface-bound state, followed by a non-loopback TCP block. Policy/interface
  changes pass through full blocking and existing local-address state cleanup.
- Added a fixed set-group launcher for official signed Surge, preserving the
  console user's UID, with no arbitrary program/argument or root-user launch.
  SurgeGate corrects an ordinary-group instance only after verified blocking,
  normal termination and actual exit. Failed startup has no permissive fallback.
- Update backups include the launcher; restoration reapplies its dedicated
  ownership/mode even when the saved policy is the legacy mode. Legacy manifests
  remain valid. Offline recovery remains independent of the guard executable.
- `scripts/check.sh` passed all 40 check groups, release builds, examples,
  shell/CLI checks and native PF syntax validation. Added strict configuration,
  interface/group validation, identity parsing and versioned manifest cases.
  These checks do not constitute live packet enforcement.

Deployment and observed live behavior:

- Updated and verified the independent recovery menu first, then installed the
  system component under its original policy. It returned to verified `allowed`.
  The installed launcher's read-only check verified the ordinary console UID and
  dedicated GID. Updated the user companion before activating the new flag.
- Activation automatically blocked, normally restarted Surge under its dedicated
  identity, and returned to `allowed` with `persistent_tcp_egress`. A bounded
  automatic policy rollback was prepared but not triggered. Ordinary-route IPv4
  HTTPS returned HTTP 200. Surge HTTP probes using explicit DIRECT and current
  rules also returned HTTP 200. An initial rule-selected HEAD probe to another
  endpoint reported an HTTP/2 bodyless-response protocol error; the subsequent
  independent rule-selected endpoint succeeded.
- Readback of the live own anchor contained all three rules, both `if-bound`
  states and the dedicated-group match. Both permit counters and the block
  counter increased. This is stronger than group startup alone but is not a
  complete packet-coverage claim.

Each following test made 200 ordinary-route IPv4 TCP connections at approximately
50 ms intervals, without proxy APIs or interface binding. A separate established
TLS connection sent repeated harmless HTTP requests before the transition.
Overall successful connections include periods before shutdown and after recovery;
they do not themselves classify bypass.

| Test start (UTC) | Transition | Connected / failed | Established connection | Final state |
| --- | --- | --- | --- | --- |
| 10:03:46 | Normal Surge quit, guard running | 133 / 67 | Broken pipe after quit | Allowed |
| 10:04:16 | Enhanced Mode off for about 3 seconds, then on | 128 / 72 | Connection reset after disabling | Allowed |
| 10:05:32 | Pause guard about 4 seconds, normally quit Surge | 80 / 120 | Broken pipe after quit | Allowed |

In the third test, the same guard PID was confirmed stopped before requesting
Surge's normal quit. The user companion was temporarily paused to hold the
disconnected interval and then resumed. A bounded native operation resumed the
guard, with an additional independent timed resume as a safety fallback.
Default routing changed from the Surge VIF to the physical interface while the
guard could not process events. The own anchor, including its insertion identity,
was unchanged in the read taken before resuming the guard. Its TCP block counter
rose from 2,180 to 2,556 packets across the pre-test/readback interval. This
376-packet increase includes background traffic and time before the pause;
it is not a per-probe count or an exact failure-to-block latency.

The stale guard snapshot correctly became unknown during the pause. After
resumption the guard published blocked, SurgeGate started a dedicated Surge
instance, and verified allowed returned. Neither a forced app kill nor a global
PF disable/state flush was used. The continuous recorder and capture child
retained their original PIDs; post-test counters were increasing with zero
reported kernel drops.

Packet verification status: recent raw-capture reads are pending. The first
successfully read ring file covered an older test, not these transitions;
subsequent administrator reads were cancelled. Connection outcomes, retained
rules and counters therefore do not yet establish absence of physical bypass
in these three tests. Private timelines and diagnostic evidence are retained
outside the repository.

Not performed: forced Surge crash, power/reboot/early-boot coverage, actual Surge
updater execution, IPv6 connectivity/enforcement acceptance, UDP enforcement,
interface-number reuse stress or exhaustive attribution of all applications.

## 2026-10-20 — Execution identity requirement clarification

The user subsequently required the dedicated group on every initial application
launch, including independent launch paths. The installed wrapper/repair design
does not satisfy that stronger identity requirement. Existing persistent PF
restrictions remain enabled; no new protection claim follows from this review.

Read-only inspection and an isolated ordinary-user test established:

- The installed wrapper has set-group permission and the dedicated group.
  The official Surge executable itself still has its original ordinary
  permissions/group. Independent execution need not pass through the wrapper.
- A small ad-hoc-signed test application in a private temporary directory was
  assigned an existing supplementary group and set-group permission. Direct
  execution and LaunchServices (`open`) both obtained the expected effective
  group while preserving the ordinary UID. Strict signature verification still
  passed. This test did not modify or restart Surge and did not grant the test
  application the Surge egress group.
- Replacing that test executable with identical bytes in a new ordinary-mode
  file, then opening it again, yielded the ordinary group. This reproduces the
  reason that file watching or post-replacement repairs cannot guarantee the
  identity of the first launch.
- The local application's Sparkle framework version points to upstream commit
  `8e30a08291cef3618eaa1de0797f8dfd4473fa0c`. Its installer matches application
  ownership/group where possible, treats that operation's failure as nonfatal,
  and replaces the bundle. The inspected code does not establish preservation
  of a custom set-group permission on the old main executable. This is source
  inspection, not an actual Surge upgrade test.

The remaining design choice is controlled application installation/update
(verify and apply execution identity before publishing the new version, with
unmanaged replacement prevented) versus preserving the native updater and
using a separately evaluated execution-control mechanism. Changing the update
workflow requires the user's choice. Neither has been deployed in this session.

Primary references: [Apple execve semantics](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/execve.2.html),
[Sparkle installer at the inspected revision](https://github.com/sparkle-project/Sparkle/blob/8e30a08291cef3618eaa1de0797f8dfd4473fa0c/Autoupdate/SUPlainInstaller.m),
[Sparkle file ownership handling](https://github.com/sparkle-project/Sparkle/blob/8e30a08291cef3618eaa1de0797f8dfd4473fa0c/Sparkle/SUFileManager.m).

## 2026-10-20 — managed application update implementation, first live attempt

Historical experiment: this implementation was subsequently removed when the user
selected the simpler fixed-group recovery design below. Its commands are not
part of the final installed build.

Scope: strengthen persistent TCP startup identity beyond the fixed launcher.
The user authorized Surge Guard to manage application updates. The implementation
adds protected application/alias metadata, official-signature staging, pre-quit
maintenance blocking shared by Guard and Gate, atomic publication, inode-bound
transaction recovery and one retained application rollback. Private installation
paths and records are not committed.

Performed:

- `scripts/check.sh`: 43 groups passed, release built with warnings as errors,
  generic examples and CLI help validated, `git diff --check` clean. Three new
  groups cover record/build/permission validation, safe bundle trees, and native
  directory/symlink exchange with inode-based recovery. No test suite changes PF
  or quits applications.
- Independent recovery menu installed and its rendered recovery section verified.
  New Gate installed as the normal user. Guard update retained the local policy,
  created a backup and verified fresh allowed status before managed adoption.
- At 10:53 UTC, the first real adoption reached maintenance blocking and normally
  quit Surge. macOS rejected the original-directory/alias exchange with EPERM.
  The updater restored the original application and removed the temporary managed
  layout/marker. Gate restarted Surge through the existing dedicated launcher;
  subsequent status was allowed with `persistent_tcp_egress`, UID 501 and effective
  / real group 60000. These numeric values describe this private test machine,
  not hardcoded public policy or a required group assignment on another Mac.
- TCC unified logs associated the denied operation with the installed
  `/Library/PrivilegedHelperTools/surge-guard` and
  `kTCCServiceSystemPolicyAppBundles`. Administrator authentication did not grant
  App Management permission. The user was asked to grant that OS permission;
  no TCC database or security policy was modified to work around the denial.
- `surge-status --json` after recovery reported `managed:false, maintenance:false`.
  The original app's ownership/mode were unchanged; no managed-startup success
  or absence of escaped packets was inferred from this failed attempt.

Pending at this entry: successful real adoption, managed LaunchServices group,
managed update/rollback, packet-level capture verification, physical reboot,
forced interruption of the updater and actual future Surge-version compatibility.


## 2026-10-20 — final fixed-group design and ordinary-startup live test

The user chose persistent PF plus the fixed dedicated-group launcher and
SurgeGate recovery, preserving Surge's normal installer/updater. Removed the
experimental managed-app CLI, protected-layout implementation, maintenance
branches and associated tests/documentation. No App Management permission was
granted; no Surge bundle ownership, mode, path or update setting was changed by
this final deployment. The earlier unsuccessful adoption had already restored
the original installation. This design does not promise that every independent
first launch has the dedicated identity; it never expands PF permission to that
instance's ordinary group.

Implementation and deployment:

- Identity matching now explicitly rejects an ordinary group or a root UID,
  even if a caller supplies matching process text. Focused regression cases
  retain the valid dedicated identity and malformed-output checks.
- `scripts/check.sh` passed 40 groups, release compilation with warnings as errors,
  generic examples, native PF syntax and CLI/shell checks. Managed-installation
  tests were removed with that implementation. `git diff --check` passed.
- Verified the independent recovery menu before system changes. Updated Guard
  with the existing policy and backup flow, then installed Gate as the normal
  user. Installed Guard, Gate and launcher hashes match the release build. The
  reserved group remains the same after this reinstall.
- The first live-test preflight encountered Gate's not-yet-fresh post-install
  snapshot and aborted before pausing any service or quitting Surge. The next
  attempt began only after both services had published valid readiness.

Completed live test, approximately 11:15:56–11:16:31 UTC:

1. Verified allowed persistent-TCP status, a dedicated-group Surge and a working
   harmless HTTP DIRECT control request. The existing continuous packet recorder
   was retained, with the same supervisor/capture processes throughout.
2. Paused Guard for a bounded 20 seconds, with an independent timed SIGCONT
   fallback. Paused Gate to hold the test condition, also with timed/finally
   resume. Requested a normal Surge quit and verified actual process absence.
   No forced application termination, PF disable, rule clearing or global state
   flush was used.
3. Issued 150 fresh HTTP/TCP attempts to one public numeric test endpoint, before
   and after a normal LaunchServices restart. The restarted Surge had the normal
   user's effective/real group, not the dedicated group. The default route was
   observed on both the physical interface while Surge was absent and the Surge
   VIF after the ordinary-group restart.
4. Of 150 attempts, 39 timed out during TCP connect. The other 111 connected only
   within the VIF and then timed out waiting for HTTP data. None received an HTTP
   response. The packet evidence contains exactly those 111 VIF SYN-ACKs; these
   local transparent-proxy handshakes are not successful physical connections.
5. Read all eight PKTAP ring files with native tcpdump successfully and correlated
   timestamps, interfaces, process metadata and test ports. From verified Surge
   absence to Guard resume (about 18.294 seconds), the captures contain no
   physical-interface packets to this test endpoint. The earlier correct-group
   instance's connection closed with FIN/ACK before that interval. Positive
   DIRECT controls before/after include physical SYN/SYN-ACK and HTTP response
   packets, establishing that the relevant interface/target was observable.
6. While Guard was still stopped, its own anchor retained exactly the same three
   rules and insertion identity: VIF permission, only the reserved group, and
   final TCP block, with interface-bound states. The block counter increased
   from 2,846 to 9,602. The 6,756 difference includes background traffic and the
   whole read-to-read interval; it is not a per-probe count or latency measure.
7. After resuming the same Guard process, fresh status reported verified blocking
   with `surge_egress_identity_mismatch`. Resumed Gate normally terminated the
   wrong-group instance and launched a dedicated one. Within about 7.1 seconds
   after Gate resume, dedicated identity and fresh allowed status were observed.
   Ordinary HTTPS returned 200; the DIRECT HTTP control again received a reply.
8. Final inspection found both services running, Gate ready, Guard allowed with
   `persistent_tcp_egress`, ordinary Surge UID and the original dedicated GID.
   No paused process, managed application layout, managed record or maintenance
   marker remained. The 256 MB Asia/Singapore recorder remained capturing;
   reported kernel drops were zero, which is not a full-coverage certificate.

One attempted CLI DIRECT probe ran immediately after the ordinary app launch
and returned `Policy does not exist` before initialization. It is excluded as
network-enforcement evidence. No certificate checks were disabled; a separate
numeric-HTTPS DIRECT preflight had encountered an untrusted/intercepted
certificate, so the validated controls used ordinary HTTPS and harmless HTTP.

Conclusion limited to this test: the new probe traffic showed no physical bypass
in the captured absent/wrong-group interval, and enforcement continued while
Guard could not react. Existing virtual-interface handshakes are distinguished
from external connectivity. This is not proof of every application's packets,
every destination, or every possible transition. The earlier three live tests'
raw-capture review remains separately pending; this result does not retroactively
certify them.

Not performed: an actual Surge version upgrade, physical reboot/early-boot
coverage, abrupt power loss, forced Surge crash, IPv6 acceptance, interface reuse
stress across other tunnels or exhaustive packet attribution. UDP remains outside
the requested added TCP enforcement. Private raw evidence and test scripts remain
outside the repository.

## 2026-10-20 — update pause, native identity and transit-only policy

Implemented and deployed the reviewed TCP-only design. Removed the experimental
UDP additions and launcher scheduling/session calls. Identity uses native,
exact-length process information and all four effective/real UID/GID fields.
The daemon rechecks the candidate process set and binds cached trust to PID plus
process birth time. Multiple candidates invalidate trust; no `ps` fallback or
generic Sparkle process-name heuristic remains.

Gate now persists explicit update pause, acknowledges a matching request only
after automatic work settles, sends one normal quit request per recovery
attempt, and applies 30-second backoff to actual recovery failures rather than
readiness waits. SwiftBar exposes identity, pause/resume actions and separate
capture/request-history gaps. `audit-stop` now persistently disables recording
autostart; `audit-start` explicitly re-enables it.

Completed checks and installation:

- `scripts/check.sh` passed all 43 groups, including malformed/missing native
  identity, a second process appearing after cached trust, PID reuse, durable
  update requests, stale/mismatched acknowledgement, private file reads,
  failure backoff, independent history flags and unprivileged action dispatch.
  Release builds with warnings as errors and `git diff --check` passed.
- The first pause round-trip regression exposed fractional-date loss during
  JSON encoding. Request dates now use whole seconds; UUID identity distinguishes
  requests. The corrected regression passed before deployment.
- Verified the independent recovery menu before privileged installation.
  Installed binaries match the release artifacts; the system installer retained
  its backup and verified a fresh allowed state before policy replacement.
  Explicitly applied the generic enhanced + persistent-TCP policy and aligned
  the user's draft after retaining a private copy. The generic user installer
  continues preserving existing policies rather than silently resetting them.
- Loaded Gate reports `spawn type = interactive (4)`. The diagnostic thread-limit
  field still reads 32; this is not a verified thread-limit fix or crash threshold.
  Apple `adv_cmds/ps/print.c` maps the thread-priority suffix `T` to
  `POLICY_TIMESHARE`, not to a throttling flag. The new Surge process has its own
  process group without `setsid()` or `AbandonProcessGroup`.
- Paused Gate, observed fresh matching acknowledgement, restarted Gate normally,
  and verified the same persisted request and unchanged Surge process. Resumed
  automatic recovery successfully. An initial test harness incorrectly required
  immediate `ready` at resume; Gate legitimately returned `restoring` while
  draining existing session entries and then became `ready`. This was not treated
  as a protection failure or concealed as an immediate-ready result.

Completed normal-exit test, approximately 13:02:03–13:02:22 UTC:

1. Verified fresh Guard/Gate status, the dedicated identity, and a successful
   harmless numeric HTTP DIRECT control with physical packet evidence.
2. Entered acknowledged update pause, started ordinary-user TCP probes on both
   the default route and the active physical interface, and requested normal
   Surge exit. No forced quit, Guard pause, PF disable or rule clearing was used.
   A separate bounded fallback could resume only this test's pause request.
3. Confirmed Surge absence and verified Guard blocking, held the paused condition
   for approximately eight seconds, and verified Gate did not relaunch Surge.
4. Resumed Gate and observed a new Surge with dedicated effective and real GIDs,
   fresh allowed Guard status and Gate ready approximately five seconds after
   the resume request. The Guard process remained the same throughout.
5. Collected 170 TCP attempts. The 76 attempts fully contained in the verified
   absence interval had no connection or response. Ten attempts elsewhere in the
   test received data before/during normal quit; none were physical-bound probes.
   They are not falsely counted as absence-period bypass.
6. Native decoding of all eight retained ring files found no physical-interface
   TCP packets to the test target between the quit request and restored readiness.
   VIF packets during the quit transition are retained as distinct observations.
   The first post-recovery DIRECT control timed out; subsequent ordinary HTTPS,
   domain DIRECT and the same numeric DIRECT control succeeded. The timeout's
   cause was not established, so immediate end-to-end recovery is not claimed.

Recorder lifecycle verification:

- Completed `audit-stop`, verified the job was absent and its launchd entry
  disabled, then explicitly started it and obtained fresh capture status.
  Stopped it again; final state is absent/disabled, with private evidence retained.
  The original capture/supervisor processes exited. Guard's PID, own-anchor rule
  text and insertion identity did not change across these recorder operations.
- An additional attempt to review every physical outbound TCP flow is
  **inconclusive**. The recorder restart was requested before that offline export
  finished; reuse of a ring segment removed the test interval from the resulting
  broad export. The zero records in that interval are not a protection pass.
  The earlier target-specific export contains its before/after positive controls
  and transition evidence and remains the basis of the scoped result above.
  Preserve the relevant closed capture files before any recorder restart in
  future acceptance runs.
- Final live state: Guard allowed in enhanced + persistent-TCP mode, Gate ready,
  Surge dedicated identity verified, update pause released, recorder stopped with
  autostart disabled. All installed component binaries match the checked build.

These observations cover the specified target and transition, not all packets,
applications, interfaces or protocols. The test did not run a real updater.
Actual Sparkle update/hang/cancel behavior, physical reboot/early boot, forced
crash, IPv6, DHCP renewal and UDP enforcement remain unverified. Existing private
captures and diagnostic records remain outside the repository.

## 2026-10-20 — review fixes, non-disruptive verification

Scope: installation preflight, bounded command cleanup, route resolution,
Gate update/shutdown/service state, independent recovery, launcher path consistency,
structured egress candidates, and conservative SwiftBar rendering.

Performed:

- `./scripts/check.sh` passed: standalone regression checks, release build with
  Swift warnings treated as errors, native launcher consistency checks compiled
  with `-Wall -Wextra -Werror`, policy validation, CLI help/log formatting, shell
  syntax and `git diff --check`.
- New cases cover a missing installation policy after state-directory creation;
  unresolved/unknown/cyclic/broken route chains and a resolved but unlisted leaf;
  timeouts with inherited output pipes and background descendants, early parent
  exit, blocked stdin and repeated descriptor counts; strict loaded/running/absent
  service results; a failed second emergency-service query and a waiting job;
  boot/nonce-bound launch and shutdown records, obsolete launch completions,
  pending-pause acknowledgement and submitted/aborted shutdown retry semantics;
  incomplete/unknown recorder and stopped-guard menu wording; structured domain
  JSON, query failures versus empty results, IPv6/mapped IPv4 normalization,
  bounded candidate deduplication, raw integer virtual IPs and local DNS forwarding
  records with null address data.
- Native C fixtures exercise ordinary-user-owned files, no-follow opens,
  descriptor close-on-exec, inode replacement, content/mode changes and changed
  directory metadata. They never launch the installed app or use set-group rights.
- An isolated fake-tools installer test confirms `--menu-only` leaves Gate intact
  and invokes neither Gate nor the system guard. Emergency recovery fixtures use
  fake sudo/launchctl/PF tools exclusively.
- Ran `./scripts/install-user.sh --menu-only` as the normal user. It backed up and
  updated the independent user menu files. The installed renderer matches the
  release build, and its installed `--section` entry point renders both components.
- Read-only `observe-egress --json` returned valid structured JSON with successful
  DNS and virtual-IP queries and candidate-domain fields. Only schema/status
  summaries were inspected; no private observations or cache contents were saved
  in the repository. A generic `rule explain` query confirmed the current CLI's
  selected-group schema without creating a target connection.
- Before/after menu installation, the Surge process identity, Guard/Gate job PIDs,
  installed Guard/Gate/launcher hashes and Gate plist hash were unchanged.
  Surge.app and its executable retained their ordinary-user ownership, mode and
  inode. The original untracked `package-lock.json` hash was unchanged.

Not performed:

- No system guard, dedicated launcher or Gate service deployment/restart; no Surge
  quit, updater invocation, power request, or live PF mutation. PF tests used
  parse-only `-n`; these results do not establish a live protection pass.
- Actual Sparkle replacement, delayed NSWorkspace callbacks, daemon crashes,
  concurrent live management commands, macOS shutdown cancellation/retry, reboot
  and early-boot packet behavior still require separately authorized acceptance.
  The unit/state/file fixtures do not replace those live scenarios.

Residual boundaries: signature validation and pathname exec are not atomic even
with pinned-descriptor/path metadata comparisons. Keeping the app user-writable
preserves Sparkle compatibility, not isolation from malicious same-user writers.
An unresolved launch left by a crashed Gate conservatively blocks recovery and
pause acknowledgement until the app is observed or the boot changes; deleting
its marker is not proof that the launch was cancelled.

## 2026-10-20 — follow-up review of 0f7038c

The preceding entry's indefinite pending-launch limitation is addressed by this
source revision. Launch records now retain their observing Gate instance and,
where available, the native launcher's PID/birth time. A recorded dead or reused
child permits recovery with failure backoff. Missing observer/child evidence is
reported as `launch_recovery_required`; an exact-nonce command requires explicit
user confirmation that the old launch finished, failed or was cancelled. No
timeout is treated as LaunchServices cancellation or update-pause acknowledgement.
Queued shutdowns are declined and removed while a launch is unresolved. Failed
bootstrap withdraws only its own unconsumed shutdown request.

Also corrected:

- A changed Surge candidate set while allowed is rejected before signature
  validation can replace the old watcher and preserve stale route trust.
- Restart confirmation uses the actual launchctl PID. A snapshot from a different
  process reports unknown/running, rather than stopped. Malformed or unreadable
  Gate status does not prevent service management through a valid service query.
- Gate configuration/session/status reads are private and bounded. Event files
  and locks open nonblocking before rejecting special files; log-reader pipe
  ends are explicitly closed on all return paths.
- Menu and event text distinguish an orphaned launch, an update pause request
  and an acknowledged pause. Pending launch polling no longer rewrites status
  at ten times per second.

Performed without deploying or restarting services:

- Final `./scripts/check.sh` passed: all 50 Swift check groups, native C launcher
  consistency checks, release build with warnings as errors, generic policy
  validation, CLI help/log formatting, shell syntax and `git diff --check`.
- Temporary-file/native-child regressions cover living/exited/reused launcher
  identities across observer restart; legacy/orphaned launch records; exact-nonce
  recovery, old completions and blocked shutdowns; bootstrap-request withdrawal;
  malformed/duplicate service PIDs and stale snapshots; FIFO rejection with a
  bounded subprocess; repeated log-reader descriptor counts; conservative menu
  and pause-request log text. No fixture quits a real application or changes PF.
- Both newly built `status --json` commands returned parseable JSON when reading
  the existing services. The new SwiftBar renderer produced its section with
  Gate and ordered-shutdown entries. Only schema/state summaries were retained.
- The original untracked `package-lock.json` remains unmodified; its SHA-256 was
  checked before and after the work.

Not performed: no menu/service installation, Surge quit/restart, live recovery
command, real Gate crash, delayed LaunchServices failure injection, power action,
Sparkle update or live PF mutation. PF checks were parse-only. State/file/native
child tests do not certify the full live crash/shutdown sequence or packet-level
protection. The signed-pathname execution race and UDP/early-boot limitations
remain as documented; ordinary-user ownership of Surge.app was not changed.

## 2026-10-20 — strict source review of 579f647

Reviewed the changes in 0f7038c and 579f647 together with their callers across
Core, Guard, Gate, the C launcher, SwiftBar integrations, scripts, tests and
operational documentation. This entry records source/fixture verification;
it does not supersede the scope of earlier live acceptance entries.

Corrected:

- Candidate changes now invalidate signature trust before the allowed-state
  early return and invalidate route generations even while blocked. Signature
  validation rechecks the candidate inventory before caching a new identity;
  the final opening check also requires a non-nil route observation.
- Recover-launch takes request.lock before the launch-record lock. The service
  rechecks its observed launch record under request.lock before consuming a
  shutdown request, avoiding rejection based on a just-recovered orphan.
- Throwing lock initialization now has one FD owner. An isolated native Swift
  check confirmed that deinit executes after a fully initialized initializer
  throws; the old catch-plus-deinit path closed the descriptor twice. Audit
  pipes are allocated after throwing initialization steps have completed.
- Interface inventory/conversion failures propagate instead of becoming an
  empty/partial cleanup list. Block rules load before address enumeration;
  failed enumeration cannot report verified old-state cleanup.
- Audit diagnostics have bounded line/chunk memory and synchronous consumption
  rather than an unbounded main-queue backlog. A native pipe experiment showed
  that FileHandle.read(upToCount:) can wait for EOF/full input on macOS; the new
  reader uses POSIX read and retries EINTR. A pipe regression requires delivery
  while the writer remains open, in addition to EOF and oversized-line cases.
- The audit supervisor persists its process group before child launch. Stop
  checks the job again after lock release, reads the latest supervisor snapshot
  and waits for recorded groups, covering an unpublished child PID and a
  replacement supervisor. Parent identity is rechecked after group rejoining.
- Retained capture scans compare the named inode as well as the open file's
  size/mtime/ctime, so rotation cannot silently present an obsolete inode as the
  currently named ring segment.
- Service parsing rejects absent/duplicate state fields, root managers use
  the shared parser, and stop/unlock confirm job absence after acquiring the
  runtime lock. The independent shell recovery path also validates state and
  the native PID range. A current-boot unlock marker is considered before an
  undeleted old snapshot.
- Menu duration conversion rejects invalid/out-of-range timestamps instead of
  trapping on Double-to-Int conversion. Persisted update dates are bounded;
  resume acknowledges only recognized recovery/waiting states, including a
  fresh Gate whose network status is still unknown.
- Dedicated-group installation writes its protected GID reservation before
  directory-service creation. A retry retains that identity and rejects an
  occupied or malformed reservation; it never adopts an unrecorded old group.
- Removed the README's immediate bootout/anchor-flush recipe in favor of the
  existing independent helper, and aligned the Chinese README, audit contract,
  acceptance steps and AGENTS.md with the corrected behavior.

Performed:

- Final `./scripts/check.sh` exited zero: 53 Swift check groups plus the native
  C launcher group, release compilation with warnings as errors, generic policy
  validation, help/log-format smoke checks, shell syntax and git diff checks.
  There were no build warnings or errors.
- New/extended fixtures exercise early-return ambiguity and candidate changes
  during signature validation; stale launch observations after exact-nonce
  recovery; repeated failed lock construction and FD counts; interface-query
  failure; large/partial/live-pipe diagnostics and consumer failure; a child
  group surviving its original parent; capture inode replacement; malformed
  service state/PID; extreme menu/update times; and reserved-GID retry/collision.
- Native PF checks used parse-only `-n`. Recovery and installer fixtures used
  fake tools and temporary directories. The process-group fixtures created
  only disposable test subprocesses, without starting packet capture.
- Both newly built `status --json` commands returned valid JSON while reading
  the existing services (Guard allowed, Gate ready). The new SwiftBar section
  rendered both components, independent unlock and ordered power actions.
  No displayed action was executed.
- The original untracked package-lock.json retained its SHA-256
  `c9416a0c2883dbb47c4cb674c0e3705b7142cf4d59683c25b5abb5280d6df719`.

Not performed: no menu/service installation or restart, Surge quit/update,
new real packet recording, root group mutation, real recovery/power command,
live PF mutation, or live crash/queue/disk-failure injection. The lock, pipe,
process and state fixtures do not certify the complete live shutdown or crash
sequence. These fixes are in source/build artifacts, not the running services.
The mutable signed-pathname execution boundary, UDP scope and early-boot limits
remain unchanged; Surge.app ownership and Sparkle update behavior were preserved.

## 2026-10-20 — fourth convergence review of 2818dec

Reviewed the 24-file commit and connected paths across all four source components,
CPcap, SwiftBar integrations, scripts, standalone tests and operational documents.
Re-reviewed the final changes and their callers independently after implementation.
The source/fixture review ended with no remaining actionable findings identified;
this is not a proof of universal correctness or a new live protection acceptance.

Corrected:

- P1: an interface-enumeration failure in `Firewall.block()` skipped even the
  addresses remembered while allowed. Blocking rules still load first; cleanup
  now attempts remembered addresses before propagating the enumeration error.
  No verified-cleanup timestamp is published on failure. Failed cleanup retains
  the union of known/new addresses for retry.
- P2: Gate could write a merged startup/session list exceeding its own 256-ID or
  64-KiB reader limits, then fail on its next restart. Config reads now cover the
  full documented per-list ID limits (256 KiB). Sessions allow 1024 IDs per list,
  with 1-MiB session/status reads; every session writer validates encoded data
  before replacement. Over-limit snapshots preserve the previous checkpoint.
  Older Gate binaries retain their smaller limits; larger new checkpoints are
  not downgrade-compatible without reducing the lists.
- P2: pretty-printing an accepted compact policy could exceed the 64-KiB reader
  limit after `configure`, leaving the daemon unable to load it. Policy writers
  share a reader-validated serializer that uses compact JSON when indentation
  would exceed the limit, and rejects genuinely oversized results before publish.
- P2: an old audit snapshot's PGID could later be reused by an unrelated process
  group, making stop/update wait for that group. New snapshots persist native
  supervisor birth identity before child launch, and group waits recheck it.
  An absent leader still does not establish group exit; legacy records without
  birth evidence keep conservative waiting. Apple's [XNU PID allocation code](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_fork.c)
  rejects IDs held by surviving process groups, supporting the reuse distinction.
- P3: a duplicate `surge-gate run` that failed to acquire gate.lock overwrote the
  real service's status from the top-level catch. It now only reports the error;
  the service loop retains its own error publications while holding gate.lock.

Specific review conclusions:

- PacketAuditService's worker synchronously hands each line to the main queue,
  but stop/tick do not join that worker or wait for child termination. The only
  waitUntilExit is on the worker after pipe completion. No circular wait was
  found. A disposable subprocess test floods a real stderr pipe, runs a bounded
  synchronous command and signals stop on the main queue, then drains/reaps on
  the worker. This tests the scheduling pattern, not a live root audit service.
- Throwing Probe.addresses callers preserve failure semantics in CLI, daemon,
  VIF verification and passive egress sampling. Dedicated-group reservation
  retains the recorded free GID and refuses collisions/unrecorded existing groups.
- Gate recover-launch/request consumption retain request.lock -> pending-record
  lock ordering; no waiter holds a pending-record lock while requesting the
  request lock. Pending records are re-observed before shutdown consumption.
  Update acknowledgement, orphan recovery and shutdown retry contracts remain.
- Rechecked candidate/route invalidation, verified status freshness, bounded
  command pipes, audit rotation/process cleanup, recovery, passive domain lookup,
  menu rendering and launcher consistency. No further actionable issue was found
  in those reviewed paths after the fixes.

Performed:

- Final `./scripts/check.sh` exited zero: 57 Swift check groups, the native C
  launcher group and the isolated release-Gate lock-contention regression (59
  PASS groups total). Release compilation with warnings as errors, example
  validation, CLI help/log formatting, shell syntax and git diff checks passed.
  No build warning or error was reported.
- Regression fixtures include failed address enumeration and cleanup retry;
  maximum-length app IDs and 768 merged pending targets; serialized policy size
  boundaries; preservation of an old checkpoint after rejected replacement;
  live main-queue/pipe/child termination; native group identity mismatch, absent
  leaders with surviving children, legacy snapshots and current group waiting.
  All observed supervisor births are retained during stop: an older snapshot
  cannot overwrite a replacement process identity obtained from the live query.
- The release Gate executable is also run against an isolated Foundation home
  with gate.lock held and a sentinel status. It must fail before app inventory or
  launch work and leave the sentinel unchanged. No installed service is stopped.
- Existing PF tests use parse-only `-n`; recovery/menu installers use fake tools
  and temporary directories. No production packet recorder was started.
- Read-only release CLI checks returned machine-readable status JSON (Guard
  allowed; Gate running, fresh and ready). The SwiftBar section contained both
  components, independent unlock and ordered restart/shutdown actions; no action
  was executed. The original untracked package-lock.json SHA-256 still matched
  `c9416a0c2883dbb47c4cb674c0e3705b7142cf4d59683c25b5abb5280d6df719`.

Not performed: no live PF mutation, installed service/menu replacement, Surge
quit/restart, group creation, Sparkle update, shutdown/reboot, or live crash/disk
failure injection. Fixes remain in source/build artifacts and are not deployed.
The signed-pathname exec race, UDP/early-boot scope and limitations of passive
observations remain documented. package-lock.json is retained unchanged.

## 2026-10-20 — follow-up review of the uncommitted fourth-round fixes

Continued reviewing the working tree on 2818dec, including Gate launch/request
interleavings, command argument conversion, recorder stop/upgrade compatibility,
process-group identity, diagnostics backpressure, egress parsing and recovery.
Found and corrected two additional P2 issues:

- Foundation URLComponents accepts raw NUL in a route URL, while the command's
  C argument conversion truncates at NUL. A query could therefore evaluate a
  different URL from the configured one. Configuration validation now rejects
  raw control characters; Command rejects NUL in executable paths and arguments
  before allocating pipes or spawning. Pipe input still supports embedded NUL,
  and percent-encoded URL data remains accepted.
- Recorder stop skipped a legacy capture PID whenever it also knew a supervisor
  process group. Older children can have a separate group, so group exit alone
  cannot confirm their exit before replacement. Stop now retains every legacy
  PID observed before/after unloading and waits for both groups and legacy
  children. Missing birth evidence remains conservative; waiting never kills an
  unrelated process or infers capture exit from supervisor exit.

Performed:

- Focused standalone checks passed. New fixtures cover raw NUL arguments and
  executable paths, control-character route URLs, preserved NUL pipe data, and
  a surviving legacy child after its supervisor group has drained.
- Full `./scripts/check.sh` exited zero: 58 Swift groups, the native C launcher
  group and isolated release-Gate contention check, for 60 PASS groups total.
  Release warnings-as-errors build, CLI examples/help, shell syntax and diff
  checks passed without build warnings or errors.
- An additional release CLI fixture rejected raw NUL/newline URLs and accepted
  literal percent-encoded data. Read-only JSON status queries remained valid:
  Guard allowed/running; Gate ready/running/fresh.
- Re-reviewed both fixes and connected callers after testing. No additional
  actionable finding was identified in this follow-up review.
- Original untracked package-lock.json SHA-256 remained
  `c9416a0c2883dbb47c4cb674c0e3705b7142cf4d59683c25b5abb5280d6df719`.

Not performed: installed service/menu replacement, Surge termination/restart,
live packet-recorder stop/upgrade, live PF changes, shutdown/reboot or Sparkle
updates. Only disposable test children were signalled. Changes remain uncommitted
and undeployed; source review and fixtures do not establish a live protection pass.

## 2026-10-20 — independent re-review of the follow-up working tree

Rechecked daemon readiness/route invalidation, Gate checkpoint and request flows,
management/recovery callers, bounded commands, recorder process and pipe handling,
state readers/writers, menu output and the preceding fixes on 2818dec.

Corrected one additional P2 issue: Gate ignored extra arguments on several
commands and did not handle command-level help. For example, `stop --help` would
dispatch stop and `install --help` would dispatch installation. A pure command
parser now validates all Gate commands before management locking/dispatch and
maps help to display-only behavior. Existing flags, shutdown actions and exact
UUID/confirmation requirements are preserved; extra/duplicate flags are errors.

Performed:

- Full `./scripts/check.sh` exited zero after the fix: 59 Swift check groups,
  one native C group and two release-Gate regression groups (62 PASS total).
  Release warnings-as-errors compilation had no warnings or errors.
- Pure parser tests cover every no-option action, command help, valid status/log
  flags, shutdown/recovery options, unknown commands, duplicate/extra flags and
  missing arguments. A temporary Foundation home with gate.lock already held
  verifies release `run --help`, `run -h` and invalid run arguments return before
  service locking and preserve the owner's status. No management action against
  an installed service is invoked by these regression tests.
- Re-reviewed parser/dispatch consistency and the final changes. No further
  actionable finding was identified in this review.
- Read-only release status commands still returned valid JSON: Guard allowed and
  running; Gate ready, running and fresh. Diff checks passed. The original
  untracked package-lock.json SHA-256 remains
  `c9416a0c2883dbb47c4cb674c0e3705b7142cf4d59683c25b5abb5280d6df719`.

Not performed: installed service/menu updates, Surge quit/restart, live PF or
packet-recorder changes, ordered shutdown/reboot or Sparkle updates. Source and
build changes remain uncommitted and undeployed. These checks do not certify
live protection or prove absence of bugs under every possible runtime ordering.

## 2026-10-21 — further convergence review

Re-reviewed the cumulative working-tree changes on 2818dec and their callers:
Gate command parsing, pending-launch completion/recovery, request-lock ordering,
update acknowledgement and shutdown retry; daemon trust/route invalidation;
remembered-address cleanup; recorder main-queue backpressure, stop/reaping and
legacy/group identity handling; bounded commands and state/log files; recovery,
launcher consistency checks, domain/IP parsing, menus and installation scripts.
No additional actionable defect was identified. No source or test logic was
changed in this pass.

Performed:

- Full `./scripts/check.sh` exited zero: 59 Swift check groups, one native C
  group and two release-Gate regression groups (62 PASS total). Release
  warnings-as-errors compilation, example/help checks and shell syntax passed.
- Read-only release status commands returned valid JSON: Guard allowed/running;
  Gate ready/running/fresh; recorder unknown_or_stopped, no_bypass_verified false.
  The recorder result does not establish that residual capture processes are absent.
- `git diff --check` passed. Original untracked package-lock.json SHA-256 remained
  `c9416a0c2883dbb47c4cb674c0e3705b7142cf4d59683c25b5abb5280d6df719`.

Not performed: installed service/menu replacement, live Surge or recorder
stop/restart, live PF changes, ordered shutdown/reboot, Sparkle updates or real
packet-path acceptance. The cumulative changes remain uncommitted and undeployed;
this review/test pass is not a proof of zero bugs or live protection.

## 2026-10-21 — retained capture capacity review

Re-reviewed the working tree on 2818dec: daemon readiness and candidate/route
invalidation; Gate launch recovery, request locking, update acknowledgement and
shutdown retry; recorder backpressure and process cleanup; commands, file/lock
ownership, recovery, dedicated launcher, egress parsing, menus and installers.

Corrected one P2 issue in `audit-coverage`: after reducing a 1024/4096 MB ring to
256 MB, retained older segments could exceed the newly configured 32 MB segment
limit and be rejected as unsafe/oversized despite being valid history. The range
reader now defaults to the largest supported segment limit (512,000,000 bytes
plus 65,536 bytes of overhead), and the CLI uses that limit independently of the
current recording capacity. Ownership/type checks and the per-file scan timeout
are retained. The packet-audit contract now explains that larger old segments
remain until overwritten and can temporarily exceed the reduced ring capacity.

Performed:

- A private valid pcap fixture exceeding 32 MB reproduced the old reduced-size
  limit failure (`Unsafe or oversized capture`). After the fix, all 520 records
  and their original time range were read successfully. A sparse file one byte
  beyond the maximum supported segment bound was still rejected. Fixtures were
  temporary; installed captures were not opened or changed.
- Full `./scripts/check.sh` exited zero: 59 Swift groups, one native C group and
  two release-Gate regression groups (62 PASS total). Release warnings-as-errors
  compilation, examples/help, shell syntax and diff checks passed.
- Re-reviewed the final reader/CLI/test/doc changes and other reader callers;
  no further actionable finding was identified in this pass.
- Read-only release JSON status: Guard allowed/running; Gate ready/running/fresh;
  recorder unknown_or_stopped with no_bypass_verified false. The recorder status
  does not establish that residual capture processes are absent.
- Original untracked package-lock.json SHA-256 remains
  `c9416a0c2883dbb47c4cb674c0e3705b7142cf4d59683c25b5abb5280d6df719`.

Not performed: installed service/menu updates, live recorder capacity changes,
Surge or recorder stop/restart, live PF changes, ordered shutdown/reboot, Sparkle
updates or packet-path acceptance. Changes remain uncommitted and undeployed;
this source/test review does not certify live protection or prove zero bugs.

## 2026-10-21 — post-5407b7b shutdown and status review

Re-reviewed Gate pending launches, update acknowledgement, shutdown submission,
stop/uninstall and lock ownership; daemon candidate/route invalidation and state
cleanup; recorder backpressure, child/group shutdown, retained captures and
freshness; command/file lifetimes, recovery, launcher checks, egress parsing and
the menu/install entry points.

Fixed two findings:

- P2: Gate uninstall left an unconsumed same-boot shutdown request behind, so a
  later reinstall/start could execute it. Stop also ignored request-removal
  errors. Both now cancel queued requests after confirming the service is absent
  while holding command.lock and gate.lock. Cancellation failure prevents a
  success report or removal of the installed service files. Cancellation does
  not remove pending-launch fences or undo power requests already sent to macOS.
- P3: PacketAuditSnapshot.read checked freshness before its bounded launchd
  query, permitting a snapshot to expire during the query and still be returned.
  It now checks freshness after service/PID validation, immediately before return.

Performed:

- Temporary-file regressions cover queued-request cancellation, repeated
  cancellation, malformed content, symlink removal without following its launch
  fence target, and permission-denied cancellation retaining the request and
  returning an error. No live Gate stop/uninstall was invoked.
- Final ./scripts/check.sh exited zero: 60 Swift groups, one native C group and
  two release-Gate groups (63 PASS total). Existing boot/monotonic/counter
  freshness checks, release warnings-as-errors build, examples/help, shell
  syntax and diff checks passed.
- Re-reviewed the final call sites and cleanup ordering; no additional
  actionable finding was identified in this pass.
- Read-only release status commands returned valid JSON: Guard allowed/running;
  Gate ready/running/fresh; recorder unknown_or_stopped with no_bypass_verified
  false. This recorder result does not verify residual-process absence.
- Original untracked package-lock.json SHA-256 remained
  c9416a0c2883dbb47c4cb674c0e3705b7142cf4d59683c25b5abb5280d6df719.

Not performed: installed service/menu replacement, live stop/uninstall/reinstall,
Surge or recorder restarts, ordered shutdown/reboot, Sparkle updates, live PF
changes or packet-path acceptance. Fixes have not been deployed; source review
and these checks do not prove zero bugs or live protection.

## 2026-10-21 — post-4476608 Gate authorization freshness review

Reviewed the previous shutdown cancellation and audit freshness changes, Gate
launch/pause/shutdown lock ordering, daemon trust and route invalidation, recorder
pipe/child lifetimes, state and log files, egress parsing, launcher validation,
recovery, CLI and menu/install paths.

Fixed one P2 finding: Gate read an allowed Guard report before potentially slow
Surge signature/identity checks, then restored applications using the retained
state string without checking whether its status or PF audit had expired. Gate
now reads the report after those checks and pause/launch-fence checks, and requires
firewallVerified at application restoration. It reads Guard status again after
the launch attempt before publishing Gate readiness. This changes application
admission/reporting; it does not change PF enforcement.

Performed:

- Added deterministic checks that expire the status and PF-audit timestamps
  independently in a retained allowed report. The state string alone remains
  allowed, while firewallVerified rejects it and revalidation returns unknown.
  These are status-predicate checks, not an NSWorkspace timing integration test.
- Final ./scripts/check.sh exited zero: 61 Swift groups, one native C group and
  two release-Gate groups (64 PASS total). Release warnings-as-errors compilation,
  examples/help, shell syntax and diff checks passed without build diagnostics.
- Re-reviewed the changed call order, launch success/failure branches, pending
  launch fencing, pause acknowledgement and retry behavior. No additional
  actionable finding was confirmed in this pass.
- Read-only release JSON status commands succeeded: Guard allowed/running;
  Gate ready/running/fresh; recorder unknown_or_stopped with no_bypass_verified
  false. Recorder status does not verify residual-process absence.
- The original untracked package-lock.json remains untouched, SHA-256
  c9416a0c2883dbb47c4cb674c0e3705b7142cf4d59683c25b5abb5280d6df719.

Not performed: injected delays in live signature/application launch operations,
service/menu deployment, Surge or recorder restarts, ordered shutdown/reboot,
Sparkle updates, live PF changes or packet-path acceptance. The fix is not
deployed; these source and isolated checks do not certify live protection.

## 2026-10-23 — post-d4c6d7b convergence review

Rechecked Gate authorization freshness, launch recovery and shutdown lock order;
recorder main-queue backpressure and child/group exit; command pipe cleanup,
atomic state/log writes, daemon loss handling, address cleanup, dedicated-group
reservation, egress domain parsing and recovery/menu paths. No new actionable
functional defect was confirmed in this pass.

Corrected one P3 presentation issue in the SwiftBar power-operation explanation:
the previous wording implied prevention of leaks before and after reboot, beyond
the documented early-boot limitation. It now describes normal app exit followed
by block verification and explicitly excludes an early-boot zero-leak guarantee.
No control flow or service/PF operation changed.

Performed:

- Final ./scripts/check.sh exited zero with 64 PASS groups: 61 Swift, one C and
  two release-Gate checks. Release warnings-as-errors build, example validation,
  CLI help, shell syntax and diff checks passed without build diagnostics.
- Ran the release SwiftBar renderer read-only and checked that the corrected
  explanation and both ordered restart/shutdown actions were present. No menu
  action was invoked and no installed menu file was replaced.
- Read-only JSON commands succeeded: Guard allowed/running; Gate ready/running/
  fresh; recorder unknown_or_stopped with no_bypass_verified false. The recorder
  result does not establish absence of residual capture processes.
- Original untracked package-lock.json remained unchanged, SHA-256
  c9416a0c2883dbb47c4cb674c0e3705b7142cf4d59683c25b5abb5280d6df719.

Not performed: service/menu deployment, Surge or recorder restarts, live PF
mutation, ordered shutdown/reboot, Sparkle updates or packet-path acceptance.
This review and its tests do not prove zero bugs or live protection.

## 2026-10-23 — Gate child exit diagnostics

Added dedicated-launcher child start/exit records, native child identity and
launch/run correlation, normal-exit versus uncaught-signal status, and callback
wall/monotonic timestamps. Normal Surge quit requests now record identity-repair
or ordered-power-operation intent before the call, followed by request acceptance
without claiming actual exit. The existing private bounded EventFile is reused.
Callbacks use asynchronous main-queue delivery; they do not change pending launch,
shutdown, retry, recovery or firewall decisions. Startup verification also reaches
an observed pending child that settles after the initial launch wait expires.

Performed:

- Isolated child tests cover exit codes 0 and 9, self-SIGTERM/SIGKILL, native birth
  identity, mismatched birth-time verification, early exit without identity,
  overlapping launch callbacks and failed spawn without a fictitious exit.
  A bounded watchdog protects the synchronous-main-wait regression. Only disposable
  test processes receive signals; no running applications are terminated.
- Checked readable and JSON output preserve exit evidence, keep the signal sender
  unknown, distinguish quit acceptance from completion, and expose coverage gaps.
- Final `./scripts/check.sh` exited zero: 63 Swift groups, one native C group and
  two release-Gate groups (66 PASS total). Release warnings-as-errors compilation,
  examples/help, shell syntax and whitespace checks passed.
- Re-reviewed callback lifetime, serialized logging, child replacement, native
  identity matching and both Surge quit call sites. Exit data does not mutate
  Gate state or authorize networking.
- Read-only JSON status commands succeeded: Guard allowed/running and Gate
  ready/running/fresh. Existing Surge, Guard and Gate PIDs remained unchanged.
  The pre-existing untracked package-lock.json was not modified.

Not performed: deployment/service replacement, real Surge exit or sleep/wake
reproduction, ordered power operations, live PF changes or packet-path acceptance.
The running Gate has not gained these diagnostics. Coverage starts only for
children launched by the updated Gate; pre-existing/NSWorkspace processes and
exits after Gate stops remain outside it. Exit status cannot identify an external
signal sender or recover evidence from a previous unobserved exit.

## 2026-10-24 — explicit private LAN TCP exception

Added the opt-in `allow_lan_tcp` policy flag (requires persistent TCP), dynamically
bound RFC1918 TCP rules for up `enN` private IPv4 addresses in both allowed and
blocked states, and effective scope in status/menu/logs. No Surge profile change
was required. Existing policy modes, route checks and public TCP restrictions
are retained. New fields must follow upgrades of running Guard/Gate and the menu.

Performed:

- Final `./scripts/check.sh` exited zero with 71 PASS groups (68 Swift, one C,
  two release-Gate), including release warnings-as-errors, examples, CLI/help,
  shell syntax and whitespace checks. New cases cover policy compatibility and
  invalid types; private-range boundaries; canonical addresses and NUL/newline
  injection; interface eligibility, duplicate/oversized inventory and withdrawal;
  ready/blocked rules; status JSON and log scope; and native PF parse-only output.
- Re-reviewed config changes, early loss handling, interface withdrawal, state
  cleanup and failure paths. Invalid configuration/inventory revokes exceptions;
  a group-less allow call rejects pending LAN rules before any PF operation.
- Ran `./scripts/install-user.sh --menu-only` and verified independent offline
  recovery entries. Updated Guard through its managed backup/rollback installer,
  then Gate, then applied the preserved local policy with only LAN opt-in added.
  Guard and Gate published fresh allowed/ready status; installed Guard/Gate/menu
  hashes matched the checked release. Gate's initial 20-second ready wait expired
  while it processed its existing restoration list; subsequent fresh status was
  ready without another restart. The running Surge PID/start time was unchanged;
  its ordinary-user ownership and launcher mode 2755 were retained.
- Read back the own anchor: six LAN rules constrain one actual interface/address,
  both directions and three private networks; VIF, dedicated-group and public TCP
  block rules remain. Direct SSH to a controlled LAN Mac succeeded without a
  proxy. A reverse TCP exchange from that Mac to a temporary private-only listener
  also succeeded; the one-shot listener closed afterward.
- A physical-interface-bound TCP attempt to a public endpoint timed out, while a
  CONNECT through Surge to the same endpoint succeeded. This is a bounded socket
  sample plus rule verification, not proof of complete packet coverage. The menu
  renderer showed effective LAN scope and retained independent recovery actions.
- Original untracked package-lock.json SHA-256 remained
  c9416a0c2883dbb47c4cb674c0e3705b7142cf4d59683c25b5abb5280d6df719.

Not performed: real Surge exit, blocked-state LAN acceptance, network/address
switch, cold boot, malformed live policy or forced enumeration failure. These
paths have source/unit coverage only. No remote protection installation, global
PF disable/flush, arbitrary live rule patch or packet-by-packet bypass claim.
The installed Gate also includes the preceding exit diagnostics, but the retained
pre-existing Surge process is outside that observer's child-exit coverage.

## 2026-10-24 — fresh installation anchor preflight

An authorized first installation on a second Mac exposed an installer defect:
`pfctl -n` tried to load this tool's not-yet-created anchor file from the planned
main configuration. The preflight safely stopped before publishing a helper,
policy, PF configuration or service; it did not quit Surge or load live PF rules.
Preflight now parses the planned blocked anchor inline while retaining existing
anchor loads. Installation still writes the original separate anchor reference.
The fresh-install instructions also install the fixed launcher before enabling
persistent TCP, which needs that launcher's dedicated group.

Performed: the local full `scripts/check.sh` passed all 72 groups, including
native parse-only checks for the initial configuration, preserved Apple anchor,
missing/duplicate/edited managed blocks and invalid PF syntax. The target Mac
also passed the new parser regression with its managed anchor file absent.
No live firewall mutation is part of these regression checks.

## 2026-10-24 — second Mac installation acceptance

Deployed runtime source commit 61ad869 to an arm64 Mac on macOS 14.5 after
building and checking it on that machine. Both machines passed 72 check groups.
The target's Command Line Tools emitted SwiftPM XCTest SDK discovery diagnostics;
standalone tests and release compilation still completed successfully. Target
binaries were compared to the tested build before declaring installation complete.

Performed:

- Installed the signed SwiftBar 2.1.1 application and independent recovery menu
  before privileged operations. The menu uses a circle title, size 12, a 30-second
  interval and an explicit refresh action; rendered recovery entries were checked.
  No other machine's startup app list, credentials or profile was copied.
- Obtained administrator authorization in the logged-in GUI session after SSH
  could not provide authorization interaction. Installed the fixed helper/launcher,
  configured persistent TCP plus private LAN access and the existing group-only
  route requirement, started Guard, then installed the normal-user Gate.
- Guard and Gate published fresh allowed/ready status. All six native readiness
  conditions and the configured rule decision passed. Native launcher validation
  returned the console UID and dedicated GID; mode 2755 and normal-user ownership
  of Surge.app were retained. Guard/Gate/menu/launcher hashes matched the build.
  System and user Launchd plists have RunAtLoad and KeepAlive enabled.
- Direct LAN SSH and a reverse private TCP exchange both succeeded after enabling
  protection on the target. Temporary test listeners were closed. Physical-bound
  public TCP timed out while a CONNECT through Surge to the same public endpoint
  succeeded. These are bounded connection checks, not complete packet coverage.
- Rule initialization/state cleanup interrupted an SSH channel; a fresh LAN
  connection recovered. Surge CLI queries also failed temporarily during startup
  and application replacement, keeping the gate blocked until valid results
  returned. The configured route requirement was never weakened to pass a check.
- During acceptance, the observed Surge version changed from 6.9.0 to 6.10.0.
  The new exit observer captured an exit code of zero, followed by an ordinary-group
  replacement that Gate normally quit and relaunched with its dedicated group.
  The recorded exit status alone does not identify who initiated the replacement.
- After that replacement, 45 consecutive status samples were allowed, with one
  Guard run, fresh ready Gate status and an unchanged final Surge PID. The temporary
  setup agent was removed. Gate has an empty explicit startup list and session
  restoration enabled; it does not import a different Mac's session.
- The originating Mac's running Surge process remained unchanged. Its original
  untracked package-lock.json was neither modified nor committed.

Not performed: desktop screenshot/visual acceptance, cold boot or login-cycle
acceptance, sleep/wake, deliberate live interface-enumeration failures, blocked-
state LAN fault injection or a packet-by-packet audit. Startup/state cleanup may
interrupt LAN sessions; UDP and early boot remain outside a zero-bypass claim.

## Source verification — macOS-update attachment recovery, 2026-10-25

- Added conservative recovery for a missing managed attachment in a recognized
  Apple default disk/live layout. Recovery requires the protected existing
  installation, keeps a private pre-repair backup, checks concurrent changes,
  and retries a live attachment completed before the disk write. Custom layouts
  and malformed markers remain errors. Management start now holds the runtime
  lock while preparing the attachment.
- Native parse-only testing found that `pfctl -R` with the default optimizer can
  emit “Must enable table loading for optimizations” and omit the nested rules
  while returning zero. The recovery load uses `-R -o none`; the regression
  inspects emitted blocking rules and default wildcard attachments. Production
  recovery also reads back the live block label before publishing disk changes.
- Added bounded, read-only disk-attachment diagnostics to unknown/stopped status,
  preserving raw status errors and never asserting verified PF from disk content.
  The menu explains attachment failures. Installation output and both READMEs
  now distinguish plugin installation from SwiftBar login-startup acceptance.
- Commit review found that failed disk/backup checks could otherwise leave a
  previously allowed live anchor unchanged during daemon startup. Preparation
  failures now attempt normal verified blocking before returning the original
  error. Callback fault tests cover failure before repair, failure after live
  attachment, and an unsuccessful block without a false protection claim.
- `scripts/check.sh` passed with 76 PASS lines, including the new default-layout,
  interrupted-repair, custom-rule rejection, native filter-only parsing and
  diagnostic-state cases, plus existing launcher/Gate checks and release builds.
- No installed helper, user service, login item, live PF rule or Surge process
  was changed. The existing untracked package-lock file was left untouched.

Not performed: privileged live attachment repair, actual failed-write/load
injection against PF, macOS update/reboot acceptance, SwiftBar login/visual
acceptance, or deployment to another Mac. Passing these source checks does not
establish live protection or compatibility with every installer environment.

## 2026-10-25 — deployment after a macOS update

Deployed runtime source commit 353f790 to the second arm64 Mac after its update
from macOS 14.5 to 14.8.9. The pre-installation disk configuration had lost the
managed PF attachment, Guard repeatedly failed startup, and Gate waited for
verified blocking before correcting Surge's ordinary-group identity.

Performed:

- Built the archived commit on the target with its updated Command Line Tools;
  `scripts/check.sh` passed with 76 PASS lines. Installed the independent recovery
  menu with `install-user.sh --menu-only` before privileged changes.
- Used the official installer after administrator authorization in the logged-in
  GUI session. It retained the existing policy, backed up prior files and restored
  the managed attachment. Initial verified blocking allowed Gate to normally quit
  and relaunch Surge with the dedicated group; Guard then verified permission.
  Installed the updated Gate after that recovery completed.
- Read back enabled PF, the root attachment before the Apple wildcard anchor,
  and the live LAN, VIF, dedicated-group and TCP-block rules. Disk configuration
  contained the managed block again. No global PF disable/flush was used.
- Guard and Gate remained allowed/ready for 45 consecutive samples, with one Guard
  run and an unchanged Surge PID. Both services were still running on a subsequent
  independent check. All three installed binary hashes matched the tested build;
  launcher validation passed with dedicated GID 60000 and mode 2755, while the
  application retained its ordinary-user owner. The policy hash was unchanged.
- A fresh LAN SSH connection and reverse private TCP exchange succeeded. A public
  TCP attempt bound to the physical interface timed out, while CONNECT through
  Surge to the same endpoint succeeded. The temporary listener was closed. These
  bounded socket tests do not establish packet-by-packet coverage.
- Installed a user LaunchAgent that opens the existing SwiftBar application once
  at login; its startup command exited successfully and SwiftBar remained running.
  Rendered output showed verified permission, ready Gate status, the circle title,
  explicit refresh and independent recovery actions. The temporary setup agent
  was removed; deployment evidence and backups were retained privately.
- The originating Mac's services were not redeployed and its Surge PID remained
  unchanged. Its untracked package-lock.json was neither changed nor committed.

Not performed: another macOS update, cold boot/login-cycle or visual menu
acceptance, deliberate live write/load failure injection, or a full packet audit.
Rule initialization interrupted an existing SSH channel before fresh LAN access
recovered. Custom PF layouts still require manual review; this acceptance does
not establish compatibility with every macOS installer environment or coverage
of UDP and early-boot traffic.

## 2026-10-25 — originating Mac upgrade acceptance

Upgraded the originating Mac on macOS 15.7.7 from checkout e0f53ea, whose runtime
sources match 353f790. Its existing PF attachment and Surge dedicated-group
identity were healthy before installation; attachment repair was not exercised
on this machine.

Performed:

- Ran `scripts/check.sh` successfully with 76 PASS lines, staged the tested
  executables privately, and ran `install-user.sh --menu-only`. Verified the
  independent recovery entries before administrator-authorized installation.
- Used the official system installer, which retained a rollback backup and
  returned verified allowed status. Installed Gate as the normal user afterward.
  Read back enabled PF and the root attachment, LAN, VIF, dedicated-group and
  persistent TCP-block rules.
- Checked 45 consecutive allowed/ready samples, then independently checked both
  services again. All six native readiness conditions passed, the new Guard had
  one run, and the existing Surge PID remained unchanged throughout the upgrade.
  Both service plists retained RunAtLoad and KeepAlive.
- Compared all three installed runtime executables and the user menu renderer to
  the tested build. Launcher validation passed with dedicated GID 60000 and mode
  2755; Surge.app retained its ordinary-user owner. Policy, Gate configuration,
  disk PF configuration and the combined SwiftBar plugin were byte-for-byte
  unchanged. The section renderer reported verified permission and ready Gate;
  the existing SwiftBar process remained running.
- Connected to a private LAN SSH endpoint and read its protocol banner. A public
  TCP attempt bound to the physical interface timed out while CONNECT through
  Surge to the same endpoint succeeded. These bounded connection checks are not
  a full packet audit. Backups and detailed evidence remain private.
- Left the original untracked package-lock.json unchanged and uncommitted.

Not performed: reboot/login-cycle, another macOS update, visual menu acceptance,
deliberate live attachment damage, update rollback injection or packet-by-packet
coverage testing. UDP and early-boot limitations remain unchanged.

## 2026-10-25 — read-only software update compatibility checks

With the upgraded guard allowed on macOS 15.7.7, `softwareupdate --list` completed
successfully in about 14 seconds and listed macOS, Safari and Command Line Tools
updates. No download/install/restart option was supplied. HTTPS HEAD requests to
Apple update catalog/CDN hosts also completed with certificate validation; their
401/404 responses establish HTTP reachability, not successful update downloads.
Guard remained allowed with all six readiness conditions passing afterward.

Code review confirms there is no Apple-update exemption or cross-reboot system
update maintenance mode. Persistent TCP rejects public physical-interface traffic
outside the Surge exceptions; failed readiness or configured route checks load
blocking rules. Normal daemon termination retains blocking rules, and startup
blocks before probing Surge. Default attachment recovery repairs post-update
protection but does not remove these update-networking dependencies.

Not performed: update payload download, preparation/personalization, firmware
installation, reboot or first-login update completion. These read-only successes
do not establish uninterrupted networking throughout a system update.
