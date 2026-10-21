import Foundation
import AppKit
import Darwin
import SurgeGuardCore

func migrateLegacy() throws {
    let legacy = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".surge_gate")
    let legacyConfig = legacy.appendingPathComponent("config.json")
    guard !FileManager.default.fileExists(atPath: UserPaths.config), FileManager.default.fileExists(atPath: legacyConfig.path) else { return }
    guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: legacyConfig)) as? [String: Any] else {
        throw GuardError("Invalid legacy config; original files retained")
    }
    var known: [String: String] = [:]
    let roots = ["/Applications", "/System/Applications", "/System/Applications/Utilities", FileManager.default.homeDirectoryForCurrentUser.path + "/Applications"]
    for root in roots {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] where name.hasSuffix(".app") {
            let url = URL(fileURLWithPath: root).appendingPathComponent(name)
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
            for value in [url.deletingPathExtension().lastPathComponent, bundle.object(forInfoDictionaryKey: "CFBundleName") as? String, bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String].compactMap({ $0 }) {
                known[value] = id
            }
        }
    }
    func resolve(_ name: String) -> String? {
        if GateConfiguration.validBundleID(name), NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) != nil { return name }
        if let id = known[name] { return id }
        event("migration_app_unresolved", "Legacy application name needs a bundle ID", app: name)
        return nil
    }
    func list(_ key: String) -> [String] {
        var seen = Set<String>()
        return (object[key] as? [String] ?? []).compactMap(resolve).filter { seen.insert($0).inserted }
    }
    var config = GateConfiguration.standard
    config.priorityOrder = list("priority_startup_order")
    config.excludedApps = list("ignored_apps").filter { $0 != "com.nssurge.surge-mac" && $0 != "com.apple.finder" }
    config.startupApps = list("always_launch_after_surge").filter { !config.excludedApps.contains($0) && $0 != "com.nssurge.surge-mac" }
    config.restoreSession = object["restore_previous_apps_on_reboot"] as? Bool ?? true
    config.delayBetweenAppsSeconds = object["delay_between_apps_seconds"] as? Double ?? 1
    config.quitTimeoutSeconds = object["app_quit_timeout_seconds"] as? Double ?? 30
    try config.validate()
    let session = legacy.appendingPathComponent("last_session_apps.json")
    var importedSession: GateSession?
    if FileManager.default.fileExists(atPath: session.path), !FileManager.default.fileExists(atPath: UserPaths.session) {
        guard let previous = try JSONSerialization.jsonObject(with: Data(contentsOf: session)) as? [String: Any],
              let names = previous["apps"] as? [String] else { throw GuardError("Invalid legacy session; original files retained") }
        importedSession = GateSession(apps: names.compactMap(resolve), pending: [])
    }
    if let importedSession { try UserPaths.write(try JSON.encode(importedSession), to: UserPaths.session) }
    try UserPaths.write(try JSON.encode(config, pretty: true), to: UserPaths.config)
    event("legacy_migrated", "Imported legacy config/session; original files retained")
}

func install() throws {
    try UserPaths.prepare()
    try migrateLegacy()
    if !FileManager.default.fileExists(atPath: UserPaths.config) {
        try UserPaths.write(try JSON.encode(GateConfiguration.standard, pretty: true), to: UserPaths.config)
    }
    _ = try GateConfiguration.load()
    let source = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath().path
    try UserPaths.prepare(UserPaths.directory + "/bin")
    let staged = UserPaths.binary + ".new." + UUID().uuidString
    defer { try? FileManager.default.removeItem(atPath: staged) }
    if source != UserPaths.binary {
        try FileManager.default.copyItem(atPath: source, toPath: staged)
        guard chmod(staged, 0o700) == 0 else { throw GuardError("Cannot protect staged user binary") }
    }
    let domain = "gui/\(getuid())"
    for label in [UserPaths.label, "com.user.surgegate"] {
        if try Command.run("/bin/launchctl", ["print", "\(domain)/\(label)"]).status == 0 {
            try Command.checked("/bin/launchctl", ["bootout", "\(domain)/\(label)"], timeout: 10)
        }
    }
    let oldPlist = FileManager.default.homeDirectoryForCurrentUser.path + "/Library/LaunchAgents/com.user.surgegate.plist"
    if FileManager.default.fileExists(atPath: oldPlist) {
        let backup = FileManager.default.fileExists(atPath: oldPlist + ".migrated-backup") ? oldPlist + ".migrated-backup." + UUID().uuidString : oldPlist + ".migrated-backup"
        try FileManager.default.moveItem(atPath: oldPlist, toPath: backup)
    }
    do {
        let fd = try lock("gate.lock", timeout: 10)
        defer { close(fd) }
        if source != UserPaths.binary {
            guard rename(staged, UserPaths.binary) == 0 else { throw GuardError("Cannot install user binary") }
        }
    }
    let agents = URL(fileURLWithPath: UserPaths.plist).deletingLastPathComponent()
    try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
    let plist: [String: Any] = ["Label": UserPaths.label, "ProgramArguments": [UserPaths.binary, "run"],
                               "RunAtLoad": true, "KeepAlive": true, "ThrottleInterval": 10,
                               "ProcessType": "Interactive",
                               "StandardOutPath": "/dev/null", "StandardErrorPath": "/dev/null"]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: URL(fileURLWithPath: UserPaths.plist), options: .atomic)
    try Command.checked("/bin/launchctl", ["enable", domain + "/" + UserPaths.label])
    try Command.checked("/bin/launchctl", ["bootstrap", domain, UserPaths.plist], timeout: 10)
    print("SurgeGate installed. Configuration: \(UserPaths.config)")
}

