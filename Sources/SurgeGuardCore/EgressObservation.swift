import Foundation
import Darwin

public struct EgressFlow: Codable, Equatable {
    public var pid: Int32
    public var process: String
    public var processPath: String?
    public var processKind = "unresolved"
    public var destinationScope: String
    public var interface: String
    public var transport: String
    public var localEndpoint: String
    public var remoteEndpoint: String
    public var sentBytes: UInt64
    public var receivedBytes: UInt64

    public var key: String { "\(pid)|\(interface)|\(transport)|\(localEndpoint)|\(remoteEndpoint)" }

    public var category: String { Self.category(kind: processKind, scope: destinationScope, sent: sentBytes) }
    public static let categories = ["public_send_review", "public_receive_only", "system_extension", "local_or_reserved", "unresolved_peer"]
    public static func category(kind: String, scope: String, sent: UInt64) -> String {
        if kind == "system_extension" { return "system_extension" }
        if scope == "public" { return sent > 0 ? "public_send_review" : "public_receive_only" }
        return scope == "local_or_reserved" ? "local_or_reserved" : "unresolved_peer"
    }
}

public struct EgressObservation: Codable {
    public var sampledAt = Date()
    public var sampleStartedAt: Date?
    public var sampleStartedUptime: Double?
    public var sampleCompletedUptime: Double?
    public var guardStateAtStart: String?
    public var guardStateAtEnd: String?
    public var guardStateDuringSample: String?
    public var guardTrackingStartedUptime: Double?
    public var guardTrackingCompletedUptime: Double?
    public var scope = "sampled_tcp_udp_interface_activity"
    public var sampleSeconds = 1
    public var surgeInterface: String?
    public var unresolvedActiveSockets = 0
    public var unattributedActiveSockets = 0
    public var unmeasuredSockets = 0
    public var flows: [EgressFlow] = []

    public static func collect() throws -> EgressObservation {
        let startedAt = Date(), startedUptime = SystemClock.seconds
        let surgeInterface = Probe.addresses().first { $0.up && $0.address == "198.18.0.1" }?.name
        // The first nettop frame is lifetime totals. Only the second delta frame is evidence of new activity.
        let output = try Command.checked("/usr/bin/nettop", ["-n", "-x", "-d", "-L", "2", "-s", "1",
                                         "-J", "interface,state,bytes_in,bytes_out"], timeout: 5)
        guard surgeInterface == Probe.addresses().first(where: { $0.up && $0.address == "198.18.0.1" })?.name else {
            throw GuardError("Surge interface changed during egress sampling; retry on the next sample")
        }
        var observation = try parse(output, surgeInterface: surgeInterface, surgePID: Probe.trustedSurgePID())
        observation.sampleStartedAt = startedAt
        observation.sampleStartedUptime = startedUptime
        observation.sampleCompletedUptime = SystemClock.seconds
        observation.guardStateDuringSample = "unknown"
        for index in observation.flows.indices {
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            if proc_pidpath(observation.flows[index].pid, &path, UInt32(path.count)) > 0 {
                let executable = String(cString: path)
                observation.flows[index].processPath = executable
                observation.flows[index].processKind = "application_or_service"
                // Classification only: a system extension is not implicitly approved or ignored.
                if executable.hasPrefix("/Library/SystemExtensions/"), executable.contains(".systemextension/Contents/MacOS/"),
                   (try? RootFiles.verify(executable)) != nil {
                    observation.flows[index].processKind = "system_extension"
                }
            }
        }
        return observation
    }

