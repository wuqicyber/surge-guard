import Foundation
import Darwin
import SystemConfiguration
import SurgeGuardCore

func log(_ message: String) {
    NSLog("surge-guard: %@", message)
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

    init() throws {
        lock = try RuntimeLock()
        try RootFiles.verify(Policy.anchorPath)
        try firewall.block()
    }

    func reconcile() {
        do {
            firewall.rememberAddresses()
            if try !firewall.unchanged() {
                allowed = false
                try firewall.block()
                log("PF changed; blocking before rechecking Surge")
            }
            let observation: Readiness?
            do { observation = try Probe.readiness() }
            catch { observation = nil }
            let ready = observation?.ready == true
            if ready != allowed {
                if ready { try firewall.allow() }
                else { try firewall.block() }
                allowed = ready
            }
            let reason = ready ? "ALLOWED: Surge Enhanced Mode is ready" :
                "BLOCKED: " + (observation?.reasons.joined(separator: "; ") ?? "readiness probe failed")
            if reason != lastReason { log(reason); lastReason = reason }
        } catch {
            log("ERROR: \(error). Attempting block, then exiting for launchd restart.")
            do { try firewall.block() } catch { log("CRITICAL: cannot verify blocking: \(error)") }
            exit(1)
        }
    }

    func run() throws {
        var context = SCDynamicStoreContext(version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        store = SCDynamicStoreCreate(nil, "surge-guard.events" as CFString, { _, _, info in
            guard let info else { return }
            Unmanaged<Daemon>.fromOpaque(info).takeUnretainedValue().reconcile()
        }, &context)
        guard let store,
              SCDynamicStoreSetNotificationKeys(store,
                ["State:/Network/Global/IPv4"] as CFArray,
                ["State:/Network/Service/.*/IPv[46]", "State:/Network/Service/.*/VPN"] as CFArray),
              let source = SCDynamicStoreCreateRunLoopSource(nil, store, 0) else {
            throw GuardError("Cannot subscribe to network state changes")
        }
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        // ponytail: 0.5 s periodic checks cover process death and missed events;
        // this userspace gate is not an atomic or zero-leak kill switch.
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
        reconcile()
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
    fputs("surge-guard: \(error)\n", stderr)
    exit(1)
}
