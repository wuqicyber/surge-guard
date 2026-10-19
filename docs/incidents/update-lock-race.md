# Update leaves the old gate blocked and unloaded

Observed on 2026-10-19. An administrator ran the update and ordinary networking
stopped. Repeated attempts to restart the old service eventually recovered it.

The unified log recorded this order:

1. Configuration installed and new user-session query preflight passed.
2. The updater requested `launchctl bootout`, immediately attempted the daemon's
   nonblocking firewall lock and failed because it was still held.
3. About 0.3 seconds later, the old daemon finished TERM cleanup, left blocked
   rules, released its lock and exited. The updater had already returned.
4. Minutes later, the old binary was started and recorded `ALLOWED`.

The failure occurred before binary replacement. It is an implicit lifecycle
assumption and a missing integration test: command completion was treated as
process/lock completion. Preflight only verified the CLI query path; it could
not prevent this handoff failure. The old menu used `kickstart -k`, had no result
verification and lacked independent emergency recovery.

Required contract:

- Install a recovery menu that works offline and independently of the root
  executable before any privileged change.
- Back up the installed version before replacing files. Configuration changes
  retain a separate previous-policy backup.
- Wait for the actual old lock to be released with a bounded deadline; a fixed
  sleep is not evidence. Keep the daemon's normal exclusive lock nonblocking.
- Serialize management operations. Start/restart must wait for fresh verified
  PF status, bind it to the new PID and show blocked/error reasons.
- Update failure attempts to restore the previous files/service and remains an
  error. Never implicitly unlock or report successful upgrade after rollback.
- Emergency removal waits for actual process exit before clearing only this
  guard's anchor. It explicitly removes protection; an old-version rollback can
  also reduce checks and must say so.

Regression checks exercise a real delayed flock release and timeout, recovery
manifest destination restrictions, and the actual offline shell script against
fake system commands. The latter checks both delayed exit and refusal to flush
while the old PID stays alive. No test mutates live PF or restarts the Mac.

Privileged update/automatic rollback and real SwiftBar interaction still need
the live acceptance procedure. Source checks alone do not certify that handoff.

Later recovery review found two shell-level gaps: the independent emergency/log
actions still queried the guard's help before dispatch, and service_pid masked
all launchctl errors as an absent job. A broken/hung binary could hold up the
escape hatch; a failed inspection could skip the PID wait and clear rules while
the owner was unknown. Fake-tool regressions reproduced both gaps before the
fix. Independent actions now skip binary capability probing, and unexpected
query errors or a running job with a missing/invalid PID fail before clearing.
The specific missing-service response still permits offline emergency removal.
