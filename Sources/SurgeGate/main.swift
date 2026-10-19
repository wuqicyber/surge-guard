import Foundation
import AppKit
import Darwin
import SurgeGuardCore

func event(_ code: String, _ message: String, app: String? = nil, level: String? = nil, details: [String: Any] = [:]) {
    do {
        try UserPaths.prepare()
        let record: [String: Any] = ["time": ISO8601DateFormatter().string(from: Date()), "component": "SurgeGate", "event": code,
                                    "level": level ?? (code.contains("failed") || code.contains("error") || code.contains("aborted") ? "error" : "info"),
                                    "message": message, "app": app ?? "", "pid": getpid(), "boot_id": SystemClock.bootID, "details": details]
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes])
        try EventFile.append(data, to: UserPaths.log, owner: getuid(), lockPath: UserPaths.log + ".lock")
    } catch { NSLog("SurgeGate event %@: %@; logging failed: %@", code, message, String(describing: error)) }
}

func applications() throws -> [NSRunningApplication] {
    let all = NSWorkspace.shared.runningApplications
    guard !all.isEmpty else { throw GuardError("Application inventory unavailable; previous session retained") }
    return all.filter { $0.activationPolicy == .regular && !$0.isTerminated && $0.bundleIdentifier != nil }
}

func appIDs(_ config: GateConfiguration) throws -> [String] {
    let excluded = Set(config.excludedApps + ["com.apple.finder", "com.nssurge.surge-mac"])
    return Array(Set(try applications().compactMap(\.bundleIdentifier))).filter { !excluded.contains($0) }.sorted()
}

@discardableResult func launch(_ id: String) throws -> Bool {
    if NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { !$0.isTerminated }) { return false }
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { throw GuardError("Application is not installed") }
    let config = NSWorkspace.OpenConfiguration()
    config.activates = false
    var result: Result<Void, Error>?
    NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
        DispatchQueue.main.async { result = error.map { .failure($0) } ?? .success(()) }
    }
    let deadline = SystemClock.seconds + 10
    while result == nil && SystemClock.seconds < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    guard let result else { throw GuardError("Application launch timed out") }
    try result.get()
    return true
}

struct GateStatus: Codable {
    var state: String
    var message: String
    var pending: [String]
    var bootId = SystemClock.bootID
    var checkedUptime = SystemClock.seconds
    var pid = getpid()
}

func publish(_ state: String, _ message: String, pending: [String]) throws {
    try UserPaths.write(try JSON.encode(GateStatus(state: state, message: message, pending: pending)), to: UserPaths.status)
}

func lock(_ name: String, timeout: TimeInterval = 0) throws -> Int32 {
    try UserPaths.prepare()
    let fd = open(UserPaths.directory + "/" + name, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw GuardError("Cannot open gate lock") }
    do { try RuntimeLock.acquire(fd, timeout: timeout) }
    catch { close(fd); throw GuardError("SurgeGate lock \(name): \(error)") }
    return fd
}

func saveSession(_ config: GateConfiguration, pending: [String]) throws {
    try UserPaths.write(try JSON.encode(GateSession(apps: appIDs(config), pending: pending)), to: UserPaths.session)
}

let shutdownPath = UserPaths.directory + "/shutdown-request.json"

func shutdown(_ action: String, config: GateConfiguration, pending: [String]) throws {
    guard ["restart", "shutdown"].contains(action) else { throw GuardError("Invalid shutdown action") }
    guard ["allowed", "blocked"].contains(StatusReport.read().state) else {
        throw GuardError("System guard state is not verified; no applications were asked to quit")
    }
    try saveSession(config, pending: pending)
    event("shutdown_started", "Requesting normal application quits; no force termination")
    let excluded = Set(config.excludedApps + ["com.apple.finder", "com.nssurge.surge-mac"])
    let apps = try applications().filter { !excluded.contains($0.bundleIdentifier ?? "") }
    for app in apps {
        guard app.terminate() else { throw GuardError("Application declined to quit: \(app.bundleIdentifier ?? "unknown")") }
    }
    let deadline = SystemClock.seconds + config.quitTimeoutSeconds
    while apps.contains(where: { !$0.isTerminated }) && SystemClock.seconds < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }
    let remaining = apps.filter { !$0.isTerminated }.compactMap(\.bundleIdentifier)
    guard remaining.isEmpty else { throw GuardError("Quit cancelled or timed out; shutdown aborted: \(remaining.joined(separator: ", "))") }
    let surge = NSRunningApplication.runningApplications(withBundleIdentifier: "com.nssurge.surge-mac")
    for app in surge { guard app.terminate() else { throw GuardError("Surge declined to quit; shutdown aborted") } }
    let blockDeadline = SystemClock.seconds + config.quitTimeoutSeconds
    while SystemClock.seconds < blockDeadline {
        let status = StatusReport.read()
        if status.state == "blocked", surge.allSatisfy(\.isTerminated) { break }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }
    guard StatusReport.read().state == "blocked", surge.allSatisfy(\.isTerminated) else {
        throw GuardError("Cannot confirm blocked firewall after Surge quit; shutdown aborted")
    }
    let verb = action == "restart" ? "restart" : "shut down"
    try Command.checked("/usr/bin/osascript", ["-e", "tell application \"System Events\" to \(verb)"], timeout: 30)
    event("shutdown_requested", "macOS accepted the request; session snapshots paused until next service start")
}

