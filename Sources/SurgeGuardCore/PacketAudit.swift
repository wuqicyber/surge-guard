import Foundation
import Darwin
import CPcap

public enum PacketAudit {
    public static let label = Paths.label + ".audit"
    public static let binary = Paths.binary + "-audit"
    public static let plist = "/Library/LaunchDaemons/" + label + ".plist"
    public static let directory = Paths.runtime + "/packet-audit"
    public static let configuration = directory + "/configuration.json"
    public static let snapshot = Paths.publicState + "/audit-status.json"
    public static let events = directory + "/events.log"
    public static let requests = directory + "/requests.log"
    public static let requestSnapshot = directory + "/requests-snapshot.json"
    public static let fileNames = (0..<8).map { "traffic.pcapng\($0)" }

    public static func joinParentProcessGroup() throws {
        let parent = getppid(), group = getpgid(parent)
        guard parent > 1, group > 0, setpgid(0, group) == 0 else {
            throw GuardError("Cannot join audit supervisor process group")
        }
    }

    public static func arguments(megabytes: Int) throws -> [String] {
        guard [256, 1024, 4096].contains(megabytes) else { throw GuardError("Audit capacity must be 256, 1024 or 4096 MB") }
        return ["-i", "pktap,all", "-p", "-n", "-U", "-B", "512", "-Z", "root", "-s", "256",
                "-C", String(megabytes / 8), "-W", "8", "-w", directory + "/traffic.pcapng"]
    }

    public static func prepare() throws {
        try RootFiles.prepareRuntime()
        if !FileManager.default.fileExists(atPath: directory) {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        }
        try RootFiles.verify(directory, directory: true)
        var info = stat()
        guard lstat(directory, &info) == 0, info.st_mode & 0o077 == 0 else { throw GuardError("Audit directory must be private") }
        for name in fileNames {
            let path = directory + "/" + name
            if lstat(path, &info) != 0 {
                guard errno == ENOENT else { throw GuardError("Cannot inspect capture file") }
                continue
            }
            try RootFiles.verify(path)
            guard lstat(path, &info) == 0, info.st_mode & 0o077 == 0, info.st_nlink == 1 else {
                throw GuardError("Unsafe capture file: \(name)")
            }
        }
    }

    public static func event(_ event: String, message: String, details: [String: Any] = [:], timeZone: String) throws {
        let timestamp = ISO8601DateFormatter()
        timestamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let warning = ["audit_capture_failed", "audit_capture_gap", "audit_capture_drops", "audit_capture_statistics_reset", "audit_surge_unavailable", "audit_surge_history_gap"].contains(event) ||
            details["state"] as? String == "incomplete"
        let record: [String: Any] = ["time": timestamp.string(from: Date()), "display_time_zone": timeZone,
                                     "component": "PacketAudit", "event": event, "level": warning ? "warning" : "info",
                                     "pid": getpid(), "boot_id": SystemClock.bootID, "monotonic_uptime": SystemClock.seconds,
                                     "message": message, "details": details]
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes])
        try EventFile.append(data, to: events, owner: 0, lockPath: directory + "/events.lock")
    }
}

public struct PacketCaptureRange: Codable {
    public var file: String
    public var packets: UInt64 = 0
    public var earliest: Date?
    public var latest: Date?
    public var readError: String?
    public var changedDuringRead = false

    public init(file: String, readError: String? = nil) { self.file = file; self.readError = readError }

