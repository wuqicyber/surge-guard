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