@discardableResult func ensureServiceLoaded(waitForRunning: Bool = false) throws -> Bool {
    let domain = "gui/\(getuid())"
    let service = "\(domain)/\(UserPaths.label)"
    let probe = try Command.run("/bin/launchctl", ["print", service])
    let wasLoaded = probe.status == 0
    if !wasLoaded {
        guard FileManager.default.fileExists(atPath: UserPaths.plist) else { throw GuardError("SurgeGate plist not found; run install first") }
        try Command.checked("/bin/launchctl", ["enable", service])
        try Command.checked("/bin/launchctl", ["bootstrap", domain, UserPaths.plist], timeout: 10)
    }
    if waitForRunning {
        let deadline = SystemClock.seconds + 5
        while !(try Command.run("/bin/launchctl", ["print", service]).output.contains("state = running")) && SystemClock.seconds < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        guard try Command.run("/bin/launchctl", ["print", service]).output.contains("state = running") else {
            throw GuardError("SurgeGate service must be running")
        }
    }
    return !wasLoaded
}

func stopService() throws {
    let service = "gui/\(getuid())/\(UserPaths.label)"
    if try Command.run("/bin/launchctl", ["print", service]).status == 0 {
        try Command.checked("/bin/launchctl", ["bootout", service], timeout: 10)
    }
    let fd = try lock("gate.lock", timeout: 10)
    close(fd)
    try? FileManager.default.removeItem(atPath: shutdownPath)
    try publish("stopped", "Stopped by user; current network and PF rules are unchanged",
                pending: (try? GateSession.load().pending) ?? [], surge: surgeIdentity(), update: try? GateUpdate.load())
    event("gate_stopped", "User stopped SurgeGate service; current network and PF rules unchanged")
    print("SurgeGate service stopped. Current network and PF protection are unchanged.")
}

func restartService() throws {
    let service = "gui/\(getuid())/\(UserPaths.label)"
    if try ensureServiceLoaded() {
        print("SurgeGate was stopped; service started.")
    } else {
        try Command.checked("/bin/launchctl", ["kill", "SIGTERM", service])
        print("Restart requested; launchd restarts the user service")
    }
}

func queueShutdown(_ action: String) throws {
    guard try GateUpdate.load()?.paused != true else { throw GuardError("Finish or cancel the Surge update and resume Gate before ordered shutdown") }
    try ensureServiceLoaded(waitForRunning: true)
    if FileManager.default.fileExists(atPath: shutdownPath) {
        let existing = (try? Data(contentsOf: URL(fileURLWithPath: shutdownPath)))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
        if existing?["boot_id"] != SystemClock.bootID {
            try? FileManager.default.removeItem(atPath: shutdownPath)
        } else {
            throw GuardError("A shutdown request is already queued")
        }
    }
    let request = ["action": action, "boot_id": SystemClock.bootID]
    try UserPaths.write(String(decoding: JSONSerialization.data(withJSONObject: request), as: UTF8.self), to: shutdownPath)
    print("Queued normal shutdown. Unsaved-document dialogs may need your attention; check SurgeGate logs if aborted.")
}

func uninstallService() throws {
    let service = "gui/\(getuid())/\(UserPaths.label)"
    if try Command.run("/bin/launchctl", ["print", service]).status == 0 { try Command.checked("/bin/launchctl", ["bootout", service], timeout: 10) }
    for path in [UserPaths.plist, UserPaths.binary] where FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
    print("User service removed; configuration/session/logs retained. System guard is separate.")
}
