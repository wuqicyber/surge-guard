import Foundation
import Darwin
import SystemConfiguration
import SurgeGuardCore

func log(_ message: String) {
    NSLog("surge-guard: %@", message)
    guard geteuid() == 0 else { return }
    do {
        try RootFiles.prepareRuntime()
        if FileManager.default.fileExists(atPath: Paths.eventsLog) {
            try RootFiles.verify(Paths.eventsLog)
            let size = (try FileManager.default.attributesOfItem(atPath: Paths.eventsLog)[.size] as? NSNumber)?.intValue ?? 0
            if size >= 1_048_576 {
                let rotated = Paths.eventsLog + ".1"
                if FileManager.default.fileExists(atPath: rotated) {
                    try RootFiles.verify(rotated)
                    try FileManager.default.removeItem(atPath: rotated)
                }
                try FileManager.default.moveItem(atPath: Paths.eventsLog, toPath: rotated)
            }
        }
        let descriptor = open(Paths.eventsLog, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw GuardError("Cannot open private event log") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == 0,
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0 else {
            try handle.close()
            throw GuardError("Private event log has unsafe ownership or permissions")
        }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        try handle.write(contentsOf: Data("\(timestamp) \(message)\n".utf8))
        try handle.close()
    } catch {
        NSLog("surge-guard: LOGGING ERROR: %@", String(describing: error))
    }
}

final class Daemon {
    let firewall = Firewall()
    let lock: RuntimeLock
    var allowed = false
    var lastReason = ""
    var store: SCDynamicStore?
    var source: CFRunLoopSource?
    var timer: Timer?
    var signals: [DispatchSourceSignal] = []
    var trustedSurgePID: pid_t?
    var surgeExitSource: DispatchSourceProcess?
    var nextSurgeSearch = Date.distantPast
    var nextFirewallAudit = Date.distantPast

    init() throws {
        lock = try RuntimeLock()
        try RootFiles.verify(Policy.anchorPath)
        try firewall.prepareAttachment()
        try firewall.block()
    }

    func surgeProcessTrusted() throws -> Bool {
        if let pid = trustedSurgePID, kill(pid, 0) == 0 { return true }
        trustedSurgePID = nil
        surgeExitSource?.cancel()
        surgeExitSource = nil

        let now = Date()
        guard now >= nextSurgeSearch else { return false }
        nextSurgeSearch = now.addingTimeInterval(1)
        guard let pid = try Probe.trustedSurgePID() else { return false }

        let exitSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        exitSource.setEventHandler { [weak self] in
            guard let self, self.trustedSurgePID == pid else { return }
            self.trustedSurgePID = nil
            self.surgeExitSource?.cancel()
            self.surgeExitSource = nil
            self.nextSurgeSearch = .distantPast
            self.reconcile(forceFirewallAudit: true)
        }
        trustedSurgePID = pid
        surgeExitSource = exitSource
        exitSource.resume()
        guard kill(pid, 0) == 0 else {
            trustedSurgePID = nil
            surgeExitSource?.cancel()
            surgeExitSource = nil
            return false
        }
        return true
    }

    func reconcile(forceFirewallAudit: Bool = false) {
        do {
            firewall.rememberAddresses()
            let now = Date()
            if forceFirewallAudit || now >= nextFirewallAudit {
                nextFirewallAudit = now.addingTimeInterval(5)
                if try !firewall.unchanged() {
                    allowed = false
                    try firewall.block()
                    log("PF changed; blocking before rechecking Surge")
                }
            }
            let observation: Readiness?
            var probeFailure: String?
            do { observation = try Probe.readiness(trustedProcess: surgeProcessTrusted()) }
            catch { observation = nil; probeFailure = String(describing: error) }
            let ready = observation?.ready == true
            if ready != allowed {
                if ready { try firewall.allow() }
                else { try firewall.block() }
                allowed = ready
            }
            let reason = ready ? "ALLOWED: Surge Enhanced Mode is ready" :
                "BLOCKED: " + (observation?.reasons.joined(separator: "; ") ?? "readiness probe failed: \(probeFailure ?? "unknown error")")
            if reason != lastReason { log(reason); lastReason = reason }
        } catch {
            log("ERROR: \(error). Attempting block, then exiting for launchd restart.")
            do { try firewall.block(); log("FAIL-CLOSED: block rules verified before restart") }
            catch { log("CRITICAL: cannot verify blocking: \(error)") }
            exit(1)
        }
    }

    func run() throws {
        var context = SCDynamicStoreContext(version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        store = SCDynamicStoreCreate(nil, "surge-guard.events" as CFString, { _, _, info in
            guard let info else { return }
            Unmanaged<Daemon>.fromOpaque(info).takeUnretainedValue().reconcile(forceFirewallAudit: true)
        }, &context)
        guard let store,
              SCDynamicStoreSetNotificationKeys(store,
                ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] as CFArray,
                ["State:/Network/Service/.*/IPv[46]", "State:/Network/Service/.*/VPN"] as CFArray),
              let source = SCDynamicStoreCreateRunLoopSource(nil, store, 0) else {
            throw GuardError("Cannot subscribe to network state changes")
        }
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        // ponytail: network/process events are primary; a 0.5 s fallback covers
        // missed readiness events, while PF integrity is audited every 5 s.
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.reconcile() }
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let handler = DispatchSource.makeSignalSource(signal: number, queue: .main)
            handler.setEventHandler { [weak self] in
                do { try self?.firewall.block(); log("Service stopping; leaving blocked rules installed") }
                catch { log("CRITICAL: block on shutdown failed: \(error)"); exit(1) }
                exit(0)
            }
            handler.resume()
            signals.append(handler)
        }
        reconcile(forceFirewallAudit: true)
        CFRunLoopRun()
    }
}

