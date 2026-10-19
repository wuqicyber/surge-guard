# Working in this repository

Read README.md first. It is the operational contract for all three components.

## Source map

- `Sources/SurgeGuardCore`: configuration validation, native readiness probes,
  bounded system commands, PF rules, status freshness and event logging.
- `Sources/SurgeGuard`: privileged daemon, CLI and SwiftBar menu renderer.
- `Sources/SurgeGate`: unprivileged application startup/session/shutdown service.
- `integrations/swiftbar`: thin plugin invoking the installed renderer.
- `scripts/install-user.sh`: user service/plugin installation; never run with sudo.
- `Tests/SurgeGuardTests`: standalone checks; no live firewall mutation or app quits.

## Contracts

- Keep public examples generic. Never commit a real profile, node credentials,
  private configuration, machine-specific paths, logs or diagnostic bundles.
- PF updates stay inside `io.github.surge-guard`. Do not globally disable PF,
  flush all state or replace unrelated configuration to simplify recovery.
- Preserve the existing signature, extension, VIF, route and IPv6 checks.
- Configured route checks fail closed. Never convert a malformed/missing policy,
  failed CLI query or expired result into enhanced-only success.
- Omitted allowed_final_policies means exact group matching without a node
  allowlist; a supplied list remains nonempty and restrictive. Null/empty lists
  are errors. DIRECT/REJECT and unresolved groups remain blocked in both forms.
  Upgrade older binaries with their existing policy before applying group-only
  JSON; older readers reject the omitted field and would block networking.
- Run user-owned Surge CLI code only after dropping privileges. Do not execute
  user scripts or configured shell commands as root.
- A condition check is not a claim that PF is active. A cached status must be
  bound to the current boot, process and monotonic freshness limits.
- Set state-file permissions on the staged inode before publishing with rename.
  Foundation atomic rewrite followed by chmod can briefly publish 0600 under a
  daemon umask of 077. Use AtomicFile through the owner-validating wrappers;
  retain the concurrent permission/content regression test.
- Keep human logs clear about component, state, cause, impact and recovery.
  Status-read failure does not establish a network outage. Preserve raw error,
  event and process fields in JSON. SwiftBar's user-owned formatter must stay
  unprivileged; only the fixed log-reading command receives sudo.
- Command must explicitly close every pipe end, including unused stdin pipes,
  on success, failed launch and timeout. Keep repeated-call descriptor checks.
  A failed service query is unknown, never evidence the daemon stopped.
- Both event logs use EventFile: current plus one previous file, each at most
  1 MiB, with private ownership/permissions and a writer lock. Do not add
  unbounded service stdout/stderr files or log every unchanged polling tick.
- SurgeGate must consume verified daemon status, not proxy-port/utun guesses.
  Do not reintroduce force-kill, `pkill -f`, or success messages after app errors.
- Install/verify the independent SwiftBar recovery menu before privileged changes.
  `launchctl bootout` may return before daemon cleanup releases its lock. Wait
  for actual lock/PID release, back up before replacement, verify fresh PF status
  after startup and attempt rollback on update failure. Never fix this with sleeps
  of a guessed duration or repeated forced restarts. Recovery must work offline.
- Independent emergency/log actions must not query the guard executable, even
  for help/capabilities. A service-query error is not service absence: refuse
  anchor clearing on unexpected errors or a running job without a valid PID.
- Document the reactive/early-boot limitations accurately. Do not market this
  external gate as guaranteed packet-by-packet enforcement.
- A known tunnel/process loss while allowed must block before remaining probes
  and integrity queries. Watch the verified native service, reject obsolete
  callbacks and distinguish rule loading from old-state cleanup in timing logs.
  Never treat callback latency as actual failure-to-packet-block latency.
- Egress observations are passive evidence, never inputs to PF permission.
  Use the second nettop delta frame, expose missing counters/interfaces/UDP peers,
  and separate system-extension/local activity from public application warnings.
  Reported socket interfaces do not verify packet paths. Label receive-only
  records; wildcard UDP peers stay unknown even on a known service port. Never
  describe these counters as confirmed public direct traffic or proof of bypass.
  No observations is not a no-bypass claim; keep the sampler asynchronous and
  bounded, and retain JSON evidence/deduplication and failure/recovery events.

## Validation and delivery

Run `scripts/check.sh` after changing logic. Add focused cases for new parsing,
failure handling or state transitions. Check CLI JSON remains machine-readable.
Use `docs/acceptance.md` for authorized live tests, and record performed versus
unperformed tests in `docs/verification.md`. Read-only checks can run normally;
perform deployment and disruptive tests within the user's authorized scope.
Do not infer a live protection pass from unit tests or a successful build.
