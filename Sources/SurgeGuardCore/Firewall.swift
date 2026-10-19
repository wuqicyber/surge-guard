import Foundation
import Darwin

public enum Paths {
    public static let label = "io.github.surge-guard"
    public static let binary = "/Library/PrivilegedHelperTools/surge-guard"
    public static let plist = "/Library/LaunchDaemons/\(label).plist"
    public static let runtime = "/private/var/db/surge-guard"
    public static let eventsLog = runtime + "/events.log"
    public static let pfConfig = "/private/etc/pf.conf"
    public static let publicState = "/Library/Application Support/SurgeGuard"
    public static let configuration = publicState + "/policy.json"
    public static let snapshot = publicState + "/status.json"
    public static let unlockMarker = publicState + "/unlocked.json"
    public static let backups = runtime + "/backups"
}

public enum RootFiles {
    public static func preparePublicState() throws {
        try verify("/Library/Application Support", directory: true)
        if !FileManager.default.fileExists(atPath: Paths.publicState) {
            try FileManager.default.createDirectory(atPath: Paths.publicState, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o755])
        }
        try verify(Paths.publicState, directory: true)
    }
    public static func verify(_ path: String, directory: Bool = false) throws {
        var info = stat()
        guard lstat(path, &info) == 0,
              info.st_uid == 0, info.st_mode & 0o022 == 0,
              info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG) else {
            throw GuardError("Expected a root-owned, non-writable-by-others \(directory ? "directory" : "file"): \(path)")
        }
    }

    public static func write(_ value: String, to path: String, mode: mode_t = 0o600) throws {
        // The parent is root-owned, so atomic replacement cannot be redirected
        // by an unprivileged process. Existing symlinks are always refused.
        try verify(URL(fileURLWithPath: path).deletingLastPathComponent().path, directory: true)
        if FileManager.default.fileExists(atPath: path) { try verify(path) }
        var info = stat()
        if lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFLNK {
            throw GuardError("Refusing symbolic link: \(path)")
        }
        try AtomicFile.write(value, to: path, mode: mode)
    }

    public static func prepareRuntime() throws {
        // macOS /var/run can be group-writable by daemon. Use a root-only
        // parent; persisted PF tokens are checked against live references.
        try verify(URL(fileURLWithPath: Paths.runtime).deletingLastPathComponent().path, directory: true)
        if !FileManager.default.fileExists(atPath: Paths.runtime) {
            try FileManager.default.createDirectory(atPath: Paths.runtime, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        }
        try verify(Paths.runtime, directory: true)
    }
}

public final class RuntimeLock {
    private let descriptor: Int32
    public init(timeout: TimeInterval = 0, management: Bool = false) throws {
        try RootFiles.prepareRuntime()
        descriptor = open(Paths.runtime + (management ? "/management.lock" : "/lock"), O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw GuardError("Cannot open service lock") }
        do { try Self.acquire(descriptor, timeout: timeout) }
        catch {
            close(descriptor)
            throw error
        }
    }
    public static func acquire(_ descriptor: Int32, timeout: TimeInterval) throws {
        let deadline = SystemClock.seconds + max(0, timeout)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN else { throw GuardError("Cannot acquire firewall lock: errno \(errno)") }
            guard SystemClock.seconds < deadline else {
                throw GuardError("Timed out waiting for the previous surge-guard process to release the firewall lock")
            }
            usleep(50_000)
        }
    }
    deinit { close(descriptor) }
}

public final class Firewall {
    private var knownAddresses = Set<String>()
    private var expectedRules: String?
    private let tokenPath = Paths.runtime + "/pf-token"

    public init() {}

    public func attached() throws -> Bool {
        Policy.attachedFirst(try Command.checked("/sbin/pfctl", ["-sr"]))
    }

    public func prepareAttachment() throws {
        let live = try Command.checked("/sbin/pfctl", ["-sr"])
        if Policy.attachedFirst(live) { return }
        guard !live.contains(Policy.attachment) else {
            throw GuardError("Another filter precedes Surge Guard; review PF ordering")
        }
        try RootFiles.verify(Paths.pfConfig)
        try RootFiles.verify(Policy.anchorPath)
        let config = try String(contentsOfFile: Paths.pfConfig)
        guard config.contains(Policy.configBlock) else {
            throw GuardError("Missing managed PF attachment; install first")
        }
        // The daemon must not depend on com.apple.pfctl running first at boot.
        try Command.checked("/sbin/pfctl", ["-n", "-f", Paths.pfConfig])
        try Command.checked("/sbin/pfctl", ["-f", Paths.pfConfig], timeout: 5)
        try requireAttachment()
    }

