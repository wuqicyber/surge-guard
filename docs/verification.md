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
  Samples did not identify public application egress outside Surge during those
  intervals; they are not an exhaustive historical or packet-level audit.
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
