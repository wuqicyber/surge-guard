import Foundation
import SurgeGuardCore

enum SwiftBar {
    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "¦").components(separatedBy: .newlines).joined(separator: " ")
    }
    static func parameter(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    static func render(sectionOnly: Bool) -> String {
        let status = StatusReport.read()
        let icon = status.state == "allowed" ? "🟢" : status.state == "blocked" ? "🔴" : "🟠"
        let title = ["allowed": "已放行", "blocked": "已阻断", "stopped": "守护已停止", "unknown": "状态未知", "unlocked": "已手动解除"][status.state] ?? "状态未知"
        var lines = sectionOnly ? [] : ["\(icon) | size=13", "---"]
        lines.append("Surge Guard · \(icon) \(title)")
        if let snapshot = status.snapshot {
            lines.append("-- 配置：\(snapshot.configurationMode == "routes" ? "增强模式 + 分流检查" : "增强模式")")
            lines.append("-- 增强模式：\(snapshot.readiness?.ready == true ? "就绪" : "未就绪")")
            for route in snapshot.session?.routes ?? [] {
                lines.append("-- \(route.ready ? "🟢" : "🔴") \(clean(route.url)) → \(clean(route.finalPolicy ?? "未知"))")
            }
            let age = max(0, Int(Date().timeIntervalSince(snapshot.checkedAt)))
            lines.append("-- 最近检查：\(age) 秒前 · PF 状态为最近验证结果 | color=#595959,#C7C7CC size=12")
        }
        if !status.reason.isEmpty { lines.append("-- 原因：\(clean(status.reason)) | color=#B91C1C,#FF6961 size=12") }
        func command(_ title: String, _ args: [String], root: Bool = false) {
            let executable = root ? "/usr/bin/sudo" : Paths.binary
            let parameters = (root ? [Paths.binary] : []) + args
            lines.append("-- \(title) | bash=\(parameter(executable)) " + parameters.enumerated().map { "param\($0.offset + 1)=\(parameter($0.element))" }.joined(separator: " ") + " terminal=true refresh=true")
        }
        command("重新检查条件", ["check"])
        command("查看完整诊断", ["doctor"], root: true)
        command("查看最近 200 条日志", ["logs"], root: true)
        command("实时跟踪日志", ["logs", "--follow"], root: true)
        command("编辑规则草稿", ["edit-config"])
        command("验证并应用规则草稿", ["configure", CLI.draft], root: true)
        command(status.daemonRunning ? "重启守护（先阻断）" : "启动守护", [status.daemonRunning ? "restart" : "start"], root: true)
        command("临时解除保护（重启后恢复）", ["unlock"], root: true)
        if FileManager.default.isExecutableFile(atPath: CLI.gateBinary) {
            let gateStatus = (try? Command.checked(CLI.gateBinary, ["status"], timeout: 3)) ?? "SurgeGate 状态不可用"
            lines.append("SurgeGate · \(clean(gateStatus))")
            for (title, args) in [("查看 SurgeGate 日志", ["logs"]), ("重启 SurgeGate", ["restart"]), ("编辑应用配置", ["edit-config"]), ("有序重启系统", ["shutdown", "--action", "restart"]), ("有序关机", ["shutdown", "--action", "shutdown"])] {
                lines.append("-- \(title) | bash=\(parameter(CLI.gateBinary)) " + args.enumerated().map { "param\($0.offset + 1)=\(parameter($0.element))" }.joined(separator: " ") + " terminal=true refresh=true")
            }
        } else { lines.append("SurgeGate · 未安装 | color=#595959,#C7C7CC") }
        return lines.joined(separator: "\n") + "\n"
    }
}
