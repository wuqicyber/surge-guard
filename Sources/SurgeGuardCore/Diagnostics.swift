import Foundation
import Darwin

public enum SystemClock {
    public static var seconds: Double {
        var scale = mach_timebase_info_data_t()
        mach_timebase_info(&scale)
        return Double(mach_continuous_time()) * Double(scale.numer) / Double(scale.denom) / 1_000_000_000
    }

    public static var bootID: String {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else { return "" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { return "" }
        return String(cString: bytes)
    }
}

public struct GuardSnapshot: Codable {
    public var version = 1
    public var bootId: String
    public var runId: String
    public var pid: Int32
    public var checkedAt: Date
    public var checkedUptime: Double
    public var firewallVerifiedUptime: Double
    public var allowed: Bool
    public var configurationMode: String
    public var readiness: Readiness?
    public var session: SessionObservation?
    public var reasons: [String]
    public var enforcement = "surge_readiness_gate"

    public init(runId: String, firewallVerifiedUptime: Double, allowed: Bool, configurationMode: String,
                readiness: Readiness?, session: SessionObservation?, reasons: [String]) {
        bootId = SystemClock.bootID
        self.runId = runId
        pid = getpid()
        checkedAt = Date()
        checkedUptime = SystemClock.seconds
        self.firewallVerifiedUptime = firewallVerifiedUptime
        self.allowed = allowed
        self.configurationMode = configurationMode
        self.readiness = readiness
        self.session = session
        self.reasons = reasons
    }

    public func fresh(boot: String = SystemClock.bootID, now: Double = SystemClock.seconds) -> Bool {
        !boot.isEmpty && version == 1 && bootId == boot && checkedUptime <= now && now - checkedUptime < 8 &&
            firewallVerifiedUptime <= now && now - firewallVerifiedUptime < 8
    }
}

public struct StatusReport: Codable {
    public var state: String
    public var daemonRunning: Bool
    public var snapshot: GuardSnapshot?
    public var reason: String

    public static func read() -> StatusReport {
        let service = try? Command.run("/bin/launchctl", ["print", "system/" + Paths.label])
        let serviceRunning = service?.status == 0 && service?.output.contains("state = running") == true
        do {
            try RootFiles.verify(Paths.publicState, directory: true)
            try RootFiles.verify(Paths.snapshot)
            let snapshot = try JSON.decode(GuardSnapshot.self, from: Data(contentsOf: URL(fileURLWithPath: Paths.snapshot)))
            let running = serviceRunning && service?.output.split(separator: "\n").contains {
                $0.trimmingCharacters(in: .whitespaces) == "pid = \(snapshot.pid)"
            } == true
            guard running else { return StatusReport(state: "stopped", daemonRunning: false, snapshot: snapshot, reason: "daemon_not_running") }
            guard snapshot.fresh() else {
                return StatusReport(state: "unknown", daemonRunning: true, snapshot: snapshot, reason: "status_or_pf_audit_expired")
            }
            return StatusReport(state: snapshot.allowed ? "allowed" : "blocked", daemonRunning: true,
                                snapshot: snapshot, reason: snapshot.reasons.joined(separator: "; "))
        } catch {
            if !serviceRunning, let marker = try? readUnlockMarker(), marker == SystemClock.bootID, !marker.isEmpty {
                return StatusReport(state: "unlocked", daemonRunning: false, snapshot: nil, reason: "manual_unlock_until_start_or_reboot")
            }
            return StatusReport(state: "unknown", daemonRunning: serviceRunning, snapshot: nil, reason: "status_unavailable: \(error)")
        }
    }

    private static func readUnlockMarker() throws -> String {
        try RootFiles.verify(Paths.publicState, directory: true)
        try RootFiles.verify(Paths.unlockMarker)
        let data = try Data(contentsOf: URL(fileURLWithPath: Paths.unlockMarker))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: String]
        return object?["boot_id"] ?? ""
    }
}

public enum EventLog {
    public static func write(_ event: String, level: String = "info", message: String, details: [String: Any] = [:]) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let record: [String: Any] = ["time": timestamp, "level": level, "event": event,
                                     "pid": getpid(), "boot_id": SystemClock.bootID, "message": message, "details": details]
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        let line = String(decoding: data, as: UTF8.self) + "\n"
        NSLog("surge-guard: %@", line)
        guard geteuid() == 0 else { return }
        do {
            try RootFiles.prepareRuntime()
            let lock = open(Paths.runtime + "/events.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard lock >= 0 else { throw GuardError("Cannot open event log lock") }
            defer { close(lock) }
            guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw GuardError("Event log busy; unified log retained this event") }
            if FileManager.default.fileExists(atPath: Paths.eventsLog) {
                try RootFiles.verify(Paths.eventsLog)
                if (try FileManager.default.attributesOfItem(atPath: Paths.eventsLog)[.size] as? NSNumber)?.intValue ?? 0 >= 1_048_576 {
                    let rotated = Paths.eventsLog + ".1"
                    if FileManager.default.fileExists(atPath: rotated) {
                        try RootFiles.verify(rotated)
                        try FileManager.default.removeItem(atPath: rotated)
                    }
                    try FileManager.default.moveItem(atPath: Paths.eventsLog, toPath: rotated)
                }
            }
            let fd = open(Paths.eventsLog, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw GuardError("Cannot open event log") }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == 0, info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0 else {
                try handle.close()
                throw GuardError("Unsafe event log permissions")
            }
            try handle.write(contentsOf: Data(line.utf8))
            try handle.close()
        } catch { NSLog("surge-guard: LOGGING ERROR: %@", String(describing: error)) }
    }
}
