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
- Run user-owned Surge CLI code only after dropping privileges. Do not execute
  user scripts or configured shell commands as root.
- A condition check is not a claim that PF is active. A cached status must be
  bound to the current boot, process and monotonic freshness limits.
- SurgeGate must consume verified daemon status, not proxy-port/utun guesses.
  Do not reintroduce force-kill, `pkill -f`, or success messages after app errors.
- Install/verify the independent SwiftBar recovery menu before privileged changes.
  `launchctl bootout` may return before daemon cleanup releases its lock. Wait
  for actual lock/PID release, back up before replacement, verify fresh PF status
  after startup and attempt rollback on update failure. Never fix this with sleeps
  of a guessed duration or repeated forced restarts. Recovery must work offline.
- Document the reactive/early-boot limitations accurately. Do not market this
  external gate as guaranteed packet-by-packet enforcement.

## Validation and delivery

Run `scripts/check.sh` after changing logic. Add focused cases for new parsing,
failure handling or state transitions. Check CLI JSON remains machine-readable.
Use `docs/acceptance.md` for authorized live tests, and record performed versus
unperformed tests in `docs/verification.md`. Read-only checks can run normally;
perform deployment and disruptive tests within the user's authorized scope.
Do not infer a live protection pass from unit tests or a successful build.
