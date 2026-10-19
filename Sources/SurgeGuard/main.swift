import Foundation
import Darwin
import SystemConfiguration
import SurgeGuardCore

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
    var surgeExitDetectedAt: Double?
    var nextSurgeSearch: Double = 0
    var nextFirewallAudit: Double = 0
    let runID = UUID().uuidString
    var firewallVerified: Double = 0
    var configuration: Configuration?
    var session: SessionObservation?
    var sessionChecked: Double = 0
    var nextSessionProbe: Double = 0
    var sessionFailure = "rule_probe_pending"
    var probing = false
    var generation = 0
    var nextPublish: Double = 0
    var lastProbeError = ""
    var lastRoutes = ""
    var egressSampling = false
    var nextEgressSample: Double = 0
    var nextEgressSummary: Double = 0
    var egressHistory = EgressHistory()
    var egressFailure = ""

    init() throws {
        lock = try RuntimeLock()
        try RootFiles.preparePublicState()
        try RootFiles.verify(Policy.anchorPath)
        try firewall.prepareAttachment()
        try firewall.block()
        firewallVerified = SystemClock.seconds
        EventLog.write("daemon_started", message: "Blocked before checking Surge", details: ["run_id": runID])
    }

    func surgeProcessTrusted() throws -> Bool {
        if let pid = trustedSurgePID, kill(pid, 0) == 0 { return true }
        trustedSurgePID = nil
        surgeExitSource?.cancel()
        surgeExitSource = nil

        let now = SystemClock.seconds
        guard now >= nextSurgeSearch else { return false }
        nextSurgeSearch = now + 1
        guard let pid = try Probe.trustedSurgePID() else { return false }

        let exitSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        exitSource.setEventHandler { [weak self] in
            guard let self, self.trustedSurgePID == pid else { return }
            self.surgeExitDetectedAt = SystemClock.seconds
            self.trustedSurgePID = nil
            self.surgeExitSource?.cancel()
            self.surgeExitSource = nil
            self.nextSurgeSearch = 0
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

    func updateSession(_ config: Configuration, force: Bool) {
        let now = SystemClock.seconds
        if force {
            generation += 1
            session = nil
            sessionChecked = 0
            nextSessionProbe = 0
            sessionFailure = "rule_probe_pending"
        }
        guard !probing, now >= nextSessionProbe else { return }
        probing = true
        nextSessionProbe = now + 1
        let requestedGeneration = generation
        let started = now
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try Probe.privilegedSession(configuration: config) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.probing = false
                guard self.generation == requestedGeneration else { return }
                self.sessionChecked = started
                switch result {
                case .success(let observation):
                    let bound = observation.routes.count == config.routeChecks.count && zip(observation.routes, config.routeChecks).allSatisfy {
                        $0.url == $1.url && $0.expectedGroup == $1.requiredGroup &&
                            (!$0.ready || ($0.actualGroup == $1.requiredGroup && $1.allowsFinalPolicy($0.finalPolicy)))
                    }
                    self.session = bound ? observation : nil
                    self.sessionFailure = bound ? "" : "rule_probe_configuration_changed"
                case .failure(let error):
                    self.session = nil
                    self.sessionFailure = "rule_probe_failed: \(error)"
                }
                if self.session == nil && self.sessionFailure != self.lastProbeError {
                    EventLog.write("rule_probe_failed", level: "warning", message: self.sessionFailure,
                                   details: ["duration_ms": String(Int((SystemClock.seconds - started) * 1000)), "run_id": self.runID])
                }
                self.lastProbeError = self.session == nil ? self.sessionFailure : ""
                if let session = self.session, let routes = try? JSON.encode(session.routes), routes != self.lastRoutes {
                    EventLog.write("route_decision_changed", message: "Surge rule decision updated",
                                   details: ["routes": (try? JSONSerialization.jsonObject(with: Data(routes.utf8))) ?? [],
                                             "outbound_mode": session.mode, "run_id": self.runID])
                    self.lastRoutes = routes
                }
                self.reconcile()
            }
        }
    }

    func reconcile(forceFirewallAudit: Bool = false) {
        defer { surgeExitDetectedAt = nil }
        do {
            firewall.rememberAddresses()
            let now = SystemClock.seconds
            if forceFirewallAudit || now >= nextFirewallAudit {
                nextFirewallAudit = now + 5
                if try !firewall.unchanged() {
                    allowed = false
                    try firewall.block()
                    EventLog.write("pf_reconciled", level: "warning", message: "Blocking before rechecking Surge", details: ["run_id": runID])
                }
                firewallVerified = SystemClock.seconds
            }
            let observation: Readiness?
            var probeFailure: String?
            do { observation = try Probe.readiness(trustedProcess: surgeProcessTrusted()) }
            catch { observation = nil; probeFailure = String(describing: error) }
            var reasons = observation?.reasons ?? ["readiness_probe_failed: \(probeFailure ?? "unknown error")"]
            var config: Configuration?
            do {
                config = try Configuration.load()
                if configuration != config {
                    generation += 1
                    session = nil
                    sessionChecked = 0
                    nextSessionProbe = 0
                    sessionFailure = "rule_probe_pending"
                    configuration = config
                    EventLog.write("configuration_loaded", message: "Validated policy configuration", details: ["mode": config!.mode, "run_id": runID])
                }
            } catch {
                reasons.append("configuration_invalid: \(error)")
                configuration = nil
                generation += 1
                session = nil
            }
            if config?.mode == "routes" {
                if observation?.ready == true, let config { updateSession(config, force: forceFirewallAudit) }
                else { generation += 1; session = nil; sessionChecked = 0 }
                if SystemClock.seconds - sessionChecked >= 3 || session == nil {
                    reasons.append(sessionFailure.isEmpty ? "rule_probe_expired" : sessionFailure)
                } else if let session {
                    if session.mode != "rule" { reasons.append("outbound_mode_is_\(session.mode)") }
                    if !session.enhancedMode { reasons.append("enhanced_mode_disabled") }
                    for route in session.routes where !route.ready { reasons.append("\(route.reason): \(route.url)") }
                    if session.routes.count != config?.routeChecks.count { reasons.append("incomplete_route_results") }
                }
            }
            let ready = reasons.isEmpty && observation?.ready == true && config != nil
            if ready != allowed {
                if ready { try firewall.allow() }
                else { try firewall.block() }
                allowed = ready
                firewallVerified = SystemClock.seconds
            }
            let reason = ready ? "allowed" : reasons.joined(separator: "; ")
            if reason != lastReason || SystemClock.seconds >= nextPublish {
                let snapshot = GuardSnapshot(runId: runID, firewallVerifiedUptime: firewallVerified, allowed: allowed,
                                             configurationMode: config?.mode ?? "invalid", readiness: observation, session: session, reasons: reasons)
                try RootFiles.write(try JSON.encode(snapshot), to: Paths.snapshot, mode: 0o644)
                nextPublish = SystemClock.seconds + 1
            }
            if reason != lastReason {
                var details: [String: Any] = ["run_id": runID, "mode": config?.mode ?? "invalid", "pf": ready ? "allowed" : "blocked"]
                if !ready, let detected = surgeExitDetectedAt {
                    details["surge_exit_event_uptime"] = detected
                    details["block_verified_uptime"] = firewallVerified
                    details["exit_event_to_block_verified_ms"] = max(0, (firewallVerified - detected) * 1000)
                }
                if let session, let encoded = try? JSON.encode(session.routes) {
                    details["routes"] = try? JSONSerialization.jsonObject(with: Data(encoded.utf8))
                }
                EventLog.write("gate_changed", level: ready ? "info" : "warning", message: reason, details: details)
                lastReason = reason
            }
        } catch {
            EventLog.write("reconciliation_failed", level: "error", message: "\(error). Blocking before launchd restart", details: ["run_id": runID])
            do { try firewall.block(); EventLog.write("fail_closed", message: "Block rules verified before restart") }
            catch { EventLog.write("pf_unverified", level: "critical", message: "Cannot verify blocking: \(error)") }
            try? FileManager.default.removeItem(atPath: Paths.snapshot)
            exit(1)
        }
    }

    func observeEgress() {
        let now = SystemClock.seconds
        guard !egressSampling, now >= nextEgressSample else { return }
        egressSampling = true
        nextEgressSample = now + 30
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try EgressObservation.collect() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.egressSampling = false
                switch result {
                case .failure(let error):
                    let reason = String(describing: error)
                    if reason != self.egressFailure {
                        EventLog.write("egress_observation_failed", level: "warning", message: reason,
                                       details: ["run_id": self.runID, "impact": "egress_observation_unavailable; firewall_policy_unchanged"])
                    }
                    self.egressFailure = reason
                case .success(let sample):
                    let now = SystemClock.seconds
                    if !self.egressFailure.isEmpty {
                        EventLog.write("egress_observation_recovered", message: "Passive egress sampling recovered", details: ["run_id": self.runID])
                    }
                    self.egressFailure = ""
                    let flows = self.egressHistory.newActivity(sample.flows, now: now)
                    for category in ["public_application", "system_extension", "local_or_unresolved"] {
                        let selected = flows.filter {
                            let categoryOfFlow = $0.processKind == "system_extension" ? "system_extension" :
                                ($0.destinationScope == "public" ? "public_application" : "local_or_unresolved")
                            return categoryOfFlow == category
                        }
                        guard !selected.isEmpty else { continue }
                        var evidence = sample; evidence.flows = selected
                        if var details = (try? JSON.encode(evidence)).flatMap({ try? JSONSerialization.jsonObject(with: Data($0.utf8)) }) as? [String: Any] {
                            details["run_id"] = self.runID
                            details["guard_state_at_log"] = self.allowed ? "allowed" : "blocked"
                            details["total_observed_flows"] = sample.flows.count
                            details["category"] = category
                            EventLog.write("egress_path_observed", level: category == "public_application" ? "warning" : "info",
                                           message: "Socket activity on an interface other than Surge VIF; inspect destination and network role", details: details)
                        }
                    }
                    if now >= self.nextEgressSummary {
                        self.nextEgressSummary = now + 300
                        EventLog.write("egress_observation_summary", message: "Sampling is active; absence of findings is not proof of no bypass",
                                       details: ["run_id": self.runID, "sample_interval_seconds": 30, "sample_seconds": sample.sampleSeconds,
                                                 "observed_flows": sample.flows.count, "unresolved_active_sockets": sample.unresolvedActiveSockets,
                                                 "unattributed_active_sockets": sample.unattributedActiveSockets, "unmeasured_sockets": sample.unmeasuredSockets,
                                                 "scope": sample.scope])
                    }
                }
            }
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
        // Network/process events are primary; a 0.5 s fallback covers
        // missed readiness events, while PF integrity is audited every 5 s.
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.reconcile()
            self?.observeEgress()
        }
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let handler = DispatchSource.makeSignalSource(signal: number, queue: .main)
            handler.setEventHandler { [weak self] in
                do {
                    try self?.firewall.block()
                    try? FileManager.default.removeItem(atPath: Paths.snapshot)
                    EventLog.write("daemon_stopped", message: "Leaving blocked rules installed")
                }
                catch { EventLog.write("pf_unverified", level: "critical", message: "Block on shutdown failed: \(error)"); exit(1) }
                exit(0)
            }
            handler.resume()
            signals.append(handler)
        }
        reconcile(forceFirewallAudit: true)
        CFRunLoopRun()
    }
}

do {
    try CLI.run(Array(CommandLine.arguments.dropFirst()))
} catch {
    EventLog.write("command_failed", level: "error", message: String(describing: error))
    if CommandLine.arguments.contains("--json") {
        struct Failure: Encodable { let ready = false; let error: String }
        print((try? JSON.encode(Failure(error: String(describing: error)))) ?? "{}")
    } else { fputs("surge-guard: \(error)\n", stderr) }
    exit(1)
}