let usage = """
Surge Guard (experimental) — macOS network gate for Surge Enhanced Mode

  surge-guard check          Read-only readiness check (exit 0 ready, 1 unavailable)
  surge-guard rules          Print blocked PF rules; does not apply them
  sudo surge-guard install   Install root-owned binary, boot service and default-block file
  sudo surge-guard start     Load the installed service (briefly interrupts connections)
  sudo surge-guard status    Inspect readiness, live PF rules and daemon registration
  sudo surge-guard unlock    Stop service and clear only its rules; re-arms at next boot/start
  sudo surge-guard uninstall Remove installed components, preserving other PF configuration

Requires macOS 13+ and Surge Mac Enhanced Mode (not Gateway VM).
Surge-ready permits existing routing/DIRECT behavior. Transition and early-boot
leak windows remain; this is not a zero-packet-leak or malware containment tool.
"""

do {
    guard CommandLine.arguments.count == 2 else { print(usage); exit(CommandLine.arguments.count == 1 ? 0 : 2) }
    let action = CommandLine.arguments[1]
    if ["help", "--help", "-h"].contains(action) { print(usage); exit(0) }
    if action == "rules" { print(Policy.blocked, terminator: ""); exit(0) }
    if action == "check" {
        let observation = try Probe.readiness()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(observation), as: UTF8.self))
        print(observation.ready ? "READY (Surge only; this does not prove PF protection)" : "NOT READY: " + observation.reasons.joined(separator: "; "))
        exit(observation.ready ? 0 : 1)
    }
    guard ["install", "start", "status", "run", "unlock", "uninstall"].contains(action) else {
        throw GuardError("Unknown command: \(action)")
    }
    guard geteuid() == 0 else { throw GuardError("This command requires sudo; check and rules are read-only") }
    switch action {
    case "install": try Admin.install()
    case "start": try Admin.start()
    case "unlock": try Admin.unlock()
    case "uninstall": try Admin.uninstall()
    case "status":
        let firewall = Firewall()
        print("Daemon loaded: \(try Admin.loaded())")
        print("PF enabled: \(try firewall.enabled())")
        print("Anchor first: \(try firewall.attached())")
        print("Surge ready: \((try? Probe.readiness().ready) == true)")
        print("Live anchor rules:\n\(try firewall.readRules())")
        print("Status is a snapshot; verify packet behavior with the documented acceptance tests.")
    case "run":
        let daemon = try Daemon()
        try daemon.run()
    default: break
    }
} catch {
    log("FATAL: \(error)")
    fputs("surge-guard: \(error)\n", stderr)
    exit(1)
}
