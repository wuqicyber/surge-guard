import Foundation

public enum GateCommand {
    public static func action(_ args: [String]) throws -> String? {
        guard let action = args.first else { return nil }
        if ["help", "--help", "-h"].contains(action) || args.contains("--help") || args.contains("-h") { return nil }
        let valid: Bool
        switch action {
        case "install", "setup", "run", "start", "stop", "restart", "uninstall", "edit-config", "update-pause", "update-resume":
            valid = args.count == 1
        case "status":
            valid = args.count == 1 || args == ["status", "--json"]
        case "logs":
            let flags = Array(args.dropFirst())
            valid = Set(flags).count == flags.count && flags.allSatisfy { ["--json", "--follow"].contains($0) }
        case "shutdown":
            valid = args.count == 3 && args[1] == "--action" && ["restart", "shutdown"].contains(args[2])
        case "recover-launch":
            valid = args.count == 3 && UUID(uuidString: args[1]) != nil && args[2] == "--confirm-settled"
        default:
            throw GuardError("Unknown command: \(action)")
        }
        guard valid else { throw GuardError("Unexpected arguments for \(action); use surge-gate \(action) --help") }
        return action
    }
}
