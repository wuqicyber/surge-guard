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
        let task = Process(), outputPipe = Pipe(), errorPipe = Pipe(), inputPipe = Pipe()
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
        try task.run()
        outputPipe.fileHandleForWriting.closeFile()
        errorPipe.fileHandleForWriting.closeFile()
        for (pipe, destination) in [(outputPipe, capture), (errorPipe, errors)] {
            drained.enter()
            DispatchQueue.global().async {
                defer { drained.leave() }
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
            _ = finished.wait(timeout: .now() + 1)
            throw GuardError("\(executable) timed out")
        }
        guard drained.wait(timeout: .now() + 1) == .success, !capture.overflow, !errors.overflow else {
            throw GuardError("\(executable) output exceeded limits")
        }
        return CommandResult(status: task.terminationStatus,
                             output: String(decoding: capture.bytes, as: UTF8.self),
                             diagnostics: String(decoding: errors.bytes, as: UTF8.self))
    }

    @discardableResult
    public static func checked(_ executable: String, _ arguments: [String],
                               input: String? = nil, timeout: TimeInterval = 2) throws -> String {
        let result = try run(executable, arguments, input: input, timeout: timeout)
        guard result.status == 0 else { throw GuardError("\(executable) failed: \(result.combined.trimmingCharacters(in: .whitespacesAndNewlines))") }
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

    public static func trustedSurgeRunning() throws -> Bool {
        let result = try Command.run("/usr/bin/pgrep", ["-x", "Surge"])
        guard result.status == 0 else { return false }
        var requirement: SecRequirement?
        let identity = "anchor apple generic and identifier \"com.nssurge.surge-mac\" and certificate leaf[subject.OU] = \"YCKFLA6N72\""
        guard SecRequirementCreateWithString(identity as CFString, SecCSFlags(rawValue: 0), &requirement) == errSecSuccess,
              let requirement else { return false }
        for value in result.output.split(whereSeparator: { $0.isWhitespace }) {
            guard let pid = Int32(value) else { continue }
            var code: SecCode?
            let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
            if SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(rawValue: 0), &code) == errSecSuccess,
               let code, SecCodeCheckValidity(code, SecCSFlags(rawValue: 0), requirement) == errSecSuccess {
                return true
            }
        }
        return false
    }

    public static func readiness() throws -> Readiness {
        guard let store = SCDynamicStoreCreate(nil, "surge-guard.probe" as CFString, nil, nil) else {
            throw GuardError("Cannot open SystemConfiguration store")
        }
        func dictionary(_ key: String) -> [String: Any] {
            SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any] ?? [:]
        }
        let primary = dictionary("State:/Network/Global/IPv4")
        let service = primary["PrimaryService"] as? String ?? ""
        let interface = primary["PrimaryInterface"] as? String ?? ""
        let vpn = dictionary("Setup:/Network/Service/\(service)/VPN")
        let surgeService = vpn["NEProviderBundleIdentifier"] as? String == "com.nssurge.surge-mac.ne"
        let connection = surgeService ? SCNetworkConnectionCreateWithServiceID(nil, service as CFString, nil, nil) : nil
        let connected = connection.map { SCNetworkConnectionGetStatus($0) == .connected } ?? false
        let vifUp = interface.hasPrefix("utun") && addresses().contains {
            $0.name == interface && $0.up && $0.address == "198.18.0.1"
        }
        let route = try Command.checked("/sbin/route", ["-n", "get", "default"])
        return Readiness(trustedProcess: try trustedSurgeRunning(), surgeService: surgeService,
                         connected: connected, vifUp: vifUp,
                         ownsDefaultRoute: !interface.isEmpty && Policy.defaultInterface(route) == interface)
    }
}
