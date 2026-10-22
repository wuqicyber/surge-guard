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

var workspaceLaunches = Set<UUID>()
let gateRunID = UUID()

func pendingLaunchState() throws -> (request: GatePendingLaunch, disposition: GatePendingLaunch.Disposition)? {
    guard let request = try GatePendingLaunch.load() else { return nil }
    if workspaceLaunches.contains(request.id) { return (request, .inFlight) }
    let appRunning: Bool
    if request.app == "com.nssurge.surge-mac" {
        let identity = surgeIdentity()
        appRunning = identity.pid != nil && (identity.verified || identity.reason == "dedicated_group_not_required")
        if !appRunning, request.observer == gateRunID, let task = surgeLaunchProcess, !task.isRunning {
            return (request, .failed)
        }
        if !appRunning, request.observer == gateRunID, request.child == nil, surgeLaunchProcess?.isRunning == true {
            return (request, .inFlight)
        }
    } else {
        appRunning = NSRunningApplication.runningApplications(withBundleIdentifier: request.app).contains(where: { !$0.isTerminated })
    }
    if appRunning { return (request, .settled) }
    let child = try request.child.flatMap { try SurgeProcess.read(pid: $0.pid) }
    return (request, request.disposition(observer: gateRunID, callbackPending: false, appRunning: false, childIdentity: child))
}

@discardableResult func launch(_ id: String) throws -> Bool {
    if NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { !$0.isTerminated }) { return false }
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { throw GuardError("Application is not installed") }
    let config = NSWorkspace.OpenConfiguration()
    config.activates = false
    let request = GatePendingLaunch(app: id, observer: gateRunID)
    try request.save()
    workspaceLaunches.insert(request.id)
    var result: Result<Void, Error>?
    NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
        DispatchQueue.main.async {
            workspaceLaunches.remove(request.id)
            do {
                try request.complete()
                result = error.map { .failure($0) } ?? .success(())
            } catch { result = .failure(error) }
        }
    }
    let deadline = SystemClock.seconds + 10
    while result == nil && SystemClock.seconds < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    guard let result else { throw GuardError("Application launch timed out") }
    try result.get()
    return true
}

var surgeLaunchProcess: Process?
enum SurgeLaunchResult { case unchanged, launched, waitingForBlock, updatePaused }

func surgeIdentity() -> GateSurgeIdentity {
    var result = GateSurgeIdentity()
    do {
        let policy = try Configuration.load()
        result.pid = try Probe.trustedSurgePID()
        guard let pid = result.pid else { result.reason = "Surge absent, untrusted or multiple instances"; return result }
        if policy.usesPersistentTCP {
            let group = try DedicatedEgress.group()
            result.expectedGroup = group
            result.verified = try DedicatedEgress.identityMatches(pid: pid, uid: getuid(), group: group)
            result.reason = result.verified ? "dedicated_group_verified" : "surge_egress_identity_mismatch"
        } else { result.reason = "dedicated_group_not_required" }
    } catch { result.reason = String(describing: error) }
    return result
}