    public static func read(_ path: String, owner: uid_t = 0, maximumBytes: Int64) throws -> PacketCaptureRange {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw GuardError("Cannot open capture") }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_uid == owner, before.st_mode & S_IFMT == S_IFREG,
              before.st_mode & 0o077 == 0, before.st_size <= maximumBytes else {
            close(fd); throw GuardError("Unsafe or oversized capture")
        }
        guard let file = fdopen(fd, "rb") else { close(fd); throw GuardError("Cannot read capture") }
        var error = [CChar](repeating: 0, count: Int(PCAP_ERRBUF_SIZE))
        guard let capture = pcap_fopen_offline(file, &error) else {
            fclose(file); throw GuardError("Cannot decode capture: \(String(cString: error))")
        }
        defer { pcap_close(capture) }
        guard pcap_snapshot(capture) > 0, pcap_snapshot(capture) <= 1_048_576 else { throw GuardError("Unsafe capture snapshot length") }
        var result = PacketCaptureRange(file: URL(fileURLWithPath: path).lastPathComponent)
        let divisor: Double = pcap_get_tstamp_precision(capture) == PCAP_TSTAMP_PRECISION_NANO ? 1_000_000_000 : 1_000_000
        let deadline = SystemClock.seconds + 5
        while true {
            var header: UnsafeMutablePointer<pcap_pkthdr>?, packet: UnsafePointer<UInt8>?
            let status = pcap_next_ex(capture, &header, &packet)
            if status == -2 { break }
            guard status == 1, let header else { result.readError = String(cString: pcap_geterr(capture)); break }
            let time = Double(header.pointee.ts.tv_sec) + Double(header.pointee.ts.tv_usec) / divisor
            guard time.isFinite, time >= 0 else { result.readError = "Invalid packet timestamp"; break }
            let date = Date(timeIntervalSince1970: time)
            result.earliest = result.earliest.map { min($0, date) } ?? date
            result.latest = result.latest.map { max($0, date) } ?? date
            result.packets += 1
            if SystemClock.seconds >= deadline { result.readError = "Capture scan timed out; range is partial"; break }
        }
        var after = stat()
        result.changedDuringRead = fstat(fd, &after) != 0 || before.st_size != after.st_size ||
            before.st_mtimespec.tv_sec != after.st_mtimespec.tv_sec || before.st_mtimespec.tv_nsec != after.st_mtimespec.tv_nsec
        return result
    }
}

public struct PacketAuditConfiguration: Codable {
    public var capacityMegabytes = 256
    public var timeZone = TimeZone.current.identifier
    public init() {}

    public func validate() throws {
        _ = try PacketAudit.arguments(megabytes: capacityMegabytes)
        guard TimeZone.knownTimeZoneIdentifiers.contains(timeZone) || ["UTC", "GMT"].contains(timeZone) else {
            throw GuardError("Unknown audit time zone")
        }
    }

    public static func load() throws -> PacketAuditConfiguration {
        try RootFiles.verify(PacketAudit.configuration)
        let value = try JSON.decode(Self.self, from: Data(contentsOf: URL(fileURLWithPath: PacketAudit.configuration)))
        try value.validate()
        return value
    }
}

public struct PacketCaptureCounters: Codable, Equatable {
    public var captured: UInt64
    public var receivedByFilter: UInt64
    public var droppedByKernel: UInt64

    public func follows(_ previous: Self) -> Bool {
        captured >= previous.captured && receivedByFilter >= previous.receivedByFilter && droppedByKernel >= previous.droppedByKernel
    }
}

public struct PacketCaptureStatistics {
    private var captured: UInt64?
    private var received: UInt64?
    public init() {}

    public mutating func consume(_ line: String) -> PacketCaptureCounters? {
        if line.hasPrefix("tcpdump: ") {
            captured = nil; received = nil
            defer { captured = nil; received = nil }
            let fields = line.dropFirst("tcpdump: ".count).split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count == 3 else { return nil }
            for field in fields.prefix(2) {
                _ = consumeField(field.trimmingCharacters(in: .whitespaces))
            }
            return consumeField(fields[2].trimmingCharacters(in: .whitespaces))
        }
        return consumeField(line)
    }

