# Initial verification record — 2026-09-08

Environment: macOS 15.7.7, Apple Silicon, Swift 6.0.3, Surge Mac 6.9.1.

Completed without root privileges or changing networking:

- `swift run surge-guard-tests`: all eight groups passed, including 32 readiness combinations, PF configuration round trip/tamper rejection, live-output attachment ordering, route parsing, native PF syntax, command timeout/backpressure and literal argument handling.
- `swift build -c release --product surge-guard`: passed.
- Release executable `check`: all five readiness conditions true with Surge Enhanced Mode active.
- Release executable `rules`: printed parseable PF policy.
- Build and live-readiness checks do not read a Surge profile or collect node credentials.

Not performed:

- Installing/enabling the root LaunchDaemon.
- Applying blocking PF rules or checking real packet counters.
- Quit/force-quit, Enhanced Mode toggle, concurrent VPN, existing TCP/UDP, IPv6 transport, sleep/wake or reboot acceptance.
- Recovery and uninstall on an installed system.

The development session had no non-interactive administrator access. No protection claim is made for the unperformed tests. The code is published as experimental; complete [acceptance.md](acceptance.md) on a target Mac before relying on it.
