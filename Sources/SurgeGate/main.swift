import Foundation
import Darwin
import SurgeGuardCore

let usage = """
SurgeGate — user-session companion to Surge Guard
  install / setup       Install/update user service; migrate legacy config without deleting it
  run                   Wait for verified protection, restore apps, checkpoint session every 30s
  status [--json]       Inspect this service (not a firewall claim)
  start                 Start the user service if stopped
  stop                  Stop the user service without changing current network or PF rules
  restart               Restart (or start) the user service
  update-pause          Persist update pause and wait for Gate acknowledgement; does not change PF
  update-resume         Finish/cancel the official update, then resume automatic recovery
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
    let management = ["install", "setup", "start", "stop", "restart", "uninstall", "shutdown", "update-pause", "update-resume"].contains(action)
        ? try lock("command.lock") : nil
    defer { if let management { close(management) } }
    switch action {
    case "install", "setup": try install()
    case "run": try run()
    case "status":
        let (status, running, fresh) = try readStatus()
        if args.contains("--json") {
            struct Report: Encodable { var running: Bool; var fresh: Bool; var status: GateStatus }
            print(try JSON.encode(Report(running: running, fresh: fresh, status: status)))
        } else { print(fresh ? "\(status.state): \(status.message)" : "状态过期或服务未运行") }
    case "start":
        try ensureServiceLoaded(waitForRunning: true)
        try waitForFreshService()
        print("SurgeGate service started.")
    case "stop": try stopService()
    case "restart": try restartService()
    case "update-pause", "update-resume":
        guard args.count == 1 else { throw GuardError("Unexpected update mode arguments") }
        try updateMode(paused: action == "update-pause")
    case "edit-config":
        try Command.checked("/usr/bin/open", ["-a", "TextEdit", UserPaths.config])
    case "logs":
        let flags = Array(args.dropFirst())
        guard Set(flags).count == flags.count, flags.allSatisfy({ ["--json", "--follow"].contains($0) }) else { throw GuardError("Usage: logs [--follow] [--json]") }
        try LogReader.show(path: UserPaths.log, follow: args.contains("--follow"), json: args.contains("--json"))
    case "shutdown":
        guard args.count == 3, args[1] == "--action", ["restart", "shutdown"].contains(args[2]) else { throw GuardError("Usage: shutdown --action restart|shutdown") }
        try queueShutdown(args[2])
    case "uninstall": try uninstallService()
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
