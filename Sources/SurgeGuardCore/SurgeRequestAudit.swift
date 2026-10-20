import Foundation
import Darwin

public struct SurgeAuditRequest: Codable, Equatable {
    public var id: String
    public var startDate: Double
    public var pid: Int32?
    public var processPath: String?
    public var sourceAddress: String?
    public var sourcePort: Int?
    public var localAddress: String?
    public var remoteAddress: String?
    public var remoteHost: String?
    public var policyName: String?
    public var originalPolicyName: String?
    public var completed: Bool?
    public var failed: Bool?
    public var rejected: Bool?
    public var inBytes: UInt64?
    public var outBytes: UInt64?
    public var takeoverMode: Int?

    public var stateKey: String {
        var state = self
        state.inBytes = nil; state.outBytes = nil
        return (try? JSON.encode(state)) ?? "invalid"
    }

    public init(_ row: [String: Any]) throws {
        if let identifier = row["id"] as? String, !identifier.isEmpty { id = identifier }
        else if let identifier = row["id"] as? NSNumber { id = identifier.stringValue }
        else { throw GuardError("Surge request has no usable ID") }
        guard let started = row["startDate"] as? Double, started.isFinite, started > 0 else {
            throw GuardError("Surge request has no usable start time")
        }
        startDate = started
        pid = row["pid"] as? Int32; processPath = row["processPath"] as? String
        sourceAddress = row["sourceAddress"] as? String; sourcePort = row["sourcePort"] as? Int
        localAddress = row["localAddress"] as? String; remoteAddress = row["remoteAddress"] as? String
        remoteHost = row["remoteHost"] as? String; policyName = row["policyName"] as? String
        originalPolicyName = row["originalPolicyName"] as? String
        completed = row["completed"] as? Bool; failed = row["failed"] as? Bool; rejected = row["rejected"] as? Bool
        inBytes = row["inBytes"] as? UInt64; outBytes = row["outBytes"] as? UInt64; takeoverMode = row["takeoverMode"] as? Int
    }
}

public struct SurgeRequestAuditBatch: Codable {
    public var surgePid: Int32
    public var queryStartedUptime: Double
    public var queryCompletedUptime: Double
    public var activeRequests: [SurgeAuditRequest]
    public var recentRequests: [SurgeAuditRequest]

    public static func parse(_ data: Data, surgePid: Int32, started: Double, completed: Double) throws -> Self {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let active = object["active-requests"] as? [[String: Any]],
              let recent = object["recent-requests"] as? [[String: Any]], active.count + recent.count <= 4096 else {
            throw GuardError("Surge request snapshot is malformed or exceeds audit limits")
        }
        return Self(surgePid: surgePid, queryStartedUptime: started, queryCompletedUptime: completed,
                    activeRequests: try active.map(SurgeAuditRequest.init), recentRequests: try recent.map(SurgeAuditRequest.init))
    }

    public static func collect() throws -> Self {
        guard geteuid() != 0, getuid() == (try Probe.consoleUID()), let pid = try Probe.trustedSurgePID() else {
            throw GuardError("Surge request audit requires the console user and verified Surge process")
        }
        let started = SystemClock.seconds
        let response = try Command.checked(Probe.surgeCLI, ["--raw", "dump", "request"], timeout: 2)
        guard try Probe.trustedSurgePID() == pid else { throw GuardError("Surge process changed during request audit") }
        return try parse(Data(response.utf8), surgePid: pid, started: started, completed: SystemClock.seconds)
    }
}

public struct SurgeRequestAuditHistory {
    private var previous: [String: String] = [:]
    private var previousRecent = Set<String>()
    private var surgePid: Int32?
    public private(set) var recentWindowOverlap = "initial_or_empty"
    public init() {}

    public mutating func changes(_ batch: SurgeRequestAuditBatch) -> [SurgeAuditRequest] {
        let recent = Set(batch.recentRequests.map(\.id))
        if surgePid != nil, surgePid != batch.surgePid { recentWindowOverlap = "surge_process_changed" }
        else if !recent.isEmpty, !previousRecent.isEmpty {
            recentWindowOverlap = recent.isDisjoint(with: previousRecent) ? "missing; possible_request_history_gap" : "present; not_a_completeness_proof"
        } else { recentWindowOverlap = "initial_or_empty" }
        if surgePid != batch.surgePid { previous = [:] }
        surgePid = batch.surgePid; previousRecent = recent
        let requests = Dictionary((batch.activeRequests + batch.recentRequests).map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let changed = requests.values.filter { previous[$0.id] != $0.stateKey }.sorted { $0.startDate < $1.startDate }
        previous = requests.mapValues(\.stateKey)
        return changed
    }
}
