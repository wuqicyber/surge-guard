import Foundation

/// Configure on the main queue; exit records are delivered there without waiting on it.
public final class GateChildExitObserver {
    private let launchID: UUID
    private var child: SurgeProcess?
    private var startupVerified = false

    public init(launchID: UUID) { self.launchID = launchID }

    public func recordIdentity(_ identity: SurgeProcess?) {
        dispatchPrecondition(condition: .onQueue(.main))
        child = identity
    }

    public func verifiedStartup(matching identity: SurgeProcess) {
        dispatchPrecondition(condition: .onQueue(.main))
        if child == identity { startupVerified = true }
    }

    public func attach(to process: Process, onExit: @escaping ([String: Any]) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        // Attach before run(), including children that fail before identity can be read.
        process.terminationHandler = { [self] task in
            let pid = task.processIdentifier
            let status = task.terminationStatus
            let reason = task.terminationReason
            let observedAt = Date(), observedUptime = SystemClock.seconds
            DispatchQueue.main.async { [self] in
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                var details: [String: Any] = [
                    "launch_id": launchID.uuidString, "child_pid": pid,
                    "startup_verified": startupVerified, "termination_status": status,
                    "exit_observed_at": formatter.string(from: observedAt),
                    "exit_observed_uptime": observedUptime,
                    "termination_sender": "unknown", "birth_time_available": false
                ]
                if let child, child.pid == pid {
                    details["birth_time_available"] = true
                    details["child_started_seconds"] = child.startedSeconds
                    details["child_started_microseconds"] = child.startedMicroseconds
                }
                switch reason {
                case .exit:
                    details["termination_reason"] = "exit"
                    details["exit_code"] = status
                case .uncaughtSignal:
                    details["termination_reason"] = "uncaught_signal"
                    details["signal"] = status
                @unknown default:
                    details["termination_reason"] = "unknown"
                }
                onExit(details)
            }
        }
    }
}