    public static func parse(_ output: String, surgeInterface: String?, surgePID: Int32?) throws -> EgressObservation {
        var result = EgressObservation(surgeInterface: surgeInterface)
        var frame = 0, pid: Int32?, process = "", deltaRows = 0
        var indices: [String: Int] = [:]
        for line in output.split(separator: "\n") {
            let fields = try csv(String(line))
            if fields == ["", "interface", "state", "bytes_in", "bytes_out", ""] {
                frame += 1; pid = nil; process = ""; continue
            }
            guard frame > 0, fields.count == 6, fields.last == "" else { throw GuardError("Unrecognized nettop CSV row") }
            guard frame == 2 else { continue }
            deltaRows += 1
            if !fields[0].contains("<->") {
                guard fields[1].isEmpty, let dot = fields[0].lastIndex(of: "."),
                      let parsed = Int32(fields[0][fields[0].index(after: dot)...]), parsed > 0 else {
                    throw GuardError("Unrecognized nettop process row")
                }
                pid = parsed; process = String(fields[0][..<dot]); continue
            }
            guard let pid else { throw GuardError("Nettop socket has no owning process") }
            guard pid != surgePID, fields[1] != surgeInterface, fields[1] != "lo0" else { continue }
            if fields[3].isEmpty && fields[4].isEmpty {
                if fields[2] != "Listen" { result.unmeasuredSockets += 1 }
                continue
            }
            guard let received = UInt64(fields[3]), let sent = UInt64(fields[4]) else {
                throw GuardError("Unrecognized nettop process or byte counters")
            }
            guard received > 0 || sent > 0 else { continue }
            guard !fields[1].isEmpty else { result.unattributedActiveSockets += 1; continue }
            let socket = fields[0].split(separator: " ", maxSplits: 1)
            guard socket.count == 2, ["tcp4", "tcp6", "udp4", "udp6"].contains(String(socket[0])) else {
                throw GuardError("Unrecognized nettop socket")
            }
            let endpoints = socket[1].components(separatedBy: "<->")
            guard endpoints.count == 2 else { throw GuardError("Unrecognized nettop endpoints") }
            let host = endpointHost(endpoints[1])
            if host == nil { result.unresolvedActiveSockets += 1 }
            let scope = host.map { isPublicAddress($0) ? "public" : "local_or_reserved" } ?? "unresolved"
            let flow = EgressFlow(pid: pid, process: process, destinationScope: scope, interface: fields[1], transport: String(socket[0]),
                                  localEndpoint: endpoints[0], remoteEndpoint: endpoints[1], sentBytes: sent, receivedBytes: received)
            if let index = indices[flow.key] {
                // Reused UDP ports can produce multiple rows with the same visible tuple.
                let received = result.flows[index].receivedBytes.addingReportingOverflow(flow.receivedBytes)
                let sent = result.flows[index].sentBytes.addingReportingOverflow(flow.sentBytes)
                guard !received.overflow, !sent.overflow else { throw GuardError("Nettop byte counters overflowed") }
                result.flows[index].receivedBytes = received.partialValue
                result.flows[index].sentBytes = sent.partialValue
            } else {
                indices[flow.key] = result.flows.count
                result.flows.append(flow)
            }
        }
        guard frame == 2, deltaRows > 0 else { throw GuardError("Nettop did not provide two complete sample frames") }
        result.flows.sort {
            if ($0.destinationScope == "public") != ($1.destinationScope == "public") { return $0.destinationScope == "public" }
            return $0.key < $1.key
        }
        return result
    }