    private mutating func consumeField(_ line: String) -> PacketCaptureCounters? {
        let parts = line.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, let value = UInt64(parts[0]) else { return nil }
        switch String(parts[1]) {
        case "packets captured", "packet captured": captured = value; received = nil
        case "packets received by filter", "packet received by filter": if captured != nil { received = value }
        case "packets dropped by kernel", "packet dropped by kernel":
            defer { captured = nil; received = nil }
            if let captured, let received {
                return PacketCaptureCounters(captured: captured, receivedByFilter: received, droppedByKernel: value)
            }
        default: break
        }
        return nil
    }
}

public struct PacketAuditSnapshot: Codable {
    public var version = 1
    public var bootId = SystemClock.bootID
    public var runId = UUID().uuidString
    public var pid = getpid()
    public var capturePid: Int32?
    public var checkedAt = Date()
    public var checkedUptime = SystemClock.seconds
    public var startedAt = Date()
    public var captureReadyAt: Date?
    public var state = "starting"
    public var reason = "waiting_for_capture"
    public var capacityMegabytes: Int
    public var timeZone = TimeZone.current.identifier
    public var captureBytesPerPacket = 256
    public var source = "pktap,all"
    public var counters: PacketCaptureCounters?
    public var countersUptime: Double?
    public var droppedByInterface: UInt64?
    public var surgeRequestsState = "unavailable"
    public var surgeRequestsUptime: Double?
    public var recentRequestWindowOverlap = "unverified"
    public var surgeHistoryHasGaps = false
    public var captureHistoryHasGaps = false
    public var noBypassVerified = false
    public var packetPathAttribution = "unverified"
    public var retention = "rolling_files; overwritten_history_unavailable; decode_timestamps_for_retained_range"
    public var guardState = "unknown"
    public var guardRunId: String?
    public var guardCheckedUptime: Double?

    public init(capacityMegabytes: Int) { self.capacityMegabytes = capacityMegabytes }

    public var historyDescriptions: [String] {
        ["抓包历史：\(captureHistoryHasGaps ? "有缺口" : "未记录到缺口")",
         "Surge 请求历史：\(surgeHistoryHasGaps ? "有缺口" : "未记录到缺口")"]
    }

    public func fresh(boot: String = SystemClock.bootID, now: Double = SystemClock.seconds) -> Bool {
        guard version == 1, !boot.isEmpty, bootId == boot, checkedUptime <= now, now - checkedUptime < 8 else { return false }
        if state == "capturing" {
            guard capturePid != nil, counters != nil, let measured = countersUptime, measured <= now, now - measured < 10 else { return false }
        }
        return true
    }

    public static func read(service query: CommandResult? = nil) -> PacketAuditSnapshot? {
        guard (try? RootFiles.verify(Paths.publicState, directory: true)) != nil,
              (try? RootFiles.verify(PacketAudit.snapshot)) != nil,
              let data = try? Data(contentsOf: URL(fileURLWithPath: PacketAudit.snapshot)),
              let value = try? JSON.decode(PacketAuditSnapshot.self, from: data), value.fresh(),
              let service = query ?? (try? Command.run("/bin/launchctl", ["print", "system/" + PacketAudit.label])),
              (try? StatusReport.serviceRunning(service, pid: value.pid)) == true else { return nil }
        return value
    }
}

public struct PacketAuditMenu {
    public let title: String
    public let canStop: Bool
    public init(service: CommandResult?, snapshot: PacketAuditSnapshot?) {
        guard let service, let running = try? StatusReport.serviceRunning(service) else {
            title = "🟠 状态未知（采集可能仍在运行）"; canStop = true; return
        }
        guard running else {
            title = "⚪️ 采集服务未运行（残留进程未核验）"; canStop = false; return
        }
        canStop = true
        guard let snapshot, snapshot.fresh(), (try? StatusReport.serviceRunning(service, pid: snapshot.pid)) == true else {
            title = "🟠 服务运行，采集状态待验证"; return
        }
        title = snapshot.state == "capturing" ? "🔵 正在抓包 · 路径未验证" : "🟠 采集不完整 / 异常（服务仍运行）"
    }
}
