import Foundation
import Darwin
import Security
import SystemConfiguration

public struct CommandResult {
    public let status: Int32
    public let output: String
    public let diagnostics: String
    public var combined: String { output + diagnostics }
}

public enum Command {
    // Fixed system tools only in privileged paths; no shell interpolation.
    // Drain output concurrently so a full pipe cannot deadlock the timeout.
    public static func run(_ executable: String, _ arguments: [String],
                           input: String? = nil, timeout: TimeInterval = 2) throws -> CommandResult {
        guard (input?.utf8.count ?? 0) < 16_384 else { throw GuardError("Command input is too large") }
        let invocation = ([executable] + arguments).joined(separator: " ")
        let task = Process(), outputPipe = Pipe(), errorPipe = Pipe(), inputPipe = Pipe()
        // Close unused stdin pipes too; long-running callers cannot rely on autorelease.
        defer {
            try? inputPipe.fileHandleForReading.close()
            try? inputPipe.fileHandleForWriting.close()
            try? outputPipe.fileHandleForWriting.close()
            try? errorPipe.fileHandleForWriting.close()
        }
        let finished = DispatchSemaphore(value: 0), drained = DispatchGroup()
        final class Capture: @unchecked Sendable { var bytes = Data(); var overflow = false }
        let capture = Capture(), errors = Capture()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "LANG": "C"]
        task.standardOutput = outputPipe
        task.standardError = errorPipe
        task.standardInput = input == nil ? FileHandle.nullDevice : inputPipe.fileHandleForReading
        task.terminationHandler = { _ in finished.signal() }
        do { try task.run() }
        catch {
            try? outputPipe.fileHandleForReading.close()
            try? errorPipe.fileHandleForReading.close()
            throw error
        }
        outputPipe.fileHandleForWriting.closeFile()
        errorPipe.fileHandleForWriting.closeFile()
        for (pipe, destination) in [(outputPipe, capture), (errorPipe, errors)] {
            drained.enter()
            DispatchQueue.global().async {
                defer { try? pipe.fileHandleForReading.close(); drained.leave() }
                while true {
                    let data = pipe.fileHandleForReading.availableData
                    if data.isEmpty { break }
                    if destination.bytes.count + data.count <= 1_048_576 { destination.bytes.append(data) }
                    else { destination.overflow = true }
                }
            }
        }
        if let input {
            do {
                try inputPipe.fileHandleForWriting.write(contentsOf: Data(input.utf8))
                try inputPipe.fileHandleForWriting.close()
            } catch {
                kill(task.processIdentifier, SIGKILL)
                throw GuardError("Cannot write command input: \(error)")
            }
        }
        if finished.wait(timeout: .now() + timeout) != .success {
            kill(task.processIdentifier, SIGKILL)
            guard finished.wait(timeout: .now() + 1) == .success else {
                throw GuardError("\(invocation) timed out after \(timeout)s and did not terminate")
            }
            throw GuardError("\(invocation) timed out after \(timeout)s")
        }
        guard drained.wait(timeout: .now() + 1) == .success, !capture.overflow, !errors.overflow else {
            throw GuardError("\(invocation) output exceeded limits")
        }
        return CommandResult(status: task.terminationStatus,
                             output: String(decoding: capture.bytes, as: UTF8.self),
                             diagnostics: String(decoding: errors.bytes, as: UTF8.self))
    }

    @discardableResult
    public static func checked(_ executable: String, _ arguments: [String],
                               input: String? = nil, timeout: TimeInterval = 2) throws -> String {
        let result = try run(executable, arguments, input: input, timeout: timeout)
        let invocation = ([executable] + arguments).joined(separator: " ")
        guard result.status == 0 else { throw GuardError("\(invocation) failed: \(result.combined.trimmingCharacters(in: .whitespacesAndNewlines))") }
        return result.output
    }
}

public struct InterfaceAddress {
    public let name: String
    public let address: String
    public let up: Bool
    public let loopback: Bool
}

public enum Probe {
    public static let surgeCLI = "/Applications/Surge.app/Contents/Applications/surge-cli"

    public static func consoleUID() throws -> uid_t {
        var uid: uid_t = 0
        guard SCDynamicStoreCopyConsoleUser(nil, &uid, nil) != nil, uid >= 501 else {
            throw GuardError("No interactive user session; waiting for login")
        }
        return uid
    }

    public static func dropPrivileges(to uid: uid_t) throws {
        guard geteuid() == 0, uid == (try consoleUID()), let account = getpwuid(uid) else {
            throw GuardError("Cannot resolve the console user for privilege drop")
        }
        let name = String(cString: account.pointee.pw_name)
        let gid = account.pointee.pw_gid
        guard initgroups(name, Int32(gid)) == 0,
              setgid(gid) == 0, setuid(uid) == 0,
              getuid() == uid, geteuid() == uid else {
            throw GuardError("Cannot enter the console user's unprivileged session")
        }
    }

    public static func session(configuration: Configuration) throws -> SessionObservation {
        guard geteuid() != 0, getuid() == (try consoleUID()) else {
            throw GuardError("Surge CLI queries must run as the console user")
        }
        let status = try Command.checked(surgeCLI, ["--raw", "status"])
        guard let object = try JSONSerialization.jsonObject(with: Data(status.utf8)) as? [String: Any],
              let mode = object["mode"] as? String,
              let features = object["features"] as? [String: Any],
              let enhanced = features["enhanced-mode"] as? Bool else {
            throw GuardError("Surge returned incomplete mode/feature status")
        }
        var routes: [RouteResult] = []
        for check in configuration.routeChecks {
            // shortcut: URL default context only; add request overrides when gating process/protocol-specific rules.
            let response = try Command.checked(surgeCLI, ["--raw", "rule", "explain", check.url])
            routes.append(try RouteResult.evaluate(Data(response.utf8), check: check))
        }
        return SessionObservation(policyFingerprint: try configuration.fingerprint(), mode: mode, enhancedMode: enhanced, routes: routes)
    }