func run() throws {
    let fd = try lock("gate.lock")
    defer { close(fd) }
    let initial = try GateConfiguration.load()
    let saved = try GateSession.load()
    // Keep the run loop alive even if AppKit has no active event sources.
    let keepAlive = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in }
    defer { keepAlive.invalidate() }
    var pending = initial.targets(saved: saved.pending + saved.apps)
    try UserPaths.write(try JSON.encode(GateSession(apps: saved.apps, pending: pending)), to: UserPaths.session)
    var lastMessage = ""
    var lastGuardState: String?
    var lastSnapshot: Double = 0
    var nextLaunch: Double = 0
    var nextSurgeLaunch: Double = 0
    var shutdownAccepted = false
    var shutdownFailure: String?
    event("gate_started", "Waiting for fresh verified system guard status")
    while true {
        do {
            let config = try GateConfiguration.load()
            if FileManager.default.fileExists(atPath: shutdownPath), !shutdownAccepted {
                let request = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: shutdownPath))) as? [String: String]
                try FileManager.default.removeItem(atPath: shutdownPath)
                guard let action = request?["action"], let requested = request?["boot_id"], requested == SystemClock.bootID else {
                    throw GuardError("Discarded invalid/previous-boot shutdown request")
                }
                try publish("shutting_down", "Waiting for applications to quit", pending: pending)
                shutdownAccepted = true
                do { try shutdown(action, config: config, pending: pending) }
                catch {
                    shutdownFailure = "\(error). Session retained; restart SurgeGate to resume recovery"
                    event("shutdown_aborted", shutdownFailure!)
                }
            }
            if shutdownAccepted {
                try publish(shutdownFailure == nil ? "shutting_down" : "error",
                            shutdownFailure ?? "macOS shutdown requested; snapshots paused", pending: pending)
            } else {
                pending.removeAll { config.excludedApps.contains($0) }
                if NSRunningApplication.runningApplications(withBundleIdentifier: "com.nssurge.surge-mac").isEmpty,
                   SystemClock.seconds >= nextSurgeLaunch {
                    nextSurgeLaunch = SystemClock.seconds + 30
                    try launch("com.nssurge.surge-mac")
                    event("surge_launch_requested", "Started Surge; still waiting for enhanced mode and policy")
                }
                let status = StatusReport.read()
                if status.state == "allowed", let target = pending.first, SystemClock.seconds >= nextLaunch {
                    switch Result(catching: { try launch(target) }) {
                    case .success(let requestedLaunch):
                        pending.removeFirst()
                        event(requestedLaunch ? "application_restored" : "application_already_running",
                              requestedLaunch ? "Application launch request completed" : "Application was already running; no launch requested",
                              app: target, details: ["pending_count": pending.count])
                        nextLaunch = SystemClock.seconds + config.delayBetweenAppsSeconds
                        try saveSession(config, pending: pending)
                    case .failure(let error):
                        event("application_restore_failed", String(describing: error), app: target)
                        // Rotate failed apps so an unavailable app cannot starve the rest.
                        pending.append(pending.removeFirst())
                        nextLaunch = SystemClock.seconds + 30
                    }
                }
                let state = status.state == "unknown" ? "unknown" : status.state == "allowed" ? (pending.isEmpty ? "ready" : "restoring") : "waiting"
                let message = status.state == "allowed" ? "\(pending.count) application(s) pending" : "\(status.state): \(status.reason)"
                try publish(state, message, pending: pending)
                if message != lastMessage {
                    let code: String
                    if status.state == "unknown" { code = "gate_status_unavailable" }
                    else if lastGuardState == "unknown" { code = "gate_status_recovered" }
                    else if status.state != "allowed" { code = "gate_waiting" }
                    else { code = pending.isEmpty ? "gate_ready" : "gate_restore_progress" }
                    event(code, message, level: status.state == "unknown" ? "warning" : "info",
                          details: ["pending_count": pending.count, "guard_state": status.state,
                                    "reason": status.reason, "previous_guard_state": lastGuardState ?? "initial"])
                    lastMessage = message
                    lastGuardState = status.state
                }
                if SystemClock.seconds - lastSnapshot >= 30 {
                    try saveSession(config, pending: pending)
                    lastSnapshot = SystemClock.seconds
                }
            }
        } catch {
            let message = String(describing: error)
            try? publish("error", message, pending: pending)
            if message != lastMessage { event("gate_error", message); lastMessage = message }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1))
    }
}

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
                               "StandardOutPath": "/dev/null", "StandardErrorPath": "/dev/null"]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: URL(fileURLWithPath: UserPaths.plist), options: .atomic)
    try Command.checked("/bin/launchctl", ["enable", domain + "/" + UserPaths.label])
    try Command.checked("/bin/launchctl", ["bootstrap", domain, UserPaths.plist], timeout: 10)
    print("SurgeGate installed. Configuration: \(UserPaths.config)")
}