    private static func csv(_ line: String) throws -> [String] {
        var fields: [String] = [], field = "", quoted = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index], next = line.index(after: index)
            if character == "\"" {
                if quoted && next < line.endIndex && line[next] == "\"" { field.append("\""); index = line.index(after: next); continue }
                quoted.toggle()
            } else if character == "," && !quoted { fields.append(field); field = "" }
            else { field.append(character) }
            index = next
        }
        guard !quoted else { throw GuardError("Unterminated nettop CSV field") }
        fields.append(field)
        return fields
    }

    public static func endpointHost(_ endpoint: String) -> String? {
        // nettop uses dot-separated ports for unbracketed IPv6, colon-separated ports for IPv4/bracketed IPv6.
        guard let separator = endpoint.lastIndex(where: { $0 == ":" || $0 == "." }),
              let port = UInt16(endpoint[endpoint.index(after: separator)...]), port > 0 else { return nil }
        var host = String(endpoint[..<separator])
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host == "*" { return nil }
        host = host.components(separatedBy: "%")[0]
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1 ? host : nil
    }

    public static func parseSurgeDomains(dnsData: Data?, vipData: Data?) -> [String: [String]] {
        var sets: [String: Set<String>] = [:]
        func cleanDomain(_ raw: String) -> String? {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.utf8.count <= 255,
                  !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
            return trimmed
        }
        if let dnsData, dnsData.count <= 4_194_304,
           let obj = try? JSONSerialization.jsonObject(with: dnsData) as? [String: Any] {
            for entry in obj["dnsCache"] as? [[String: Any]] ?? [] {
                guard let domain = (entry["domain"] as? String).flatMap(cleanDomain) else { continue }
                for ip in entry["data"] as? [String] ?? [] where !ip.isEmpty {
                    sets[ip, default: []].insert(domain)
                }
            }
            for entry in obj["local"] as? [[String: Any]] ?? [] {
                guard let domain = (entry["domain"] as? String).flatMap(cleanDomain) else { continue }
                if let ip = entry["data"] as? String, !ip.isEmpty {
                    sets[ip, default: []].insert(domain)
                }
            }
        }
        if let vipData, vipData.count <= 4_194_304,
           let obj = try? JSONSerialization.jsonObject(with: vipData) as? [String: Any] {
            for entry in obj["items"] as? [[String: Any]] ?? [] {
                guard let domain = (entry["domain"] as? String).flatMap(cleanDomain),
                      let ip = entry["IP"] as? String, !ip.isEmpty else { continue }
                sets[ip, default: []].insert(domain)
            }
        }
        return sets.mapValues { Array($0.sorted().prefix(5)) }
    }

    public static func surgeDomainMap() -> [String: [String]] {
        guard geteuid() != 0, FileManager.default.isExecutableFile(atPath: Probe.surgeCLI),
              (try? Probe.trustedSurgePID()) != nil else { return [:] }
        let dnsData = (try? Command.checked(Probe.surgeCLI, ["--raw", "dump", "dns"], timeout: 2)).map { Data($0.utf8) }
        let vipData = (try? Command.checked(Probe.surgeCLI, ["--raw", "dump", "virtual-ip-db"], timeout: 2)).map { Data($0.utf8) }
        return parseSurgeDomains(dnsData: dnsData, vipData: vipData)
    }

    public static func isPublicAddress(_ host: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            let b = withUnsafeBytes(of: v4) { Array($0) }
            return !(b[0] == 0 || b[0] == 10 || b[0] == 127 || b[0] >= 224 ||
                     (b[0] == 100 && b[1] & 0xc0 == 64) || (b[0] == 169 && b[1] == 254) ||
                     (b[0] == 172 && b[1] & 0xf0 == 16) || (b[0] == 192 && b[1] == 168) ||
                     (b[0] == 192 && b[1] == 0 && [0, 2].contains(b[2])) ||
                     (b[0] == 198 && b[1] & 0xfe == 18) || (b[0] == 198 && b[1] == 51 && b[2] == 100) ||
                     (b[0] == 203 && b[1] == 0 && b[2] == 113))
        }
        guard inet_pton(AF_INET6, host, &v6) == 1 else { return false }
        let b = withUnsafeBytes(of: v6) { Array($0) }
        if b.prefix(10).allSatisfy({ $0 == 0 }), b[10] == 255, b[11] == 255 {
            return isPublicAddress(b[12...].map(String.init).joined(separator: "."))
        }
        return (b[0] & 0xe0 == 0x20 || Array(b.prefix(12)) == [0, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0]) &&
            Array(b.prefix(4)) != [0x20, 1, 0x0d, 0xb8]
    }
}

public struct EgressHistory {
    private var recorded: [String: Double] = [:]
    public private(set) var deduplicated = 0
    public private(set) var limited = 0
    public init() {}

    public mutating func newActivity(_ flows: [EgressFlow], now: Double, context: String = "unknown") -> [EgressFlow] {
        recorded = recorded.filter { now >= $0.value && now - $0.value < 300 }
        func key(_ flow: EgressFlow) -> String {
            context + "|" + flow.category + "|" + (flow.sentBytes > 0 ? "send|" : "receive|") + flow.key
        }
        let fresh = flows.filter { recorded[key($0)] == nil }.sorted {
            EgressFlow.categories.firstIndex(of: $0.category)! < EgressFlow.categories.firstIndex(of: $1.category)!
        }
        // Bound both retained keys and per-sample log size under connection churn.
        let selected = Array(fresh.prefix(20))
        deduplicated = flows.count - fresh.count
        limited = fresh.count - selected.count
        for flow in selected where recorded.count < 4096 { recorded[key(flow)] = now }
        return selected
    }
}