    public static func privilegedSession(configuration: Configuration, helperPath: String = Paths.binary) throws -> SessionObservation {
        let uid = try consoleUID()
        try RootFiles.verify(helperPath)
        // Enter the user's bootstrap namespace, then drop UID/GID inside our
        // root-owned helper before executing any user-owned Surge code.
        let response = try Command.checked("/bin/launchctl", ["asuser", String(uid), helperPath, "session-probe", String(uid)],
                                           timeout: Double(configuration.routeChecks.count + 1) * 3 + 3)
        guard uid == (try consoleUID()) else { throw GuardError("Console user changed during rule probe") }
        let observation = try JSON.decode(SessionObservation.self, from: Data(response.utf8))
        guard observation.policyFingerprint == (try configuration.fingerprint()) else {
            throw GuardError("Policy changed during query; run candidate --config checks as the normal user")
        }
        return observation
    }

    public static func addresses() -> [InterfaceAddress] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { freeifaddrs(first) }
        var result: [InterfaceAddress] = []
        var current = first
        while let item = current {
            defer { current = item.pointee.ifa_next }
            let info = item.pointee
            guard let address = info.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) || address.pointee.sa_family == UInt8(AF_INET6) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host,
                              socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            result.append(InterfaceAddress(name: String(cString: info.ifa_name),
                                           address: String(cString: host).components(separatedBy: "%")[0],
                                           up: info.ifa_flags & UInt32(IFF_UP) != 0,
                                           loopback: info.ifa_flags & UInt32(IFF_LOOPBACK) != 0))
        }
        return result
    }

    public static func trustedSurgePID() throws -> pid_t? {
        let result = try Command.run("/usr/bin/pgrep", ["-x", "Surge"])
        guard result.status == 0 else { return nil }
        var requirement: SecRequirement?
        let identity = "anchor apple generic and identifier \"com.nssurge.surge-mac\" and certificate leaf[subject.OU] = \"YCKFLA6N72\""
        guard SecRequirementCreateWithString(identity as CFString, SecCSFlags(rawValue: 0), &requirement) == errSecSuccess,
              let requirement else { return nil }
        for value in result.output.split(whereSeparator: { $0.isWhitespace }) {
            guard let pid = Int32(value) else { continue }
            var code: SecCode?
            let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
            if SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(rawValue: 0), &code) == errSecSuccess,
               let code, SecCodeCheckValidity(code, SecCSFlags(rawValue: 0), requirement) == errSecSuccess {
                return pid
            }
        }
        return nil
    }

    public static func trustedSurgeRunning() throws -> Bool {
        try trustedSurgePID() != nil
    }

    public static func isSurgeService(_ service: String, store: SCDynamicStore) -> Bool {
        guard !service.isEmpty,
              let vpn = SCDynamicStoreCopyValue(store, "Setup:/Network/Service/\(service)/VPN" as CFString) as? [String: Any] else { return false }
        return vpn["NEProviderBundleIdentifier"] as? String == "com.nssurge.surge-mac.ne"
    }

    public static func connectionLossReason(_ status: SCNetworkConnectionStatus) -> String? {
        switch status {
        case .connected: return nil
        case .disconnecting: return "surge_tunnel_disconnecting"
        case .disconnected: return "surge_tunnel_disconnected"
        case .connecting: return "surge_tunnel_connecting"
        default: return "surge_tunnel_status_unknown"
        }
    }

    public static func readiness(trustedProcess: Bool? = nil) throws -> Readiness {
        guard let store = SCDynamicStoreCreate(nil, "surge-guard.probe" as CFString, nil, nil) else {
            throw GuardError("Cannot open SystemConfiguration store")
        }
        func dictionary(_ key: String) -> [String: Any] {
            SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any] ?? [:]
        }
        let primary = dictionary("State:/Network/Global/IPv4")
        let globalIPv6 = dictionary("State:/Network/Global/IPv6")
        let service = primary["PrimaryService"] as? String ?? ""
        let interface = primary["PrimaryInterface"] as? String ?? ""
        let ipv6Interface = globalIPv6.isEmpty ? nil :
            (globalIPv6["PrimaryInterface"] as? String ?? "")
        let surgeService = isSurgeService(service, store: store)
        let connection = surgeService ? SCNetworkConnectionCreateWithServiceID(nil, service as CFString, nil, nil) : nil
        let connected = connection.map { SCNetworkConnectionGetStatus($0) == .connected } ?? false
        let vifUp = interface.hasPrefix("utun") && addresses().contains {
            $0.name == interface && $0.up && $0.address == "198.18.0.1"
        }
        let route = try Command.checked("/sbin/route", ["-n", "get", "default"])
        return Readiness(trustedProcess: try trustedProcess ?? trustedSurgeRunning(), surgeService: surgeService,
                         connected: connected, vifUp: vifUp,
                         ownsDefaultRoute: !interface.isEmpty && Policy.defaultInterface(route) == interface,
                         ipv6Safe: Policy.ipv6Safe(primaryInterface: ipv6Interface, surgeInterface: interface))
    }
}
