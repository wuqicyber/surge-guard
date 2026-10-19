import Foundation
import SurgeGuardCore

// Standalone checks also work with Command Line Tools, where XCTest may not
// be installed. Throw on failure so checks still work in optimized builds.
func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw GuardError(message) }
}

func rejects(_ operation: () throws -> Void) throws {
    do { try operation() } catch { return }
    throw GuardError("Expected rejection")
}

do {
    for mask in 0..<64 {
        let state = Readiness(trustedProcess: mask & 1 != 0,
                              surgeService: mask & 2 != 0, connected: mask & 4 != 0,
                              vifUp: mask & 8 != 0, ownsDefaultRoute: mask & 16 != 0,
                              ipv6Safe: mask & 32 != 0)
        try check(state.ready == (mask == 63), "Incorrect readiness for mask \(mask)")
        try check(state.reasons.isEmpty == (mask == 63), "Missing failure reason")
    }
    print("PASS: all 64 readiness combinations")

    let routeCheck = RouteCheck(url: "https://example.com", requiredGroup: "Residential", allowedFinalPolicies: ["Node A", "Node B"])
    let routeConfig = Configuration(version: 1, mode: "routes", routeChecks: [routeCheck])
    try routeConfig.validate()
    let roundTrip = try Configuration.decode(Data(JSON.encode(routeConfig).utf8))
    try check(roundTrip == routeConfig, "Configuration JSON round trip failed")
    try check(try roundTrip.fingerprint() == routeConfig.fingerprint(), "Identical policies have different query fingerprints")
    try check(try Configuration.enhanced.fingerprint() != routeConfig.fingerprint(), "Rule result cannot be bound to a different policy")
    for invalid in [Configuration(version: 1, mode: "routes", routeChecks: []),
                    Configuration(version: 1, mode: "enhanced", routeChecks: [routeCheck]),
                    Configuration(version: 2, mode: "enhanced", routeChecks: []),
                    Configuration(version: 1, mode: "routes", routeChecks: [routeCheck, routeCheck]),
                    Configuration(version: 1, mode: "routes", routeChecks: [RouteCheck(url: "https://user:secret@example.com", requiredGroup: "Residential", allowedFinalPolicies: ["Node A"])]),
                    Configuration(version: 1, mode: "routes", routeChecks: [RouteCheck(url: "https://example.com", requiredGroup: "Residential", allowedFinalPolicies: ["DIRECT"])])] {
        try rejects { try invalid.validate() }
    }
    try rejects { _ = try Configuration.decode(Data("{\"version\":1,\"mode\":\"enhanced\",\"route_checks\":[],\"typo\":true}".utf8)) }
    print("PASS: policy validation, credentials, duplicate checks and unknown fields")

    let explanation: [String: Any] = ["rule-policy": "Residential", "final": "Node A", "final-type": "Shadowsocks",
                                      "steps": [["group": "Residential", "selected": "Nested"], ["group": "Nested", "selected": "Node A"]]]
    func route(_ object: [String: Any]) throws -> RouteResult {
        try RouteResult.evaluate(JSONSerialization.data(withJSONObject: object), check: routeCheck)
    }
    let matching = try route(explanation)
    try check(matching.ready, "Nested allowed proxy rejected")
    var different = explanation
    different["final"] = "Node C"
    try check(!(try route(different)).ready, "Unlisted node accepted")
    different = explanation; different["rule-policy"] = "Other"
    try check(!(try route(different)).ready, "Wrong rule group accepted")
    different = explanation; different["steps"] = []
    try check(!(try route(different)).ready, "Unresolved group accepted")
    different = explanation; different["final-type"] = "DIRECT"
    try check(!(try route(different)).ready, "Built-in direct type accepted")
    different = explanation; different.removeValue(forKey: "final-type")
    try rejects { _ = try route(different) }
    try rejects { _ = try RouteResult.evaluate(Data("not-json".utf8), check: routeCheck) }
    print("PASS: nested routing, unlisted/direct targets and malformed CLI responses")

    var snapshot = GuardSnapshot(runId: "test", firewallVerifiedUptime: 100, allowed: true,
                                 configurationMode: "routes", readiness: nil, session: nil, reasons: [])
    snapshot.bootId = "boot-a"; snapshot.checkedUptime = 100
    try check(snapshot.fresh(boot: "boot-a", now: 101), "Fresh status rejected")
    try check(!snapshot.fresh(boot: "boot-b", now: 101), "Previous boot status accepted")
    try check(!snapshot.fresh(boot: "boot-a", now: 110), "Expired status accepted")
    try check(!snapshot.fresh(boot: "boot-a", now: 99), "Future status accepted")
    snapshot.firewallVerifiedUptime = 90
    try check(!snapshot.fresh(boot: "boot-a", now: 101), "Expired PF audit accepted")
    let statusData = try JSON.encode(snapshot)
    let decoded = try JSON.decode(GuardSnapshot.self, from: Data(statusData.utf8))
    try check(decoded.bootId == snapshot.bootId, "Status schema did not round trip")
    print("PASS: boot-bound monotonic status/PF freshness")

    var gate = GateConfiguration.standard
    gate.startupApps = ["com.example.B", "com.example.A"]
    gate.priorityOrder = ["com.example.C", "com.example.A"]
    gate.excludedApps = ["com.example.D"]
    try gate.validate()
    try check(gate.targets(saved: ["com.example.C", "com.example.B", "com.example.D", "com.apple.finder", "com.nssurge.surge-mac"]) == ["com.example.C", "com.example.A", "com.example.B"], "Gate order, deduplication or exclusions failed")
    gate.restoreSession = false
    try check(gate.targets(saved: ["com.example.C"]) == ["com.example.A", "com.example.B"], "Disabled session restoration ignored")
    gate.startupApps = ["Terminal"]
    try rejects { try gate.validate() }
    print("PASS: portable app IDs, launch order, exclusions and session opt-out")
    let checkpoint = GateSession(apps: ["com.example.A"], pending: ["com.example.Missing"])
    let restored = try GateSession.decode(Data(JSON.encode(checkpoint).utf8))
    try check(restored.apps == checkpoint.apps && restored.pending == checkpoint.pending, "Pending recovery lost in checkpoint")
    try rejects { _ = try GateSession.decode(Data("{}".utf8)) }
    try rejects { _ = try GateSession.decode(Data("{\"apps\":[\"Terminal\"],\"pending\":[],\"saved_at\":0}".utf8)) }
    print("PASS: session round trip preserves pending apps; corrupt session is rejected")
    let logRecord: [String: Any] = ["time": "2026-01-01T00:00:00Z", "level": "warning", "event": "gate_changed", "pid": 123,
                                    "message": "route_policy_mismatch", "details": ["pf": "blocked", "routes": [["url": "https://example.com", "ready": false, "expected_group": "Residential", "actual_group": "Other", "final_policy": "Node C"]]]]
    let logLine = String(decoding: try JSONSerialization.data(withJSONObject: logRecord), as: UTF8.self)
    let readable = LogReader.format(logLine)
    try check(readable.contains("BLOCKED") && readable.contains("Residential") && readable.contains("Other") && readable.contains("Node C"), "Readable log omitted decision context")
    let machine = try JSONSerialization.jsonObject(with: Data(LogReader.format(logLine, json: true).utf8)) as? [String: Any]
    try check(machine?["event"] as? String == "gate_changed", "Machine log lost event fields")
    try check(LogReader.format("legacy event") == "legacy event", "Legacy logs became unreadable")
    _ = try JSONSerialization.jsonObject(with: Data(LogReader.format("legacy event", json: true).utf8))
    let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("surge-guard-log-test-" + UUID().uuidString)
    do {
        try (logLine + "\nlegacy record without trailing newline").write(to: logURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: logURL) }
        try LogReader.show(path: logURL.path, follow: false, json: false)
    }
    print("PASS: readable decision logs, machine JSON and legacy records")

    let config = """
    # Existing configuration
    set skip on lo0
    scrub-anchor "com.apple/*"
    nat-anchor "com.apple/*"
    anchor "com.apple/*"
    load anchor "com.apple" from "/etc/pf.anchors/com.apple"
    # User comment must survive

    """
    let installed = try Policy.attaching(to: config)
    let reinstalled = try Policy.attaching(to: installed)
    let removed = try Policy.removingAttachment(from: installed)
    try check(installed == reinstalled, "Installation must be idempotent")
    try check(removed == config, "Removal must preserve original configuration")
    try check(installed.range(of: Policy.attachment)!.lowerBound <
              installed.range(of: "\nanchor \"com.apple/*\"")!.lowerBound, "Wrong anchor order")
    print("PASS: PF configuration installation/removal round trip")

    for invalid in ["", Policy.begin, Policy.end,
                    "anchor \"com.apple/*\"\nanchor \"com.apple/*\"\n",
                    "# io.github.surge-guard\nanchor \"com.apple/*\"\n"] {
        try rejects { _ = try Policy.attaching(to: invalid) }
    }
    let modified = Policy.configBlock.replacingOccurrences(of: Policy.end, with: "pass quick all\n" + Policy.end)
    try rejects { _ = try Policy.removingAttachment(from: modified) }
    try rejects { _ = try Policy.removingAttachment(from: Policy.configBlock + Policy.configBlock) }
    print("PASS: malformed/edited PF configuration is rejected")

    try check(Policy.attachedFirst(Policy.attachment + " all\nanchor \"com.apple/*\" all\n"), "Valid attachment rejected")
    let liveMacRules = "scrub-anchor \"com.apple/*\" all fragment reassemble\n" + Policy.attachment + " all\nanchor \"com.apple/*\" all\n"
    try check(Policy.attachedFirst(liveMacRules), "macOS normalization rule mistaken for a filter")
    try check(!Policy.attachedFirst("scrub-anchor \"com.apple/*\" all\npass quick all\n" + Policy.attachment + " all\n"), "Filter before guard accepted after normalization")
    for invalid in ["pass quick all\n" + Policy.attachment + " all\n",
                    "anchor \"com.apple/*\" all\n" + Policy.attachment + " all\n",
                    "anchor \"io.github.surge-guard-impostor\" all\n", ""] {
        try check(!Policy.attachedFirst(invalid), "Unsafe filter ordering accepted")
    }
    print("PASS: live PF attachment order")

    try check(Policy.defaultInterface("route to: default\n  interface: utun108\n") == "utun108", "Dynamic utun parsing failed")
    try check(Policy.defaultInterface("   interface: en0\n") == "en0", "Physical interface parsing failed")
    try check(Policy.defaultInterface("route: not in table") == nil, "Missing route accepted")
    try check(Policy.defaultInterface("interface: utun9 extra") == nil, "Malformed route accepted")
    print("PASS: route parser")

    try check(Policy.ipv6Safe(primaryInterface: nil, surgeInterface: "utun9"), "Missing global IPv6 route must be safe")
    try check(Policy.ipv6Safe(primaryInterface: "utun9", surgeInterface: "utun9"), "Surge IPv6 route rejected")
    try check(!Policy.ipv6Safe(primaryInterface: "en0", surgeInterface: "utun9"), "Physical IPv6 route accepted")
    try check(!Policy.ipv6Safe(primaryInterface: "", surgeInterface: "utun9"), "Malformed IPv6 state accepted")
    print("PASS: IPv6 safety gate")

    // -n is parse-only; never enable PF or touch live rules/state in tests.
    let parser = try Command.run("/sbin/pfctl", ["-n", "-a", Policy.anchor, "-f", "-"], input: Policy.blocked)
    try check(parser.status == 0, "PF parser rejected policy: \(parser.combined)")
    print("PASS: native macOS PF parser")

    var started = Date()
    do {
        _ = try Command.run("/bin/sleep", ["5"], timeout: 0.05)
        throw GuardError("Expected timeout")
    } catch {
        try check(String(describing: error).contains("/bin/sleep 5 timed out"), "Timeout omitted command context")
    }
    try check(Date().timeIntervalSince(started) < 2, "Timeout did not terminate child")
    started = Date()
    try rejects { _ = try Command.run("/usr/bin/yes", [], timeout: 0.1) }
    try check(Date().timeIntervalSince(started) < 2, "Full pipe defeated timeout")
    print("PASS: timeout and output backpressure")

    try rejects { _ = try Command.checked("/usr/bin/false", []) }
    let literal = try Command.run("/usr/bin/printf", ["%s", "literal $(not-a-command)"])
    try check(literal.output == "literal $(not-a-command)", "Unexpected shell evaluation")
    // Constant test command only: exercise real stderr/stdout separation.
    let streams = try Command.run("/bin/sh", ["-c", "printf 'rules'; printf 'ALTQ warning' >&2"])
    try check(streams.output == "rules" && streams.diagnostics == "ALTQ warning", "Diagnostics contaminated structured output")
    print("PASS: command errors and literal arguments")
    // Read-only regression for the group-writable /var/run found on macOS.
    try check(!Paths.runtime.hasPrefix("/var/run/"), "Runtime state must not depend on a non-writable /var/run")
    try RootFiles.verify(URL(fileURLWithPath: Paths.runtime).deletingLastPathComponent().path, directory: true)
    print("PASS: protected runtime parent")
    print("All checks passed. Live packet blocking has NOT been tested by this program.")
} catch {
    fputs("FAIL: \(error)\n", stderr)
    exit(1)
}
