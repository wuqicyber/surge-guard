import Foundation
import Darwin
import SurgeGuardCore

enum Recovery {
    static let destinations: [String: (String, mode_t)] = [
        "surge-guard": (Paths.binary, 0o755), "daemon.plist": (Paths.plist, 0o644),
        "anchor": (Policy.anchorPath, 0o644), "policy.json": (Paths.configuration, 0o644),
        "surge-guard-launch": (DedicatedEgress.launcher, 0o755)
    ]

    static func copy(_ source: String, to destination: String, mode: mode_t) throws {
        try RootFiles.verify(source)
        try RootFiles.verify(URL(fileURLWithPath: destination).deletingLastPathComponent().path, directory: true)
        if FileManager.default.fileExists(atPath: destination) { try RootFiles.verify(destination) }
        let staged = destination + ".new." + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: staged) }
        try Command.checked("/usr/bin/install", ["-o", "root", "-g", "wheel", "-m", String(mode, radix: 8), source, staged])
        guard rename(staged, destination) == 0 else { throw GuardError("Cannot replace \(destination)") }
    }

    @discardableResult static func save(kind: String) throws -> BackupManifest {
        let manifest = try BackupManifest(kind: kind, includesLauncher: kind == "update" && FileManager.default.fileExists(atPath: DedicatedEgress.launcher))
        try RootFiles.prepareRuntime()
        try RootFiles.preparePublicState()
        if !FileManager.default.fileExists(atPath: Paths.backups) {
            try FileManager.default.createDirectory(atPath: Paths.backups, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try RootFiles.verify(Paths.backups, directory: true)
        let directory = Paths.backups + "/" + manifest.id
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for name in manifest.files {
            let source = destinations[name]!.0
            if name == "policy.json", !FileManager.default.fileExists(atPath: source) {
                // Older guards have no policy file; their baseline is enhanced-only.
                try RootFiles.write(try JSON.encode(Configuration.enhanced, pretty: true), to: directory + "/" + name)
            } else { try copy(source, to: directory + "/" + name, mode: 0o600) }
        }
        let encoded = try JSON.encode(manifest, pretty: true)
        try RootFiles.write(encoded, to: directory + "/manifest.json")
        try RootFiles.write(encoded, to: BackupManifest.pointer(kind), mode: 0o644)
        EventLog.write("backup_created", message: "Local recovery backup saved", details: ["kind": kind, "backup_id": manifest.id])
        return manifest
    }

    static func latest(_ kind: String) throws -> BackupManifest {
        try RootFiles.verify(Paths.publicState, directory: true)
        let pointer = BackupManifest.pointer(kind)
        try RootFiles.verify(pointer)
        let manifest = try JSON.decode(BackupManifest.self, from: Data(contentsOf: URL(fileURLWithPath: pointer)))
        try manifest.validate()
        guard manifest.kind == kind else { throw GuardError("Wrong recovery backup kind") }
        return manifest
    }

    static func validate(_ manifest: BackupManifest) throws {
        try manifest.validate()
        try RootFiles.verify(Paths.backups, directory: true)
        let directory = Paths.backups + "/" + manifest.id
        try RootFiles.verify(directory, directory: true)
        try RootFiles.verify(directory + "/manifest.json")
        let saved = try JSON.decode(BackupManifest.self, from: Data(contentsOf: URL(fileURLWithPath: directory + "/manifest.json")))
        guard try JSON.encode(saved) == JSON.encode(manifest) else { throw GuardError("Recovery backup metadata differs") }
        for name in manifest.files { try RootFiles.verify(directory + "/" + name) }
        _ = try Configuration.decode(Data(contentsOf: URL(fileURLWithPath: directory + "/policy.json")))
        if manifest.kind == "update" {
            try Command.checked("/sbin/pfctl", ["-n", "-a", Policy.anchor, "-f", directory + "/anchor"])
            try Command.checked("/usr/bin/plutil", ["-lint", directory + "/daemon.plist"])
        }
    }

    static func restore(_ manifest: BackupManifest) throws {
        try validate(manifest)
        for name in manifest.files {
            let (destination, mode) = destinations[name]!
            try copy(Paths.backups + "/" + manifest.id + "/" + name, to: destination, mode: mode)
        }
        if manifest.kind == "update", !manifest.files.contains("surge-guard-launch"),
           FileManager.default.fileExists(atPath: DedicatedEgress.launcher) {
            try RootFiles.verify(DedicatedEgress.launcher)
            try FileManager.default.removeItem(atPath: DedicatedEgress.launcher)
        }
        if try manifest.files.contains("surge-guard-launch") || Configuration.load().usesPersistentTCP {
            try Admin.prepareDedicatedGroup()
        }
        EventLog.write("backup_restored", level: "warning", message: "Previous local files restored; verify their protection capabilities", details: ["kind": manifest.kind, "backup_id": manifest.id])
    }
}
