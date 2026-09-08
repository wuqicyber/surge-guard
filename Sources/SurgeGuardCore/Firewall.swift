import Foundation
import Darwin

public enum Paths {
    public static let label = "io.github.surge-guard"
    public static let binary = "/Library/PrivilegedHelperTools/surge-guard"
    public static let plist = "/Library/LaunchDaemons/\(label).plist"
    public static let runtime = "/private/var/db/surge-guard"
    public static let pfConfig = "/private/etc/pf.conf"
}

public enum RootFiles {
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
        try value.write(toFile: path, atomically: true, encoding: .utf8)
        guard chmod(path, mode) == 0 else { throw GuardError("Cannot set permissions: \(path)") }
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
    public init() throws {
        try RootFiles.prepareRuntime()
        descriptor = open(Paths.runtime + "/lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw GuardError("Cannot open service lock") }
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            close(descriptor)
            throw GuardError("Another surge-guard process owns the firewall; stop it first")
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
        try Command.checked("/sbin/pfctl", ["-f", Paths.pfConfig])
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
            let result = try Command.run("/sbin/pfctl", ["-E"])
            guard result.status == 0 else { throw GuardError("Cannot acquire PF reference: \(result.combined)") }
            // pfctl writes the enable-reference token to stderr on macOS.
            guard let line = result.combined.split(separator: "\n").first(where: { $0.contains("Token") }),
                  let token = line.split(whereSeparator: { !$0.isNumber }).last else {
                throw GuardError("PF did not return an enable-reference token")
            }
            try RootFiles.write(String(token) + "\n", to: tokenPath)
        }
        if try !enabled() { try Command.checked("/sbin/pfctl", ["-e"]) }
        guard try enabled() else { throw GuardError("PF is not enabled") }
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

    public func block() throws {
        try requireAttachment()
        rememberAddresses()
        try Command.checked("/sbin/pfctl", ["-a", Policy.anchor, "-f", "-"], input: Policy.blocked)
        try ensureEnabled()
        let actual = try readRules()
        guard actual.contains("surge-guard-block") else { throw GuardError("Block rule did not load") }
        // States precede PF rule evaluation. Terminate states involving this
        // Mac, including old interface addresses; never flush all PF state.
        for address in knownAddresses.sorted() {
            try Command.checked("/sbin/pfctl", ["-k", address])
            try Command.checked("/sbin/pfctl", ["-k", address.contains(":") ? "::/0" : "0.0.0.0/0", "-k", address])
        }
        knownAddresses = Set(Probe.addresses().filter { !$0.loopback }.map(\.address))
        expectedRules = actual
    }

    public func allow() throws {
        try requireAttachment()
        try ensureEnabled()
        try Command.checked("/sbin/pfctl", ["-a", Policy.anchor, "-F", "rules"])
        let actual = try readRules()
        guard actual.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GuardError("Surge Guard rules were not cleared")
        }
        expectedRules = actual
    }

    public func unlock() throws {
        // Only the caller's anchor/reference is removed, including during recovery.
        try Command.checked("/sbin/pfctl", ["-a", Policy.anchor, "-F", "rules"])
        if FileManager.default.fileExists(atPath: tokenPath) {
            try RootFiles.verify(tokenPath)
            let token = try String(contentsOfFile: tokenPath).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty, token.allSatisfy(\.isNumber) else { throw GuardError("Invalid PF reference file") }
            let references = try Command.checked("/sbin/pfctl", ["-s", "References"])
            if references.split(whereSeparator: { !$0.isNumber }).contains(Substring(token)) {
                try Command.checked("/sbin/pfctl", ["-X", token])
            }
            try FileManager.default.removeItem(atPath: tokenPath)
        }
    }
}