    private func requireAttachment() throws {
        guard try attached() else { throw GuardError("Surge Guard must be the first live PF filter rule; run start after reviewing pf.conf") }
    }

    public func enabled() throws -> Bool {
        try Command.checked("/sbin/pfctl", ["-s", "info"]).contains("Status: Enabled")
    }

    public func ensureEnabled() throws {
        try requireAttachment()
        let references = try Command.checked("/sbin/pfctl", ["-s", "References"])
        var ownsReference = false
        if FileManager.default.fileExists(atPath: tokenPath) {
            try RootFiles.verify(tokenPath)
            let token = try String(contentsOfFile: tokenPath).trimmingCharacters(in: .whitespacesAndNewlines)
            ownsReference = !token.isEmpty && token.allSatisfy(\.isNumber) &&
                references.split(whereSeparator: { !$0.isNumber }).contains(Substring(token))
        }
        if !ownsReference {
            let result = try Command.run("/sbin/pfctl", ["-E"], timeout: 5)
            guard result.status == 0 else { throw GuardError("Cannot acquire PF reference: \(result.combined)") }
            // pfctl writes the enable-reference token to stderr on macOS.
            guard let line = result.combined.split(separator: "\n").first(where: { $0.contains("Token") }),
                  let token = line.split(whereSeparator: { !$0.isNumber }).last else {
                throw GuardError("PF did not return an enable-reference token")
            }
            try RootFiles.write(String(token) + "\n", to: tokenPath)
        }
        if try !enabled() {
            try Command.checked("/sbin/pfctl", ["-e"], timeout: 5)
            guard try enabled() else { throw GuardError("PF is not enabled") }
        }
    }

    public func rememberAddresses() {
        knownAddresses.formUnion(Probe.addresses().filter { !$0.loopback }.map(\.address))
    }

    public func readRules() throws -> String {
        try Command.checked("/sbin/pfctl", ["-a", Policy.anchor, "-sr"])
    }

    public func unchanged() throws -> Bool {
        guard try attached(), try enabled(), let expectedRules else { return false }
        return try readRules() == expectedRules
    }

    @discardableResult
    public func block() throws -> (rulesLoadedUptime: Double, statesClearedUptime: Double) {
        rememberAddresses()
        // Load fail-closed rules before slower integrity checks. If the anchor
        // was detached, ensureEnabled still rejects the transition.
        try Command.checked("/sbin/pfctl", ["-a", Policy.anchor, "-f", "-"],
                            input: Policy.blocked, timeout: 5)
        let rulesLoaded = SystemClock.seconds
        try ensureEnabled()
        let actual = try readRules()
        guard actual.contains("surge-guard-block") else { throw GuardError("Block rule did not load") }
        // States precede PF rule evaluation. Terminate states involving this
        // Mac, including old interface addresses; never flush all PF state.
        for address in knownAddresses.sorted() {
            try Command.checked("/sbin/pfctl", ["-k", address], timeout: 5)
            try Command.checked("/sbin/pfctl", ["-k", address.contains(":") ? "::/0" : "0.0.0.0/0", "-k", address], timeout: 5)
        }
        knownAddresses = Set(Probe.addresses().filter { !$0.loopback }.map(\.address))
        expectedRules = actual
        return (rulesLoaded, SystemClock.seconds)
    }

    public func allow() throws {
        try ensureEnabled()
        try Command.checked("/sbin/pfctl", ["-a", Policy.anchor, "-F", "rules"], timeout: 5)
        let actual = try readRules()
        guard actual.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GuardError("Surge Guard rules were not cleared")
        }
        expectedRules = actual
    }

    public func unlock() throws {
        // Only the caller's anchor/reference is removed, including during recovery.
        try Command.checked("/sbin/pfctl", ["-a", Policy.anchor, "-F", "rules"], timeout: 5)
        if FileManager.default.fileExists(atPath: tokenPath) {
            try RootFiles.verify(tokenPath)
            let token = try String(contentsOfFile: tokenPath).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty, token.allSatisfy(\.isNumber) else { throw GuardError("Invalid PF reference file") }
            let references = try Command.checked("/sbin/pfctl", ["-s", "References"])
            if references.split(whereSeparator: { !$0.isNumber }).contains(Substring(token)) {
                try Command.checked("/sbin/pfctl", ["-X", token], timeout: 5)
            }
            try FileManager.default.removeItem(atPath: tokenPath)
        }
    }
}
