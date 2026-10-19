# Intermittent status read permission failure

Observed on 2026-10-19: SurgeGate logged `unknown` with an EACCES read failure for
the public status snapshot, then returned to zero pending apps about a second
later. This establishes a reader failure and recovery, not a network outage.

A four-second read-only observation sampled mostly 0644, one 0600 mode and one
EACCES failure on the actual snapshot. A temporary-file reproduction under umask
077 also observed private modes during concurrent Foundation atomic rewrites,
even though permissions were 0644 after the write returned. Applying chmod after
publication did not prevent that visibility window.

The fixed writer creates a unique sibling file, writes the full content, applies
the final permissions and fsyncs it, then publishes with POSIX rename. Ownership
and parent/target checks remain in RootFiles/UserPaths. Readers see either the
complete previous inode or the complete new inode with final permissions. A
concurrent test checks mode and complete content under restrictive umask; private
state remains 0600. No live PF manipulation is involved in that regression test.

SurgeGate now records unavailable/recovered status separately, treats unknown as
a warning and pauses application restoration. Already-running apps are recorded
as skips rather than false launch successes. Both components share the human
renderer; default output explains state/cause/effect/recovery while JSON retains
original errors, event and process fields. SwiftBar formats privileged fixed-log
reads as the normal user; the root log remains private.

The observed live writer remains vulnerable until the new system executable is
installed. Source regression checks and a user-menu update alone cannot establish
that the running privileged writer has been replaced.
