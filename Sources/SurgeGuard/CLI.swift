import Foundation
import Darwin
import SurgeGuardCore

enum CLI {
    static let usage = """
    Surge Guard — Surge Enhanced Mode gate with optional routing conditions

      check [--json] [--config FILE]   Probe conditions; does not prove PF is active
      status [--json]                  Read the daemon's recent verified status
      doctor                          Explain conditions, configuration and service status
      validate FILE                   Validate a policy without network changes
      rules                           Preview blocked PF rules
      swiftbar [--section]             Render the portable SwiftBar menu
      edit-config                     Open a user-owned policy draft
      sudo configure FILE             Validate and atomically install a policy
      sudo install                    Install/update; a running gate stays blocked during update
      sudo start                      Load the installed system service
      sudo restart                    Ask the service to block and restart normally
      sudo logs [--follow] [--json]    Readable recent events; optional follow or JSON Lines
      sudo unlock                     Stop and remove this gate; reboot/start re-arms it
      sudo uninstall                  Remove installed system components; retain configuration/logs

    Enhanced mode preserves Surge routing and DIRECT policies. This is a reactive
    readiness gate; it does not certify that every packet is forced through Surge.
    """

    struct CheckReport: Encodable {
        let version = 1
        var ready: Bool
        let mode: String
        let readiness: Readiness
        var session: SessionObservation?
        var reasons: [String]
    }

    static func policy(_ args: [String]) throws -> Configuration {
        if let position = args.firstIndex(of: "--config") {
            guard args.indices.contains(position + 1) else { throw GuardError("--config requires a file") }
            return try Configuration.decode(Data(contentsOf: URL(fileURLWithPath: args[position + 1])))
        }
        if FileManager.default.fileExists(atPath: Paths.configuration) || FileManager.default.fileExists(atPath: Paths.publicState) {
            return try Configuration.load()
        }
        return .enhanced
    }

    static func check(_ args: [String]) throws -> CheckReport {
        let configuration = try policy(args)
        let readiness = try Probe.readiness()
        var report = CheckReport(ready: readiness.ready, mode: configuration.mode,
                                 readiness: readiness, reasons: readiness.reasons)
        if configuration.mode == "routes" {
            do {
                let session = try geteuid() == 0 ? Probe.privilegedSession(configuration: configuration) : Probe.session(configuration: configuration)
                report.session = session
                if !session.ready {
                    if session.mode != "rule" { report.reasons.append("outbound_mode_is_\(session.mode)") }
                    if !session.enhancedMode { report.reasons.append("enhanced_mode_disabled") }
                    report.reasons += session.routes.filter { !$0.ready }.map { "\($0.reason): \($0.url)" }
                }
                report.ready = readiness.ready && session.ready
            } catch {
                report.ready = false
                report.reasons.append("rule_probe_failed: \(error)")
            }
        }
        return report
    }

