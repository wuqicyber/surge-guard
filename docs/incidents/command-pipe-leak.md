# Companion waits although the system guard is allowed

Observed on 2026-10-19: SurgeGate stayed in `waiting` with the old reason
`stopped: daemon_not_running`, while an independent status read showed a fresh
allowed snapshot and the unchanged running system daemon. This is a companion
observation failure, not evidence that the guard stopped or networking failed.

The companion held 2,559 numeric file descriptors, mostly pipe ends. A focused
regression reproduced two leaked descriptors per local command: 40 calls grew
the count from 25 to 105. Command created an stdin pipe even without input and
left its two ends to deferred Foundation cleanup. Long-running callers could
not rely on that lifetime. StatusReport also discarded command errors with
`try?`, mapping inability to query launchd into a stopped-daemon report.

The shared runner now closes unused stdin ends explicitly, closes output
readers after draining and cleans up failed launches. Both the guard and
companion use this code. Query launch/timeout/non-service errors become
`unknown: service_query_failed`; only a successful service inspection or the
specific launchctl missing-service result establishes absence. PID binding and
snapshot freshness still apply. Unknown pauses application restoration and
has a distinct menu label and warning event.

Regression coverage checks descriptor counts over repeated success, input,
failed launch and timeout calls. Separate cases cover a running/mismatched PID,
an absent service and an unsuccessful query. Before this fix, ordinary CLI and
short unit checks passed because each process soon exited; repeated calls were
the missing test. Do not replace this regression with a test that wraps every
call in an autorelease pool and hides missing explicit cleanup.

The user service was backed up and updated. It resumed reading allowed status,
recognized already-running applications and returned to ready. This does not
substitute for a long-duration run or a system-binary upgrade. Verify deployment
and performed observations in [the verification record](../verification.md).