let usage = """
SurgeGate — user-session companion to Surge Guard
  install / setup       Install/update user service; migrate legacy config without deleting it
  run                   Wait for verified protection, restore apps, checkpoint session every 30s
  status [--json]       Inspect this service (not a firewall claim)
  restart               Restart the user service
  edit-config           Edit bundle-ID application settings
  logs [--follow] [--json]
                        Readable recent events; optional follow or JSON Lines
  shutdown --action restart|shutdown
                        Queue an ordered normal quit; abort if an app refuses or PF cannot be verified
  uninstall             Remove user service and binary; retain settings/session/logs
Run as your normal user. No Python, force-kill or broad process-name matching.
"""

do {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let action = args.first, !["help", "--help", "-h"].contains(action) else { print(usage); exit(0) }
    guard geteuid() != 0 else { throw GuardError("Run SurgeGate without sudo") }
    switch action {
    case "install", "setup": try install()
    case "run": try run()
    case "status":
        let status = try JSON.decode(GateStatus.self, from: Data(contentsOf: URL(fileURLWithPath: UserPaths.status)))
        let service = try Command.run("/bin/launchctl", ["print", "gui/\(getuid())/\(UserPaths.label)"])
        let running = service.status == 0 && service.output.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "pid = \(status.pid)" }
        let fresh = running && status.bootId == SystemClock.bootID && SystemClock.seconds >= status.checkedUptime && SystemClock.seconds - status.checkedUptime < 15
        if args.contains("--json") {
            struct Report: Encodable { var running: Bool; var fresh: Bool; var status: GateStatus }
            print(try JSON.encode(Report(running: running, fresh: fresh, status: status)))
        } else { print(fresh ? "\(status.state): \(status.message)" : "状态过期或服务未运行") }
    case "restart":
        try Command.checked("/bin/launchctl", ["kill", "SIGTERM", "gui/\(getuid())/\(UserPaths.label)"])
        print("Restart requested; launchd restarts the user service")
    case "edit-config":
        try Command.checked("/usr/bin/open", ["-a", "TextEdit", UserPaths.config])
    case "logs":
        let flags = Array(args.dropFirst())
        guard Set(flags).count == flags.count, flags.allSatisfy({ ["--json", "--follow"].contains($0) }) else { throw GuardError("Usage: logs [--follow] [--json]") }
        try LogReader.show(path: UserPaths.log, follow: args.contains("--follow"), json: args.contains("--json"))
    case "shutdown":
        guard args.count == 3, args[1] == "--action", ["restart", "shutdown"].contains(args[2]) else { throw GuardError("Usage: shutdown --action restart|shutdown") }
        guard try Command.run("/bin/launchctl", ["print", "gui/\(getuid())/\(UserPaths.label)"]).output.contains("state = running") else { throw GuardError("SurgeGate service must be running") }
        guard !FileManager.default.fileExists(atPath: shutdownPath) else { throw GuardError("A shutdown request is already queued") }
        let request = ["action": args[2], "boot_id": SystemClock.bootID]
        try UserPaths.write(String(decoding: JSONSerialization.data(withJSONObject: request), as: UTF8.self), to: shutdownPath)
        print("Queued normal shutdown. Unsaved-document dialogs may need your attention; check SurgeGate logs if aborted.")
    case "uninstall":
        let service = "gui/\(getuid())/\(UserPaths.label)"
        if try Command.run("/bin/launchctl", ["print", service]).status == 0 { try Command.checked("/bin/launchctl", ["bootout", service], timeout: 10) }
        for path in [UserPaths.plist, UserPaths.binary] where FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
        print("User service removed; configuration/session/logs retained. System guard is separate.")
    default: throw GuardError("Unknown command: \(action)")
    }
} catch {
    if CommandLine.arguments.dropFirst().first == "run" {
        try? publish("error", String(describing: error), pending: [])
    }
    event("command_failed", String(describing: error))
    fputs("surge-gate: \(error)\n", stderr)
    exit(1)
}
