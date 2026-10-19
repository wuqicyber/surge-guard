import Foundation
import Darwin

public enum UserPaths {
    public static var directory: String { FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Application Support/SurgeGuard" }
    public static var binary: String { directory + "/bin/surge-gate" }
    public static var config: String { directory + "/gate.json" }
    public static var session: String { directory + "/session.json" }
    public static var status: String { directory + "/gate-status.json" }
    public static var log: String { directory + "/gate-events.jsonl" }
    public static let label = "io.github.surge-guard.gate"
    public static var plist: String { FileManager.default.homeDirectoryForCurrentUser.path + "/Library/LaunchAgents/" + label + ".plist" }

    public static func prepare(_ path: String = directory) throws {
        guard geteuid() != 0 else { throw GuardError("SurgeGate must run as a normal user") }
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o022 == 0 else { throw GuardError("Unsafe user state directory") }
    }

    public static func write(_ text: String, to path: String) throws {
        try prepare()
        guard URL(fileURLWithPath: path).deletingLastPathComponent().path == directory else {
            throw GuardError("User state must be written inside its managed directory")
        }
        var info = stat()
        if lstat(path, &info) == 0 {
            guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG else { throw GuardError("Unsafe user state file") }
        }
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        guard chmod(path, 0o600) == 0 else { throw GuardError("Cannot protect user state file") }
    }
}

public struct GateConfiguration: Codable, Equatable {
    private static let bundleCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
    public var version: Int
    public var startupApps: [String]
    public var priorityOrder: [String]
    public var excludedApps: [String]
    public var restoreSession: Bool
    public var delayBetweenAppsSeconds: Double
    public var quitTimeoutSeconds: Double

    public static let standard = GateConfiguration(version: 1, startupApps: [], priorityOrder: [], excludedApps: [],
                                                   restoreSession: true, delayBetweenAppsSeconds: 1, quitTimeoutSeconds: 30)

    public static func validBundleID(_ value: String) -> Bool {
        value.count <= 255 && value.contains(".") && !value.hasPrefix(".") && !value.hasSuffix(".") &&
            value.unicodeScalars.allSatisfy { bundleCharacters.contains($0) }
    }

    public func validate() throws {
        guard version == 1, delayBetweenAppsSeconds.isFinite, (0...30).contains(delayBetweenAppsSeconds),
              quitTimeoutSeconds.isFinite, (5...300).contains(quitTimeoutSeconds) else {
            throw GuardError("Invalid gate version, launch delay or quit timeout")
        }
        for list in [startupApps, priorityOrder, excludedApps] {
            guard list.count <= 256, Set(list).count == list.count, list.allSatisfy(Self.validBundleID) else {
                throw GuardError("Application lists require unique bundle IDs")
            }
        }
        guard !startupApps.contains("com.nssurge.surge-mac"), Set(startupApps).isDisjoint(with: excludedApps) else {
            throw GuardError("Startup apps must not contain Surge or an excluded app")
        }
    }

    public static func load() throws -> GateConfiguration {
        let data = try Data(contentsOf: URL(fileURLWithPath: UserPaths.config))
        guard data.count <= 65_536, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["version", "startup_apps", "priority_order", "excluded_apps", "restore_session", "delay_between_apps_seconds", "quit_timeout_seconds"] else {
            throw GuardError("Invalid or unknown SurgeGate configuration fields")
        }
        let config = try JSON.decode(GateConfiguration.self, from: data)
        try config.validate()
        return config
    }

    public func targets(saved: [String]) -> [String] {
        let excluded = Set(excludedApps + ["com.apple.finder", "com.nssurge.surge-mac"])
        var seen = Set<String>()
        let targets = (startupApps + (restoreSession ? saved : [])).filter { Self.validBundleID($0) && !excluded.contains($0) && seen.insert($0).inserted }
        let ranked = priorityOrder.filter { targets.contains($0) }
        return ranked + targets.filter { !ranked.contains($0) }
    }
}

public struct GateSession: Codable {
    public var apps: [String]
    public var pending: [String]
    public var savedAt: Date

    public init(apps: [String], pending: [String]) { self.apps = apps; self.pending = pending; savedAt = Date() }

    public static func load() throws -> GateSession {
        guard FileManager.default.fileExists(atPath: UserPaths.session) else { return GateSession(apps: [], pending: []) }
        let data = try Data(contentsOf: URL(fileURLWithPath: UserPaths.session))
        return try decode(data)
    }

    public static func decode(_ data: Data) throws -> GateSession {
        guard data.count <= 65_536 else { throw GuardError("Session is too large") }
        let result = try JSON.decode(GateSession.self, from: data)
        guard result.apps.count <= 256, result.pending.count <= 256,
              (result.apps + result.pending).allSatisfy(GateConfiguration.validBundleID) else { throw GuardError("Session contains invalid app IDs") }
        return result
    }
}