func ensureSurge(quitTimeout: Double) throws -> SurgeLaunchResult {
    if try GateUpdate.load()?.paused == true { return .updatePaused }
    let policy = try Configuration.load()
    guard policy.usesPersistentTCP else { return try launch("com.nssurge.surge-mac") ? .launched : .unchanged }
    let group = try DedicatedEgress.group()
    let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.nssurge.surge-mac").filter { !$0.isTerminated }
    if let pid = try Probe.trustedSurgePID(), (apps.isEmpty || (apps.count == 1 && apps[0].processIdentifier == pid)),
       try DedicatedEgress.identityMatches(pid: pid, uid: getuid(), group: group) { return .unchanged }
    if !apps.isEmpty {
        guard StatusReport.read().state == "blocked" else {
            return .waitingForBlock
        }
        if try GateUpdate.load()?.paused == true { return .updatePaused }
        for app in apps {
            guard app.terminate() else { throw GuardError("Surge declined normal quit; dedicated launch cancelled") }
        }
        let deadline = SystemClock.seconds + quitTimeout
        while apps.contains(where: { !$0.isTerminated }) && SystemClock.seconds < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        guard apps.allSatisfy(\.isTerminated) else { throw GuardError("Surge did not finish normal quit; no forced termination") }
    }
    if try GateUpdate.load()?.paused == true { return .updatePaused }
    if surgeLaunchProcess?.isRunning == true { return .unchanged }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: DedicatedEgress.launcher)
    task.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
    task.standardInput = FileHandle.nullDevice
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    var request = GatePendingLaunch(app: "com.nssurge.surge-mac", observer: gateRunID)
    try request.save()
    do { try task.run() }
    catch { try request.complete(); throw error }
    surgeLaunchProcess = task
    request.child = try SurgeProcess.read(pid: task.processIdentifier)
    if request.child != nil { try request.save() }
    let deadline = SystemClock.seconds + 10
    while SystemClock.seconds < deadline {
        if let pid = try Probe.trustedSurgePID(),
           try DedicatedEgress.identityMatches(pid: pid, uid: getuid(), group: group) { try request.complete(); return .launched }
        guard task.isRunning else {
            try request.complete()
            throw GuardError("Dedicated Surge launcher exited with status \(task.terminationStatus)")
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    throw GuardError("Dedicated Surge startup timed out; networking remains gated")
}

struct GateStatus: Codable {
    var state: String
    var message: String
    var pending: [String]
    var surge: GateSurgeIdentity?
    var update: GateUpdate?
    var pendingLaunch: GatePendingLaunch?
    var runId: UUID? = gateRunID
    var capabilities = ["update_pause_v1", "launch_recovery_v1"]
    var bootId = SystemClock.bootID
    var checkedUptime = SystemClock.seconds
    var pid = getpid()
}

func publish(_ state: String, _ message: String, pending: [String], surge: GateSurgeIdentity? = nil, update: GateUpdate? = nil,
             pendingLaunch: GatePendingLaunch? = nil) throws {
    try UserPaths.write(try JSON.encode(GateStatus(state: state, message: message, pending: pending, surge: surge, update: update,
                                                 pendingLaunch: pendingLaunch)), to: UserPaths.status)
}

func readStatus() throws -> (status: GateStatus, running: Bool, fresh: Bool, servicePID: Int32?) {
    let service = try Command.run("/bin/launchctl", ["print", "gui/\(getuid())/\(UserPaths.label)"])
    let pid = try StatusReport.servicePID(service)
    let running = pid != nil
    do {
        guard let data = try UserPaths.readPrivate(UserPaths.status, maximumBytes: GateSession.maximumBytes) else {
            return (GateStatus(state: running ? "waiting" : "stopped", message: running ? "Initializing" : "Service is not running", pending: []), running, false, pid)
        }
        let status = try JSON.decode(GateStatus.self, from: data)
        let fresh = pid == status.pid && !status.bootId.isEmpty && status.bootId == SystemClock.bootID && SystemClock.seconds >= status.checkedUptime &&
            SystemClock.seconds - status.checkedUptime < 15
        return (status, running, fresh, pid)
    } catch {
        return (GateStatus(state: "unknown", message: "Status unavailable: \(error)", pending: []), running, false, pid)
    }
}

func updateMode(paused: Bool) throws {
    let fd = try lock("request.lock")
    let update = GateUpdate(paused: paused)
    do {
        defer { close(fd) }
        let previous = try readStatus()
        guard previous.fresh, !["shutting_down", "shutdown_requested"].contains(previous.status.state),
              try GateShutdownRequest.load() == nil else {
            throw GuardError("SurgeGate must be running with fresh status and no ordered shutdown")
        }
        try UserPaths.write(try JSON.encode(update), to: GateUpdate.path)
    }
    let deadline = SystemClock.seconds + 20
    while SystemClock.seconds < deadline {
        let report = try readStatus()
        if update.acknowledged(by: report.status.update, state: report.status.state, fresh: report.fresh) {
            print(paused ? "SurgeGate confirmed update pause. Finish or cancel the official update before resuming. Guard/PF were not changed." :
                "SurgeGate confirmed automatic recovery enabled. Network readiness: \(StatusReport.read().state).")
            return
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    throw GuardError("Update mode saved but not acknowledged within 20s; do not start updating yet. Inspect Gate status/logs. The saved mode remains in effect.")
}

func lock(_ name: String, timeout: TimeInterval = 0) throws -> Int32 {
    try UserPaths.lock(at: UserPaths.directory + "/" + name, timeout: timeout)
}

func saveSession(_ config: GateConfiguration, pending: [String], preserveSavedApps: Bool = false) throws {
    let existing = preserveSavedApps ? try GateSession.load().apps : []
    let excluded = Set(config.excludedApps + ["com.apple.finder", "com.nssurge.surge-mac"])
    let apps = Array(Set(try appIDs(config) + existing)).filter { !excluded.contains($0) }.sorted()
    try UserPaths.write(try GateSession(apps: apps, pending: pending).encoded(), to: UserPaths.session)
}

let shutdownPath = GateShutdownRequest.path

func shutdown(_ action: String, config: GateConfiguration, pending: [String], preserveSavedApps: Bool = false) throws {
    guard ["restart", "shutdown"].contains(action) else { throw GuardError("Invalid shutdown action") }
    guard ["allowed", "blocked"].contains(StatusReport.read().state) else {
        throw GuardError("System guard state is not verified; no applications were asked to quit")
    }
    try saveSession(config, pending: pending, preserveSavedApps: preserveSavedApps)
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
    try UserPaths.write(try GateSession(apps: saved.apps, pending: pending).encoded(), to: UserPaths.session)
    var lastMessage = ""
    var lastGuardState: String?
    var lastSnapshot: Double = 0
    var nextLaunch: Double = 0
    var surgeRetry = GateRetry()
    var lastUpdate: GateUpdate?
    var acknowledgedPause: UUID?
    var shutdownPhase = GateShutdownPhase.idle
    var shutdownFailure: String?
    event("gate_started", "Waiting for fresh verified system guard status")
    while true {
        do {
            let config = try GateConfiguration.load()
            let update = try GateUpdate.load()
            if update != lastUpdate {
                surgeRetry = GateRetry()
                lastUpdate = update
                if let update {
                    event(update.paused ? "update_pause_requested" : "update_resume_requested",
                          update.paused ? "Update pause requested; waiting for in-flight operations to settle" : "Automatic recovery requested; awaiting service confirmation",
                          details: ["request_id": update.id.uuidString])
                }
            }
            var launchState = try pendingLaunchState()
            if let settled = launchState, settled.disposition == .settled || settled.disposition == .failed {
                try settled.request.complete()
                if settled.disposition == .failed {
                    let message = "Earlier launcher exited without verified application startup; retrying no earlier than 30 seconds"
                    if settled.request.app == "com.nssurge.surge-mac" { surgeRetry.failed(message, at: SystemClock.seconds) }
                    else { nextLaunch = SystemClock.seconds + 30 }
                    event("launch_failed_after_restart", message, app: settled.request.app)
                }
                launchState = nil
            }
            // Submission and consumption share a short lock; command waiters do not hold it.
            let requestLock = try lock("request.lock")
            var request: GateShutdownRequest?
            let preserve = shutdownPhase.preservesSession
            do {
                defer { close(requestLock) }
                // Recovery may have cleared the observed marker before we obtained this lock.
                guard try GatePendingLaunch.observationIsCurrent(launchState?.request) else { continue }
                request = try GateShutdownRequest.load()
                if let queued = request {
                    try queued.withdraw()
                    do {
                        try GateShutdownRequest.validate(paused: GateUpdate.load()?.paused == true,
                                                         pendingLaunch: launchState?.request, phase: shutdownPhase)
                        try publish("shutting_down", "Waiting for applications to quit", pending: pending)
                    } catch {
                        request = nil
                        event("shutdown_declined", "\(error). No applications were asked to quit; this request was removed", level: "error",
                              details: ["request_id": queued.id.uuidString])
                    }
                }
            }
            if let unsettled = launchState {
                let orphaned = unsettled.disposition == .orphaned
                let message = orphaned ?
                    "Launch result unknown after Gate restart (\(unsettled.request.app)). Verify the old launch finished, failed or was cancelled, then run surge-gate recover-launch \(unsettled.request.id.uuidString) --confirm-settled. Absence or timeout alone does not prove cancellation." :
                    "An earlier launch is still in flight; update pause is not yet acknowledged. Waiting for callback, verified app startup or recorded launcher exit."
                try publish(orphaned ? "launch_recovery_required" : update?.paused == true ? "update_pausing" : "launch_pending",
                            message, pending: pending, update: update, pendingLaunch: unsettled.request)
                if message != lastMessage {
                    event(orphaned ? "launch_recovery_required" : "launch_pending", message, app: unsettled.request.app, level: "warning")
                    lastMessage = message
                }
                RunLoop.current.run(until: Date().addingTimeInterval(1))
                continue
            }
            if let request {
                shutdownFailure = nil
                shutdownPhase = .quitting
                do {
                    try shutdown(request.action, config: config, pending: pending, preserveSavedApps: preserve)
                    shutdownPhase = .submitted
                } catch {
                    shutdownPhase = .aborted
                    shutdownFailure = "\(error). Session retained; save documents and retry ordered shutdown, or restart SurgeGate to resume recovery"
                    event("shutdown_aborted", shutdownFailure!)
                }
            }
            if shutdownPhase.preservesSession {
                try publish(shutdownFailure == nil ? "shutdown_requested" : "error",
                            shutdownFailure ?? "macOS request submitted, completion is not confirmed. If cancelled, retry ordered shutdown or restart Gate to resume recovery; snapshots remain paused", pending: pending)
            } else if update?.paused == true {
                try publish("update_paused", update!.reason, pending: pending, surge: surgeIdentity(), update: update)
                if acknowledgedPause != update!.id {
                    event("update_paused", update!.reason)
                    acknowledgedPause = update!.id
                }
            } else {
                pending.removeAll { config.excludedApps.contains($0) }
                var identity = surgeIdentity()
                var waitingForIdentity = false
                let needsSurge = identity.pid == nil || identity.reason == "surge_egress_identity_mismatch"
                if !needsSurge, identity.verified || identity.reason == "dedicated_group_not_required" {
                    surgeRetry.succeeded(at: SystemClock.seconds, launched: false)
                }
                if needsSurge, surgeRetry.canAttempt(at: SystemClock.seconds) {
                    do {
                        let result = try ensureSurge(quitTimeout: config.quitTimeoutSeconds)
                        waitingForIdentity = result == .waitingForBlock
                        surgeRetry.succeeded(at: SystemClock.seconds, launched: result == .launched)
                        if result == .launched {
                            event("surge_launch_requested", "Surge identity/startup verified; still waiting for enhanced mode and policy")
                        }
                    } catch {
                        surgeRetry.failed(String(describing: error), at: SystemClock.seconds)
                        event("surge_recovery_failed", "\(error). Retrying no earlier than 30 seconds")
                    }
                    identity = surgeIdentity()
                }
                // A pause arriving during a bounded operation is acknowledged only after that operation settles.
                if try GateUpdate.load()?.paused == true || GatePendingLaunch.load() != nil { continue }
                // Identity checks can outlive a status snapshot; read authorization immediately before restoring apps.
                var status = StatusReport.read()
                if status.state == "allowed", status.firewallVerified, let target = pending.first, SystemClock.seconds >= nextLaunch {
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
                    status = StatusReport.read()
                }
                let state = surgeRetry.failure != nil ? "recovery_failed" : waitingForIdentity ? "waiting_identity" :
                    status.state == "unknown" ? "unknown" : status.state == "allowed" ? (pending.isEmpty ? "ready" : "restoring") : "waiting"
                let message = surgeRetry.failure.map { "\($0); next attempt in \(max(0, Int(ceil(surgeRetry.nextAttempt - SystemClock.seconds))))s" } ??
                    (waitingForIdentity ? "Waiting for verified blocking before correcting Surge's egress identity" :
                        status.state == "allowed" ? "\(pending.count) application(s) pending" : "\(status.state): \(status.reason)")
                try publish(state, message, pending: pending, surge: identity, update: update)
                if message != lastMessage, surgeRetry.failure == nil {
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
