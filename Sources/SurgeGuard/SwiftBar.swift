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
        let modern = ((try? Command.checked(Paths.binary, ["--help"])) ?? "").contains("restore-policy")
        let state = ["allowed", "blocked"].contains(status.state) && !status.firewallVerified ? "unknown" : status.state
        let icon = state == "allowed" ? "🟢" : state == "blocked" ? "🔴" : "🟠"
        let title = !modern && status.daemonRunning ? "旧版运行 · PF 待验证" : ["allowed": "PF 已验证放行", "blocked": "PF 已验证阻断", "stopped": "守护已停止", "unknown": "状态未知", "unlocked": "已手动解除"][state] ?? "状态未知"
        var lines = sectionOnly ? [] : ["\(icon) | size=13", "---"]
        // SwiftBar 2.1.1 clears submenu actions during live updates; a color preserves the action.
        let parentStyle = " | color=#1F2937,#F2F2F7"
        lines.append("Surge Guard · \(icon) \(title)" + parentStyle)
        if let snapshot = status.snapshot {
            let current = status.firewallVerified
            lines.append("-- 配置：\(snapshot.configurationMode == "routes" ? "增强模式 + 分流检查" : "增强模式")")
            lines.append("-- 增强模式检查：\(current ? (snapshot.readiness?.ready == true ? "就绪" : "未就绪") : "历史结果，待重新验证")")
            for route in snapshot.session?.routes ?? [] {
                lines.append("-- \(current ? (route.ready ? "🟢" : "🔴") : "🟠") 分流\(current ? "检查" : "历史记录")：\(clean(route.url)) → \(clean(route.finalPolicy ?? "未知"))")
            }
            let age = max(0, Int(Date().timeIntervalSince(snapshot.checkedAt)))
            lines.append("-- 最近检查：\(age) 秒前 · PF 状态为最近验证结果 | color=#595959,#C7C7CC size=12")
        }
        if !modern, status.daemonRunning {
            lines.append("-- 旧版守护正在运行，PF 状态尚未验证 | color=#92400E,#FCD34D size=12")
            lines.append("-- 旧版不生成新版状态报告；这不代表文件权限损坏 | color=#595959,#C7C7CC size=12")
        } else if !status.reason.isEmpty {
            lines.append("-- 原因：\(clean(status.reason)) | color=#B91C1C,#FF6961 size=12")
        }
        let actionHelper = CLI.userDirectory.appendingPathComponent("bin/surge-guard-action").path
        let renderer = CLI.userDirectory.appendingPathComponent("bin/surge-guard-ui").path
        let normalBinary = FileManager.default.isExecutableFile(atPath: renderer) ? renderer : Paths.binary
        func command(_ title: String, _ args: [String], root: Bool = false, depth: String = "--") {
            let recoverable = root && args.count == 1 && ["start", "restart", "unlock", "backup", "rollback", "restore-policy", "logs", "doctor"].contains(args[0]) && FileManager.default.isExecutableFile(atPath: actionHelper)
            let executable = recoverable ? actionHelper : root ? "/usr/bin/sudo" : normalBinary
            let parameters = (root && !recoverable ? [Paths.binary] : []) + args
            lines.append("\(depth) \(title) | bash=\(parameter(executable)) " + parameters.enumerated().map { "param\($0.offset + 1)=\(parameter($0.element))" }.joined(separator: " ") + " terminal=true refresh=true")
        }
        command("重新检查条件", ["check"])
        command("查看完整诊断", ["doctor"], root: true)
        command("查看最近 200 条日志", ["logs"], root: true)
        if modern { command("实时跟踪日志", ["logs", "--follow"], root: true) }
        command("编辑规则草稿", ["edit-config"])
        if modern { command("验证并应用规则草稿", ["configure", CLI.draft], root: true) }
        else { lines.append("-- 当前为旧版系统守护：分流门禁及备份命令尚未启用 | color=#92400E,#FCD34D size=12") }
        lines.append("-- 恢复与备份（离线可用）" + parentStyle)
        command("重启守护并等待验证（连接可能重建）", ["restart"], root: true, depth: "----")
        command("启动守护 / 恢复保护", ["start"], root: true, depth: "----")
        if modern {
            command("备份当前版本与配置", ["backup"], root: true, depth: "----")
            command("恢复上一版与配置（可能减少检查条件）", ["rollback"], root: true, depth: "----")
            command("恢复上一次规则配置", ["restore-policy"], root: true, depth: "----")
        } else { lines.append("---- 版本 / 规则备份与恢复：需升级系统守护 | color=#595959,#C7C7CC size=12") }
        command("应急解除阻断（关闭保护，启动或开机后恢复）", ["unlock"], root: true, depth: "----")
        for kind in ["update", "policy"] {
            let path = BackupManifest.pointer(kind)
            if (try? RootFiles.verify(path)) != nil,
               let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               let saved = try? JSON.decode(BackupManifest.self, from: data), (try? saved.validate()) != nil {
                let formatter = DateFormatter(); formatter.dateStyle = .short; formatter.timeStyle = .short
                lines.append("---- \(kind == "update" ? "版本" : "规则")备份：\(formatter.string(from: saved.createdAt)) | color=#595959,#C7C7CC size=12")
            }
        }
        if FileManager.default.isExecutableFile(atPath: CLI.gateBinary) {
            let gateStatus = (try? Command.checked(CLI.gateBinary, ["status"], timeout: 3)) ?? "SurgeGate 状态不可用"
            lines.append("SurgeGate · \(clean(gateStatus))" + parentStyle)
            for (title, args) in [("查看 SurgeGate 日志", ["logs"]), ("重启 SurgeGate", ["restart"]), ("编辑应用配置", ["edit-config"]), ("有序重启系统", ["shutdown", "--action", "restart"]), ("有序关机", ["shutdown", "--action", "shutdown"])] {
                lines.append("-- \(title) | bash=\(parameter(CLI.gateBinary)) " + args.enumerated().map { "param\($0.offset + 1)=\(parameter($0.element))" }.joined(separator: " ") + " terminal=true refresh=true")
            }
        } else {
            let legacyGate = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".surge_gate/surge_gate.py").path
            let gateTitle = FileManager.default.fileExists(atPath: legacyGate) ? "旧版待迁移，运行状态未验证" : "未安装"
            lines.append("SurgeGate · \(gateTitle) | color=#595959,#C7C7CC")
            lines.append("-- 有序重启 / 关机：需先安装 SurgeGate | color=#595959,#C7C7CC")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
