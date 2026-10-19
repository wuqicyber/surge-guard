# Troubleshooting for people and agents

Start with these read-only commands. A successful condition probe is not proof
that the service/PF is active.

```sh
/Library/PrivilegedHelperTools/surge-guard status --json
/Library/PrivilegedHelperTools/surge-guard doctor
sudo /Library/PrivilegedHelperTools/surge-guard doctor
sudo /Library/PrivilegedHelperTools/surge-guard logs
```

The last command renders retained events as readable records with local time,
severity, state/reason and expected/actual routing details. `logs --follow` uses
the same readable format for new events. `logs --json` emits JSON Lines for agents.
Old plain-text records stay readable and get a JSON wrapper in machine mode.
Following the log
need not print anything new while conditions stay unchanged. Events rotate
at 1 MiB; the previous file is `events.log.1` in the same private state directory.
Never make the private directory world-readable to simplify menu access.

| Symptom/reason | Check | Action |
| --- | --- | --- |
| `unknown`, `status_unavailable` | Is the new binary installed? Is the system job running? | An old daemon does not publish the new status schema. Install the independent recovery menu first, then update system and companion. Do not label PID-only detection as protected. |
| `status_or_pf_audit_expired` | Current PID, boot and recent `pf_unverified`/restart events | Run root doctor. A stale snapshot cannot prove either allowed or blocked PF; do not assume the menu color alone proves protection. |
| `stopped` | `launchctl print system/io.github.surge-guard` | Start the installed service; inspect startup errors if it exits. |
| `unlocked` | `manual_unlock` event from this boot | This is intentional temporary removal. `start` or reboot re-arms; `uninstall` is permanent removal. |
| `configuration_invalid` | Validate the intended local policy | Correct the local draft and use `sudo ... configure FILE`. No enhanced-only fallback occurs on damaged installed settings. |
| `rule_probe_pending` | Is a console user logged in? | Wait for the user session and first bounded query. No external HTTP health request is required. |
| `rule_probe_failed` | Error and duration; `surge-cli status`, `surge-cli rule explain URL` as the user | Confirm CLI availability/version and user-session access. Do not run a user-owned CLI as root. Persistent identical errors are not logged every timer tick. |
| `rule_probe_expired` | Are queries slow/hung? | Results older than three seconds from query start cannot open the gate. Check CLI latency and reduce unnecessary checks. |
| `outbound_mode_is_direct/proxy` | `surge-cli mode` | Routes mode requires Rule mode. Change it deliberately in Surge, then recheck. |
| `route_policy_mismatch` | `route_decision_changed` event; expected/actual group and final node | Correct Surge's rule/group choice or explicitly update the local allowlist. A similarly named node is not automatically allowed. |
| `pf_unverified` | Root doctor, first-anchor ordering, competing PF users | Resolve the reported PF error. Protection is unknown when PF cannot be programmed. Never flush all PF rules/state as a shortcut. |
| Enhanced mode unavailable | Signature/extension/VIF/default-route/IPv6 fields | Start Enhanced Mode, inspect competing VPNs/routes and rerun the condition probe. |
| Menu has two Surge sections | Existing combined plugin and standalone plugin | Use `install-user.sh --menu-only`, remove the standalone copy and call the renderer once from the combined menu. |

## SurgeGate

```sh
"$HOME/Library/Application Support/SurgeGuard/bin/surge-gate" status --json
"$HOME/Library/Application Support/SurgeGuard/bin/surge-gate" logs
```

- `waiting`: the system guard has not recently verified `allowed`. Inspect its
  reasons first. A local proxy port being open is not a substitute.
- `restoring`: some app launches remain pending. `application_restore_failed`
  identifies the bundle ID; absent apps remain pending rather than being lost.
- `ready`: initial restoration is complete. This is not a separate PF claim.
- `error`: inspect the event and configuration. A corrupt session/config is not
  silently discarded. The service retries configuration errors.
- `shutting_down`: a normal OS shutdown request is being processed; wait for
  app prompts. After shutdown is accepted, snapshots pause so an empty desktop
  cannot overwrite the saved session.
- `shutdown_aborted`: no force-kill is performed. The saved session is retained
  and snapshots pause. Resolve the app/PF/permission error; restart SurgeGate to
  resume normal restoration. If macOS cancels an already accepted shutdown,
  restart SurgeGate to resume as well.
- `migration_app_unresolved`: inspect the retained legacy file and replace the
  display name with a valid Bundle ID in the new local config. Finder/Surge are
  always excluded from ordinary recovery.

Do not run ordered-shutdown tests on an unsaved working session. Unit tests do
not send app quit events or request OS shutdown.

## Diagnostics and public issues

Share a small sanitized summary: component version, macOS/Surge versions,
configuration mode, state, reason/event codes and which acceptance scenario
failed. Remove personal URLs, group/node names, app lists, paths and raw logs.
The policy/status files are locally readable and must not contain credentials.

## Recovery

SwiftBar → **恢复与备份（离线可用）** is the first recovery path. It offers a
normal restart with bounded result checks, start/re-arm, trusted backup/rollback,
previous-policy restore and an independent emergency remove-block action.
Legacy guards support restart/start/emergency removal before upgrading; backup
commands are clearly marked as requiring the new system version.

If an update reports a lock conflict, do not repeatedly click forced restart.
An observed failure mode was `bootout` returning before the old daemon finished
TERM cleanup: the updater immediately failed on its lock, then the old daemon
left blocked rules with no loaded service. The fixed updater waits on the real
lock, saves a backup, verifies startup and attempts rollback on failure. See
[the incident contract](incidents/update-lock-race.md).

Emergency removal works without executing the installed guard binary. It waits
for the old PID to exit, clears only `io.github.surge-guard`, then verifies the
anchor is empty. Protection is explicitly OFF until Start or next boot. It
refuses to flush if the previous process is still alive. It never toggles Surge,
disables PF globally, or restores a whole old `pf.conf`.

In a local Terminal, `sudo /Library/PrivilegedHelperTools/surge-guard unlock`
stops the system service and removes only this gate. Keep the command available
offline before applying a new policy. The user service cannot unlock PF.

If the binary is absent, follow README's two-command emergency procedure.
Retained policy/session data is separate from public source; do not restore an
old complete `pf.conf` over subsequent edits made by other services.
