import Foundation
import SurgeGuardCore
import Darwin

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
    let egressHeader = ",interface,state,bytes_in,bytes_out,\n"
    let egressFirst = egressHeader + "Example.400,,,999,999,\ntcp4 192.168.1.2:5000<->1.1.1.1:443,en0,Established,999,999,\n"
    let egressDelta = egressHeader + "\"Example, Browser.400\",,,100,200,\n" +
        "tcp4 192.168.1.2:5000<->1.1.1.1:443,en0,Established,100,200,\n" +
        "tcp4 192.168.1.2:5001<->8.8.8.8:443,en0,Established,0,0,\n" +
        "tcp4 192.168.1.2:5002<->10.0.0.1:443,en0,Established,100,200,\n" +
        "tcp4 198.18.0.1:5003<->1.1.1.1:443,utun108,Established,100,200,\n" +
        "udp4 *:5004<->*:*,en0,,50,20,\n" +
        "tcp6 [2001:4860::1]:5005<->[2001:4860::8888]:443,en0,Established,30,40,\n" +
        "tcp6 2001:4860::1.5007<->2001:4860::8888.443,en0,Established,30,40,\n" +
        "udp4 *:*<->*:*,,,,,\n" +
        "tcp4 *:5008<->*:*,,Listen,,,\n" +
        "udp4 *:5009<->*:*,en0,,0,0,\n" +
        "udp4 *:5010<->*:*,en0,,1,0,\n" +
        "tcp4 192.168.1.2:5011<->1.1.1.1:443,,Established,1,2,\n" +
        "Surge.401,,,100,200,\ntcp4 192.168.1.2:5006<->1.0.0.1:443,en0,Established,100,200,\n"
    let observed = try EgressObservation.parse(egressFirst + egressDelta, surgeInterface: "utun108", surgePID: 401)
    try check(observed.flows.count == 6 && observed.flows.filter({ $0.destinationScope == "public" }).count == 3 &&
              observed.unresolvedActiveSockets == 2 && observed.unmeasuredSockets == 1 && observed.unattributedActiveSockets == 1,
              "Egress sample lost IPv4/IPv6/local/unknown activity or included Surge/idle sockets")
    try check(observed.flows[0].process == "Example, Browser" && observed.flows[0].sentBytes == 200,
              "Egress sample used lifetime totals or broke quoted process names")
    let transportNamedProcess = try EgressObservation.parse(egressFirst + egressDelta.replacingOccurrences(of: "Example, Browser.400", with: "tcp4 Client.400"),
                                                           surgeInterface: "utun108", surgePID: 401)
    try check(transportNamedProcess.flows.first?.process == "tcp4 Client", "Process name was mistaken for a socket row")
    let duplicateUDP = "udp4 *:5004<->*:*,en0,,50,20,\n"
    let reused = try EgressObservation.parse(egressFirst + egressDelta.replacingOccurrences(of: duplicateUDP, with: duplicateUDP + duplicateUDP),
                                            surgeInterface: "utun108", surgePID: 401)
    try check(reused.flows.first(where: { $0.localEndpoint == "*:5004" })?.sentBytes == 40,
              "Reused UDP tuple discarded activity or disabled the observer")
    let encodedEgress = try JSON.encode(observed)
    try check(try JSON.decode(EgressObservation.self, from: Data(encodedEgress.utf8)).flows == observed.flows, "Egress JSON did not round trip")
    for invalid in [egressFirst, egressHeader + egressHeader, egressFirst + egressDelta.replacingOccurrences(of: "100,200,\n", with: "bad,200,\n"),
                    egressFirst + egressDelta.replacingOccurrences(of: "Surge.401", with: "invalid-process"), egressFirst + "\"unterminated\n"] {
        try rejects { _ = try EgressObservation.parse(invalid, surgeInterface: "utun108", surgePID: 401) }
    }
    for address in ["10.0.0.1", "127.0.0.1", "169.254.1.1", "172.16.0.1", "192.168.1.1", "100.64.0.1", "198.18.1.1",
                    "192.0.2.1", "198.51.100.1", "203.0.113.1", "224.0.0.251", "::1", "fe80::1", "fd00::1", "ff02::1", "2001:db8::1", "not-an-ip"] {
        try check(!EgressObservation.isPublicAddress(address), "Non-public egress address was reported as public: \(address)")
    }
    for address in ["1.1.1.1", "8.8.8.8", "2001:4860::8888", "::ffff:1.1.1.1", "64:ff9b::101:101"] {
        try check(EgressObservation.isPublicAddress(address), "Public egress address was silently missed: \(address)")
    }
    var egressHistory = EgressHistory()
    try check(egressHistory.newActivity(observed.flows, now: 10).count == 6, "First egress evidence was suppressed")
    try check(egressHistory.newActivity(observed.flows, now: 11).isEmpty, "Unchanged egress flooded the event log")
    try check(egressHistory.newActivity(observed.flows, now: 310).count == 6, "Continued egress could never be recorded again")
    let churn = (1...25).map { index -> EgressFlow in var flow = observed.flows[0]; flow.pid = Int32(index); return flow }
    try check(egressHistory.newActivity(churn, now: 311).count == 20, "Egress batch did not bound connection churn")
    var egressDetails = try JSONSerialization.jsonObject(with: Data(encodedEgress.utf8)) as! [String: Any]
    egressDetails["flows"] = (egressDetails["flows"] as! [[String: Any]]).map { value in
        var value = value; value["process_kind"] = "system_extension"; return value
    }
    let egressRecord: [String: Any] = ["event": "egress_path_observed", "details": egressDetails]
    let egressLine = String(decoding: try JSONSerialization.data(withJSONObject: egressRecord), as: UTF8.self)
    try check(LogReader.format(egressLine).contains("系统扩展") && LogReader.format(egressLine).contains("200 字节") &&
              LogReader.format(egressLine).contains("en0"), "Readable egress log lost classification or evidence")
    try check(LogReader.format(egressLine, json: true).contains("remote_endpoint"), "Machine egress log lost endpoint evidence")
    let discoveryDelta = egressHeader + "Discovery Service.402,,,0,0,\n" +
        "udp6 *.5353<->*.*,awdl0,,45,0,\n" +
        "udp4 *:5353<->*:*,en0,,267,0,\n" +
        "Example Player.403,,,0,0,\n" +
        "udp6 *.5353<->*.*,awdl0,,0,45,\n" +
        "udp4 *:5353<->*:*,en0,,267,45,\n" +
        "udp4 *:60000<->*:*,en0,,297,125,\n" +
        "udp6 *.5353<->*.*,llw0,,45,45,\n"
    let discovery = try EgressObservation.parse(egressFirst + discoveryDelta, surgeInterface: "utun108", surgePID: 401)
    let discoveryDetails = try JSONSerialization.jsonObject(with: Data(JSON.encode(discovery).utf8))
    let discoveryRecord: [String: Any] = ["event": "egress_path_observed", "details": discoveryDetails]
    let discoveryLine = String(decoding: try JSONSerialization.data(withJSONObject: discoveryRecord, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    let discoveryHuman = LogReader.format(discoveryLine)
    try check(discovery.flows.count == 6 && discovery.flows.allSatisfy({ $0.destinationScope == "unresolved" }),
              "A local service port falsely established a known remote destination")
    try check(discoveryHuman.contains("仅有接收计数") && discoveryHuman.contains("有发送计数") &&
              discoveryHuman.contains("本地端点：*:60000") && discoveryHuman.contains("本地端点：*.5353") &&
              discoveryHuman.components(separatedBy: "mDNS 常用端口").count - 1 == 5 &&
              discoveryHuman.components(separatedBy: "无法区分局域网与公网").count - 1 == 6,
              "Unknown UDP evidence lost direction, local endpoint or qualified service-port hint")
    for human in [discoveryHuman, LogReader.format(egressLine)] {
        try check(human.contains("未验证数据包实际路径") && human.contains("nettop 报告接口") &&
                  !human.contains("公网直出") && !human.contains("已确认绕过"),
                  "Socket/interface counters were presented as proof of the actual packet path")
    }
    try check(LogReader.format(discoveryLine, json: true) == discoveryLine,
              "Human evidence correction rewrote the original machine record")
    let timingRecord: [String: Any] = ["event": "gate_changed", "time": "2026-01-01T00:00:00.123Z", "message": "signed Surge process missing",
                                     "details": ["exit_event_to_block_verified_ms": 22.5]]
    let timingLine = String(decoding: try JSONSerialization.data(withJSONObject: timingRecord), as: UTF8.self)
    try check(LogReader.format(timingLine).contains("00.123") && LogReader.format(timingLine).contains("22.5 毫秒"), "Exit-event timing or millisecond timestamp lost in readable logs")
    print("PASS: sampled egress uses new byte activity, separates Surge/local/unknown sockets and retains bounded deduplicated evidence")

    let atomicDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("surge-atomic-test-" + UUID().uuidString)
    do {
        try UserPaths.prepare(atomicDirectory.path)
        defer { try? FileManager.default.removeItem(at: atomicDirectory) }
        let path = atomicDirectory.appendingPathComponent("status.json").path
        let values = [String(repeating: "A", count: 4096), String(repeating: "B", count: 8192)]
        let originalMask = umask(0o077)
        defer { umask(originalMask) }
        try AtomicFile.write(values[0], to: path, mode: 0o644)
        final class WriteResult: @unchecked Sendable { var failure: String? }
        let result = WriteResult(), completed = DispatchGroup()
        completed.enter()
        DispatchQueue.global().async {
            defer { completed.leave() }
            do { for index in 0..<150 { try AtomicFile.write(values[index % 2], to: path, mode: 0o644) } }
            catch { result.failure = String(describing: error) }
        }
        var unreadable = false, incomplete = false, samples = 0
        while completed.wait(timeout: .now()) != .success {
            var info = stat()
            if lstat(path, &info) != 0 || info.st_mode & 0o777 != 0o644 { unreadable = true }
            if let value = try? String(contentsOfFile: path), values.contains(value) {} else { incomplete = true }
            samples += 1
        }
        try check(result.failure == nil && samples > 0 && !unreadable && !incomplete,
                  "Atomic publication exposed wrong permissions or incomplete content: \(result.failure ?? "reader failure")")
        try AtomicFile.write("private", to: path, mode: 0o600)
        var info = stat(); lstat(path, &info)
        try check(info.st_mode & 0o777 == 0o600, "Private state permissions were widened")
    }
    print("PASS: atomic state publication keeps final permissions and complete content under restrictive umask")
    let lockURL = FileManager.default.temporaryDirectory.appendingPathComponent("surge-guard-lock-test-" + UUID().uuidString)
    do {
        let first = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        let second = open(lockURL.path, O_RDWR)
        guard first >= 0, second >= 0 else { throw GuardError("Cannot create lock fixture") }
        defer { close(first); close(second); try? FileManager.default.removeItem(at: lockURL) }
        try RuntimeLock.acquire(first, timeout: 0)
        try rejects { try RuntimeLock.acquire(second, timeout: 0.06) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { flock(first, LOCK_UN) }
        try RuntimeLock.acquire(second, timeout: 1)
        flock(second, LOCK_UN)
    }
    print("PASS: delayed daemon lock release waits successfully; occupied lock times out")
    let directoryFixture = FileManager.default.temporaryDirectory.appendingPathComponent("surge-gate-directory-test-" + UUID().uuidString)
    do {
        defer { try? FileManager.default.removeItem(at: directoryFixture) }
        try UserPaths.prepare(directoryFixture.path)
        try UserPaths.prepare(directoryFixture.path)
        let bin = directoryFixture.appendingPathComponent("bin").path
        try UserPaths.prepare(bin)
        try UserPaths.prepare(bin)
        let regularFile = directoryFixture.appendingPathComponent("regular").path
        try "".write(toFile: regularFile, atomically: true, encoding: .utf8)
        try rejects { try UserPaths.prepare(regularFile) }
        let link = directoryFixture.appendingPathComponent("link").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: bin)
        try rejects { try UserPaths.prepare(link) }
    }
    print("PASS: user installer accepts existing bin directories and rejects files/symlinks")
    let backup = try BackupManifest(kind: "update")
    try JSON.decode(BackupManifest.self, from: Data(JSON.encode(backup).utf8)).validate()
    var invalidBackup = try JSONSerialization.jsonObject(with: Data(JSON.encode(backup).utf8)) as! [String: Any]
    for (field, value) in [("id", "../outside" as Any), ("kind", "unknown" as Any), ("files", ["/etc/pf.conf"] as Any)] {
        var modified = invalidBackup; modified[field] = value
        try rejects { try JSON.decode(BackupManifest.self, from: JSONSerialization.data(withJSONObject: modified)).validate() }
    }
    invalidBackup["files"] = []
    try rejects { try JSON.decode(BackupManifest.self, from: JSONSerialization.data(withJSONObject: invalidBackup)).validate() }
    print("PASS: recovery manifests reject path traversal, arbitrary destinations and incomplete backups")

    let actionFixture = FileManager.default.temporaryDirectory.appendingPathComponent("surge-guard-menu-test-" + UUID().uuidString)
    do {
        try FileManager.default.createDirectory(at: actionFixture, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: actionFixture) }
        let directory = actionFixture.path
        let mock = directory + "/mock"
        // The real script runs only against these fake tools; no sudo/PF/service mutation.
        let mockScript = """
        #!/bin/sh
        kind=$1; shift
        printf '%s %s\\n' "$kind" "$*" >> '\(directory)/calls'
        case "$kind" in
          id) echo 501 ;;
          sudo) case "$1" in -v) exit 0 ;; -n) shift ;; esac; exec "$@" ;;
          guard) case "$1" in --help) echo legacy ;; check) exit 0 ;; esac ;;
          launchctl)
            if [ "$1" = print ] && [ -f '\(directory)/query-failed' ]; then echo 'Service query failed' >&2; exit 5; fi
            if [ "$1" = print ] && [ -f '\(directory)/missing-pid' ]; then echo 'state = running'; exit 0; fi
            if [ "$1" = print ] && [ -f '\(directory)/absent' ]; then echo 'Could not find service' >&2; exit 113; fi
            case "$1" in
              print) if [ -f '\(directory)/stopped' ]; then exit 1; fi; if [ -f '\(directory)/restarted' ]; then echo 'pid = 5678'; else echo 'pid = 1234'; fi ;;
              bootout) touch '\(directory)/stopped' ;;
              kill) touch '\(directory)/restarted' ;;
            esac ;;
          kill)
            if [ -f '\(directory)/stuck' ]; then exit 0; fi
            if [ ! -f '\(directory)/exited' ]; then touch '\(directory)/exited'; exit 0; fi
            exit 1 ;;
          pfctl) exit 0 ;;
          tail)
            if [ -f '\(directory)/tail-failed' ]; then exit 5; fi
            printf '%s\\n' '{"event":"gate_state","message":"0 application(s) pending"}' ;;
          sleep) exit 0 ;;
        esac
        """
        try mockScript.write(toFile: mock, atomically: true, encoding: .utf8)
        chmod(mock, 0o700)
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var script = try String(contentsOf: project.appendingPathComponent("integrations/swiftbar/surge-guard-action.sh"))
        script = script.replacingOccurrences(of: "guard_bin=/Library/PrivilegedHelperTools/surge-guard", with: "guard_bin='\(directory)/guard'")
        for tool in ["launchctl", "kill", "sleep", "pfctl", "tail"] {
            let original = tool == "pfctl" ? "/sbin/pfctl" : tool == "tail" ? "/usr/bin/tail" : "/bin/" + tool
            script = script.replacingOccurrences(of: original, with: "'\(directory)/\(tool)'")
        }
        script = script.replacingOccurrences(of: "sudo ", with: "'\(directory)/sudo' ")
        script = script.replacingOccurrences(of: "$(id -u)", with: "$('\(directory)/id' -u)")
        let rendererPath = directory + "/renderer"
        script = script.replacingOccurrences(of: "renderer=\"$HOME/Library/Application Support/SurgeGuard/bin/surge-guard-ui\"", with: "renderer='\(rendererPath)'")
        let rendererScript = "#!/bin/sh\nprintf 'renderer %s\\n' \"$*\" >> '\(directory)/calls'\nprintf 'rendered: '\n/bin/cat\n"
        try rendererScript.write(toFile: rendererPath, atomically: true, encoding: .utf8); chmod(rendererPath, 0o700)
        for tool in ["guard", "sudo", "launchctl", "kill", "sleep", "pfctl", "tail", "id"] {
            let wrapper = "#!/bin/sh\nexec '\(mock)' \(tool) \"$@\"\n"
            let path = directory + "/" + tool
            try wrapper.write(toFile: path, atomically: true, encoding: .utf8); chmod(path, 0o700)
        }
        let testScript = directory + "/action.sh"
        try script.write(toFile: testScript, atomically: true, encoding: .utf8)
        let recovered = try Command.run("/bin/sh", [testScript, "unlock"], timeout: 10)
        try check(recovered.status == 0 && recovered.output.contains("Protection is OFF"), "Offline recovery failed against legacy fixture: \(recovered.combined)")
        let calls = try String(contentsOfFile: directory + "/calls")
        try check(calls.range(of: "kill -0")!.lowerBound < calls.range(of: "pfctl -a io.github.surge-guard -F rules")!.lowerBound, "Rules cleared before daemon exit check")
        try FileManager.default.removeItem(atPath: directory + "/stopped")
        let restarted = try Command.run("/bin/sh", [testScript, "restart"], timeout: 10)
        try check(restarted.status == 0 && restarted.output.contains("pid=5678"), "Legacy restart did not wait for new PID: \(restarted.combined)")
        let restartCalls = try String(contentsOfFile: directory + "/calls")
        try check(restartCalls.contains("kill SIGTERM") && !restartCalls.contains("kickstart"), "Legacy restart used a forced restart")
        try "".write(toFile: directory + "/stuck", atomically: true, encoding: .utf8)
        try "".write(toFile: directory + "/calls", atomically: true, encoding: .utf8)
        let refused = try Command.run("/bin/sh", [testScript, "unlock"], timeout: 10)
        try check(refused.status != 0 && !String(contentsOfFile: directory + "/calls").contains("-F rules"), "Recovery cleared rules while old daemon was alive")
        try FileManager.default.removeItem(atPath: directory + "/stuck")
        try FileManager.default.removeItem(atPath: directory + "/stopped")
        try "".write(toFile: directory + "/calls", atomically: true, encoding: .utf8)
        let independent = try Command.run("/bin/bash", [testScript, "unlock"], timeout: 10)
        let independentCalls = try String(contentsOfFile: directory + "/calls")
        let binaryIndependent = independent.status == 0 && !independentCalls.contains("guard --help")
        try "".write(toFile: directory + "/query-failed", atomically: true, encoding: .utf8)
        try "".write(toFile: directory + "/calls", atomically: true, encoding: .utf8)
        let failedQuery = try Command.run("/bin/bash", [testScript, "unlock"], timeout: 10)
        let failedQueryCalls = try String(contentsOfFile: directory + "/calls")
        let queryFailureSafe = failedQuery.status != 0 && !failedQueryCalls.contains("-F rules")
        try check(binaryIndependent && queryFailureSafe, "Recovery depends on guard help or flushes after an unknown query: binaryIndependent=\(binaryIndependent), queryFailureSafe=\(queryFailureSafe)")
        try FileManager.default.removeItem(atPath: directory + "/query-failed")
        try "".write(toFile: directory + "/missing-pid", atomically: true, encoding: .utf8)
        try "".write(toFile: directory + "/calls", atomically: true, encoding: .utf8)
        let missingPID = try Command.run("/bin/bash", [testScript, "unlock"], timeout: 10)
        try check(missingPID.status != 0 && !String(contentsOfFile: directory + "/calls").contains("-F rules"), "Recovery flushed without a known running PID")
        try FileManager.default.removeItem(atPath: directory + "/missing-pid")
        try "".write(toFile: directory + "/absent", atomically: true, encoding: .utf8)
        let absent = try Command.run("/bin/bash", [testScript, "unlock"], timeout: 10)
        try check(absent.status == 0, "Known missing service blocked independent recovery")
        try "".write(toFile: directory + "/calls", atomically: true, encoding: .utf8)
        let logBridge = try Command.run("/bin/bash", [testScript, "logs"], timeout: 10)
        let logCalls = try String(contentsOfFile: directory + "/calls")
        try check(logBridge.status == 0 && logBridge.output.contains("rendered: {") && logCalls.contains("renderer format-logs"), "System log reader bypassed the user formatter")
        try check(logCalls.contains("sudo \(directory)/tail -n 200 /private/var/db/surge-guard/events.log") && !logCalls.contains("sudo \(rendererPath)"), "User formatter was invoked with sudo")
        try check(!logCalls.contains("guard --help"), "Independent log access queried the potentially broken guard executable")
        try "".write(toFile: directory + "/tail-failed", atomically: true, encoding: .utf8)
        try check(try Command.run("/bin/bash", [testScript, "logs"], timeout: 10).status != 0, "Log pipeline concealed a failed privileged reader")
        let plugin = try String(contentsOf: project.appendingPathComponent("integrations/swiftbar/surge-guard.5s.sh"))
        let pluginPath = directory + "/plugin.sh"
        try ("HOME='\(directory)'\n" + plugin).write(toFile: pluginPath, atomically: true, encoding: .utf8)
        let fallback = try Command.checked("/bin/sh", [pluginPath, "--section"])
        try check(fallback.contains("param1=unlock") && !fallback.contains("---"), "Missing independent fallback when renderer is absent")
    }
    print("PASS: offline legacy recovery waits for exit and refuses to flush while daemon remains alive")
    print("PASS: emergency recovery avoids the guard executable and refuses unknown queries or missing running PIDs")
    print("PASS: SwiftBar log bridge formats without sudo and propagates privileged-reader failure")

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

    let groupOnly = RouteCheck(url: "https://example.com", requiredGroup: "Residential")
    let groupConfiguration = Configuration(version: 1, mode: "routes", routeChecks: [groupOnly])
    let groupJSON = try JSON.encode(groupConfiguration)
    try check(!groupJSON.contains("allowed_final_policies"), "Group-only policy serialized a misleading null allowlist")
    try check(try Configuration.decode(Data(groupJSON.utf8)) == groupConfiguration, "Omitted allowlist did not round trip")
    try check(try groupConfiguration.fingerprint() != routeConfig.fingerprint(), "Group-only policy shared a fingerprint with a restricted policy")
    for badValue in ["null", "[]", "\"Node A\"", "[1]", "[\"Node A\",\"Node A\"]", "[\"DIRECT\"]"] {
        let invalid = groupJSON.replacingOccurrences(of: "\"required_group\":\"Residential\"", with: "\"allowed_final_policies\":\(badValue),\"required_group\":\"Residential\"")
        try rejects { _ = try Configuration.decode(Data(invalid.utf8)) }
    }
    for final in ["Node A", "Node C"] {
        var value = explanation; value["final"] = final
        try check(try RouteResult.evaluate(JSONSerialization.data(withJSONObject: value), check: groupOnly).ready, "Group-only matching rejected a changed proxy node")
    }
    for (key, value) in [("rule-policy", "Other"), ("final", "DIRECT"), ("final", "REJECT"), ("final-type", "DIRECT"), ("final-type", "REJECT")] {
        var invalid = explanation; invalid[key] = value
        try check(!(try RouteResult.evaluate(JSONSerialization.data(withJSONObject: invalid), check: groupOnly)).ready, "Group-only matching accepted a wrong group or direct/reject result")
    }
    var unresolved = explanation; unresolved["steps"] = []
    try check(!(try RouteResult.evaluate(JSONSerialization.data(withJSONObject: unresolved), check: groupOnly)).ready, "Group-only matching accepted an unresolved group")
    try check(!groupOnly.allowsFinalPolicy(nil) && !groupOnly.allowsFinalPolicy(""), "Daemon result binding accepted a missing final policy")
    print("PASS: optional final-policy allowlist accepts group proxy changes; null/empty/malformed lists and direct/reject results fail closed")

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
    let freshSnapshot = GuardSnapshot(runId: "display-test", firewallVerifiedUptime: SystemClock.seconds,
                                     allowed: true, configurationMode: "enhanced", readiness: nil, session: nil, reasons: [])
    let snapshotObject = try JSONSerialization.jsonObject(with: Data(JSON.encode(freshSnapshot).utf8))
    for (running, state, included, expected) in [(true, "allowed", true, true), (false, "allowed", true, false),
                                               (true, "unknown", true, false), (true, "allowed", false, false)] {
        var object: [String: Any] = ["daemon_running": running, "state": state, "reason": ""]
        if included { object["snapshot"] = snapshotObject }
        let report = try JSON.decode(StatusReport.self, from: JSONSerialization.data(withJSONObject: object))
        try check(report.firewallVerified == expected, "Menu accepted PID/condition-only or unknown status as verified PF")
    }
    print("PASS: menu requires running daemon and current verified PF; conditions alone cannot be green")
    for (running, fresh, state, pending, allowed, green) in [
        (true, true, "ready", [String](), true, true),
        (false, true, "ready", [], true, false), (true, false, "ready", [], true, false),
        (true, true, "ready", [], false, false), (true, true, "ready", ["com.example.A"], true, false),
        (true, true, "waiting", [], true, false), (true, true, "restoring", [], true, false),
        (true, true, "error", [], true, false), (true, true, "unknown", [], true, false), (true, true, "shutting_down", [], true, false)
    ] {
        let object: [String: Any] = ["running": running, "fresh": fresh, "status": ["state": state, "pending": pending]]
        let report = try JSON.decode(GateStatusReport.self, from: JSONSerialization.data(withJSONObject: object))
        try check(report.menuTitle(guardAllowed: allowed).contains("🟢") == green, "SurgeGate menu displayed false green")
    }
    print("PASS: companion green requires fresh running ready state, no pending apps and verified network permission")

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
    let legacyPermission: [String: Any] = ["event": "gate_state", "level": "info", "app": "", "pid": 123,
                                         "message": "unknown: status_unavailable: Error Domain=NSCocoaErrorDomain Code=257 Permission denied UserInfo={raw-details}"]
    let permissionLine = String(decoding: try JSONSerialization.data(withJSONObject: legacyPermission), as: UTF8.self)
    let friendlyPermission = LogReader.format(permissionLine)
    try check(friendlyPermission.contains("WARNING") && friendlyPermission.contains("SurgeGate") && friendlyPermission.contains("EACCES/13") && friendlyPermission.contains("暂停"), "Status failure lacks cause/impact/severity")
    try check(!friendlyPermission.contains("UserInfo") && !friendlyPermission.contains("event=") && !friendlyPermission.contains("pid="), "Default human log leaked raw diagnostic noise")
    try check(LogReader.format(permissionLine, json: true).contains("raw-details"), "Raw diagnostics were lost")
    let terminalInjection = String(decoding: try JSONSerialization.data(withJSONObject: ["event": "\u{1b}[31munknown", "time": "\u{1b}[31mclock", "level": "\u{1b}[31merror"]), as: UTF8.self)
    try check(!LogReader.format(terminalInjection).contains("\u{1b}"), "Log header preserved terminal control characters")
    let progress = String(decoding: try JSONSerialization.data(withJSONObject: ["event": "gate_state", "app": "", "message": "1 application(s) pending"]), as: UTF8.self)
    try check(LogReader.format(progress).contains("剩余 1 个应用"), "Legacy progress was not explained")
    let recovered = String(decoding: try JSONSerialization.data(withJSONObject: ["event": "gate_status_recovered", "component": "SurgeGate", "details": ["pending_count": 0, "guard_state": "allowed"]]), as: UTF8.self)
    try check(LogReader.format(recovered).contains("已恢复") && LogReader.format(recovered).contains("剩余 0 个应用"), "Recovery state is not clear")
    let nestedFailure = "rule_probe_failed: /bin/launchctl asuser 501 helper failed: raw-helper-error\nsurge-guard: surge-cli --raw status failed: Surge isn't running on the local machine. Use --remote to specify a remote target."
    let waitingRecord: [String: Any] = ["component": "SurgeGate", "event": "gate_waiting", "message": "blocked: " + nestedFailure,
                                       "details": ["guard_state": "blocked", "reason": nestedFailure, "pending_count": 0]]
    let waitingLine = String(decoding: try JSONSerialization.data(withJSONObject: waitingRecord), as: UTF8.self)
    let waitingLog = LogReader.format(waitingLine)
    try check(waitingLog.contains("系统门禁已阻断") && waitingLog.contains("恢复暂停") && waitingLog.contains("Surge CLI 暂时无法连接"), "Waiting log omitted actual CLI cause and paused state")
    try check(!waitingLog.contains("asuser") && !waitingLog.contains("raw-helper-error") && LogReader.format(waitingLine, json: true).contains("raw-helper-error"), "Nested helper diagnostics polluted the human log or vanished from JSON")
    let failedProbe = String(decoding: try JSONSerialization.data(withJSONObject: ["event": "rule_probe_failed", "message": nestedFailure]), as: UTF8.self)
    try check(LogReader.format(failedProbe).contains("Surge CLI 暂时无法连接") && !LogReader.format(failedProbe).contains("raw-helper-error"), "Root probe failure retained nested command noise")
    try check(readable.contains("SurgeGuard") && readable.contains("普通联网已阻断") && readable.contains("最终策略"), "System log lacks component/state/route context")
    print("PASS: both components explain state, cause, impact, progress and recovery; JSON retains raw diagnostics")
    _ = try JSONSerialization.jsonObject(with: Data(LogReader.format("legacy event", json: true).utf8))
    let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("surge-guard-log-test-" + UUID().uuidString)
    do {
        try (logLine + "\nlegacy record without trailing newline").write(to: logURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: logURL) }
        try LogReader.show(path: logURL.path, follow: false, json: false)
    }
    print("PASS: readable decision logs, machine JSON and legacy records")
    let eventDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("surge-events-test-" + UUID().uuidString)
    do {
        try UserPaths.prepare(eventDirectory.path)
        defer { try? FileManager.default.removeItem(at: eventDirectory) }
        let path = eventDirectory.appendingPathComponent("events.jsonl").path
        let lockPath = path + ".lock"
        for index in 1...5 {
            let record = Data(("record-\(index):" + String(repeating: "x", count: EventFile.maximumBytes / 2)).utf8)
            try EventFile.append(record, to: path, owner: getuid(), lockPath: lockPath)
        }
        for (suffix, index) in [("", 5), (".1", 4)] {
            let value = try Data(contentsOf: URL(fileURLWithPath: path + suffix))
            var info = stat(); lstat(path + suffix, &info)
            try check(value.count <= EventFile.maximumBytes && String(decoding: value.prefix(9), as: UTF8.self).hasPrefix("record-\(index):"), "Log rotation lost the newest/previous record or exceeded its bound")
            try check(info.st_mode & 0o777 == 0o600, "Log permissions were widened")
        }
        try check(try FileManager.default.contentsOfDirectory(atPath: eventDirectory.path).count == 3, "Log rotation accumulated extra files")
        try rejects { try EventFile.append(Data(repeating: 65, count: EventFile.maximumBytes), to: path, owner: getuid(), lockPath: lockPath) }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        try rejects { try EventFile.append(Data("unsafe".utf8), to: path, owner: getuid(), lockPath: lockPath) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        try rejects { try EventFile.append(Data("wrong owner".utf8), to: path, owner: getuid() + 1, lockPath: lockPath) }
        try FileManager.default.removeItem(atPath: path + ".1")
        try FileManager.default.createSymbolicLink(atPath: path + ".1", withDestinationPath: path)
        try rejects { try EventFile.append(Data(repeating: 65, count: EventFile.maximumBytes / 2), to: path, owner: getuid(), lockPath: lockPath) }
    }
    print("PASS: bounded private event logs retain only current/previous files and reject oversized or unsafe writes")

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
    func descriptorCount() -> Int {
        (0..<4096).filter { fcntl(Int32($0), F_GETFD) != -1 }.count
    }
    let descriptorsBefore = descriptorCount()
    for _ in 0..<40 { _ = try Command.run("/usr/bin/true", []) }
    try check(descriptorCount() <= descriptorsBefore + 2, "Repeated commands leaked descriptors: before=\(descriptorsBefore), after=\(descriptorCount())")
    print("PASS: repeated command execution closes pipe descriptors")
    let failedDescriptors = descriptorCount()
    for _ in 0..<10 {
        try rejects { _ = try Command.run("/nonexistent/surge-guard-test", []) }
        try rejects { _ = try Command.run("/bin/sleep", ["1"], timeout: 0.01) }
        _ = try Command.run("/bin/cat", [], input: "test")
    }
    try check(descriptorCount() <= failedDescriptors + 2, "Command failure/input/timeout leaked pipe descriptors")
    let mockService = try Command.run("/usr/bin/printf", ["state = running\n pid = 123\n"])
    try check(try StatusReport.serviceRunning(mockService, pid: 123), "Running daemon rejected")
    try check(!(try StatusReport.serviceRunning(mockService, pid: 456)), "Mismatched PID accepted")
    try rejects { _ = try StatusReport.serviceRunning(Command.run("/usr/bin/false", [])) }
    let absentService = try Command.run("/bin/launchctl", ["print", "system/io.github.surge-guard.nonexistent-test"])
    try check(!(try StatusReport.serviceRunning(absentService)), "Absent service was treated as running")
    print("PASS: command failures release descriptors; query errors remain unknown, distinct from absent service")
    // Read-only regression for the group-writable /var/run found on macOS.
    try check(!Paths.runtime.hasPrefix("/var/run/"), "Runtime state must not depend on a non-writable /var/run")
    try RootFiles.verify(URL(fileURLWithPath: Paths.runtime).deletingLastPathComponent().path, directory: true)
    print("PASS: protected runtime parent")
    print("All checks passed. Live packet blocking has NOT been tested by this program.")
} catch {
    fputs("FAIL: \(error)\n", stderr)
    exit(1)
}