    static var userDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/SurgeGuard")
    }
    static var draft: String { userDirectory.appendingPathComponent("policy-draft.json").path }
    static var gateBinary: String { userDirectory.appendingPathComponent("bin/surge-gate").path }

    static func run(_ args: [String]) throws {
        guard let action = args.first else { print(usage); return }
        if ["help", "--help", "-h"].contains(action) || args.contains("--help") || args.contains("-h") { print(usage); return }
        if action == "session-probe" {
            guard args.count == 2, let uid = UInt32(args[1]) else { throw GuardError("Invalid internal session probe") }
            try Probe.dropPrivileges(to: uid)
            let observation = try Probe.session(configuration: Configuration.load())
            print(try JSON.encode(observation))
            return
        }
        if ["check", "doctor"].contains(action) {
            var index = 1
            var seen = Set<String>()
            while index < args.count {
                let option = args[index]
                guard seen.insert(option).inserted else { throw GuardError("Duplicate option: \(option)") }
                if option == "--config", args.indices.contains(index + 1) { index += 2 }
                else if option == "--json", action == "check" { index += 1 }
                else { throw GuardError("Unknown or incomplete option: \(option)") }
            }
        } else if ["status", "swiftbar"].contains(action) {
            let optional = ["status": "--json", "swiftbar": "--section"][action]!
            guard args.count == 1 || (args.count == 2 && args[1] == optional) else { throw GuardError("Unexpected options for \(action)") }
        } else if action == "logs" {
            let flags = Array(args.dropFirst())
            guard Set(flags).count == flags.count, flags.allSatisfy({ ["--json", "--follow"].contains($0) }) else { throw GuardError("Usage: logs [--follow] [--json]") }
        } else if !["validate", "configure"].contains(action), args.count != 1 {
            throw GuardError("Unexpected arguments for \(action)")
        }
        switch action {
        case "rules": print(Policy.blocked, terminator: "")
        case "check":
            let report = try check(args)
            print(try JSON.encode(report, pretty: !args.contains("--json")))
            if !args.contains("--json") { print(report.ready ? "READY (conditions only; inspect status for PF)" : "NOT READY") }
            exit(report.ready ? 0 : 1)
        case "status":
            let report = StatusReport.read()
            print(try JSON.encode(report, pretty: !args.contains("--json")))
        case "validate":
            guard args.count == 2 else { throw GuardError("Usage: validate FILE") }
            let config = try Configuration.decode(Data(contentsOf: URL(fileURLWithPath: args[1])))
            print("Valid version \(config.version), mode \(config.mode), \(config.routeChecks.count) route check(s)")
        case "doctor":
            print("=== Service and recent PF verification ===")
            print(try JSON.encode(StatusReport.read(), pretty: true))
            print("=== Fresh condition probe (no firewall changes) ===")
            print(try JSON.encode(check(args), pretty: true))
            print("=== Paths ===\nPolicy: \(Paths.configuration)\nPrivate events: \(Paths.eventsLog)")
            if geteuid() == 0 {
                let firewall = Firewall()
                print("PF enabled: \(try firewall.enabled()); anchor first: \(try firewall.attached())")
                print("Live anchor:\n\(try firewall.readRules())")
            } else { print("For live PF and private logs: sudo \(Paths.binary) doctor / logs") }
            print("This diagnoses readiness gating; it is not proof of zero leakage or packet-by-packet enforcement.")
        case "swiftbar": print(SwiftBar.render(sectionOnly: args.contains("--section")), terminator: "")
        case "edit-config":
            guard geteuid() != 0 else { throw GuardError("Edit the draft as your normal user, then use sudo configure FILE") }
            try FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            if !FileManager.default.fileExists(atPath: draft) {
                try JSON.encode(policy([]), pretty: true).write(toFile: draft, atomically: true, encoding: .utf8)
            }
            try Command.checked("/usr/bin/open", ["-a", "TextEdit", draft])
        default:
            guard ["install", "start", "restart", "run", "unlock", "uninstall", "configure", "logs"].contains(action) else {
                throw GuardError("Unknown command: \(action)")
            }
            guard geteuid() == 0 else { throw GuardError("\(action) requires administrator privileges") }
            switch action {
            case "install": try Admin.install()
            case "start": try Admin.start()
            case "restart": try Admin.restart()
            case "unlock": try Admin.unlock()
            case "uninstall": try Admin.uninstall()
            case "configure":
                guard args.count == 2 else { throw GuardError("Usage: sudo configure FILE") }
                let config = try Configuration.decode(Data(contentsOf: URL(fileURLWithPath: args[1])))
                try RootFiles.preparePublicState()
                try RootFiles.write(try JSON.encode(config, pretty: true), to: Paths.configuration, mode: 0o644)
                EventLog.write("configuration_installed", message: "Policy validated and installed", details: ["mode": config.mode])
                print("Policy installed. A running daemon reloads it automatically; inspect status.")
            case "logs":
                try RootFiles.verify(Paths.eventsLog)
                try LogReader.show(path: Paths.eventsLog, follow: args.contains("--follow"), json: args.contains("--json"))
            case "run": try Daemon().run()
            default: break
            }
        }
    }
}
