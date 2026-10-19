import Foundation

public enum LogReader {
    private static func reason(_ message: String) -> String {
        let labels = ["route_policy_mismatch": "分流策略与配置不一致", "rule_probe_failed": "无法查询 Surge 分流",
                      "rule_probe_expired": "分流结果已过期，等待重新验证", "rule_probe_pending": "等待第一次分流检查",
                      "configuration_invalid": "联网规则配置无效", "enhanced_mode_disabled": "增强模式已关闭",
                      "outbound_mode_is_direct": "Surge 当前为 Direct 模式，需要 Rule 模式",
                      "outbound_mode_is_proxy": "Surge 当前为 Global Proxy 模式，需要 Rule 模式",
                      "readiness_probe_failed": "无法确认增强模式接管状态",
                      "signed Surge process missing": "未找到签名有效的 Surge 进程",
                      "Surge network extension is not connected": "Surge 网络扩展未连接",
                      "primary network service is not Surge": "主网络服务不属于 Surge",
                      "Surge VIF is not up with its expected IPv4 address": "Surge 虚拟网卡或地址未就绪",
                      "Surge does not own the IPv4 default route": "IPv4 默认路由未由 Surge 接管",
                      "the global IPv6 route is not owned by Surge": "IPv6 主路由未由 Surge 接管"]
        return message.components(separatedBy: "; ").map { part in
            guard let key = labels.keys.first(where: { part == $0 || part.hasPrefix($0 + ":") }) else { return text(part) }
            return labels[key]! + " [\(key)]" + text(String(part.dropFirst(key.count)))
        }.joined(separator: "; ")
    }

    private static func text(_ value: Any?) -> String {
        guard let value else { return "—" }
        return String(String(describing: value).unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
    }

    public static func format(_ line: String, json: Bool = false) -> String {
        let record = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        if json {
            let object = record ?? ["event": "legacy_text", "message": line]
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
            return String(decoding: data, as: UTF8.self)
        }
        guard let record else { return text(line) }
        let event = record["event"] as? String ?? "event"
        let message = record["message"] as? String ?? ""
        let details = record["details"] as? [String: Any] ?? [:]
        let titles = ["daemon_started": "守护启动", "daemon_stopped": "守护停止，保留阻断",
                      "route_decision_changed": "分流结果变化", "configuration_loaded": "配置已加载",
                      "configuration_installed": "配置已应用", "rule_probe_failed": "分流查询失败",
                      "pf_reconciled": "PF 规则已重新校验", "pf_unverified": "无法确认防火墙保护",
                      "manual_unlock": "已手动解除保护", "restart_requested": "已请求正常重启",
                      "gate_started": "应用恢复服务启动", "application_restored": "应用已启动",
                      "application_restore_failed": "应用启动失败，保留待重试", "shutdown_started": "开始有序退出",
                      "shutdown_aborted": "关机已中止，会话已保留", "shutdown_requested": "已请求系统关机",
                      "legacy_migrated": "旧配置已迁移", "migration_app_unresolved": "旧应用名称需要补全 Bundle ID"]
        let title = event == "gate_changed" ? (message == "allowed" ? "ALLOWED / 已放行" : "BLOCKED / 已阻断") : titles[event] ?? event
        var timestamp = record["time"] as? String ?? "—"
        if let date = ISO8601DateFormatter().date(from: timestamp) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss XXXXX"
            timestamp = formatter.string(from: date)
        }
        let level = (record["level"] as? String ?? "info").uppercased()
        var lines = ["\(timestamp)  [\(level)] \(title)"]
        if !message.isEmpty && message != "allowed" { lines.append("  原因 / message: \(reason(message))") }
        if let routes = details["routes"] as? [[String: Any]] {
            for route in routes {
                lines.append("  \((route["ready"] as? Bool) == true ? "✓" : "✗") \(text(route["url"]))")
                lines.append("    预期 / expected group: \(text(route["expected_group"]))")
                lines.append("    实际 / actual group: \(text(route["actual_group"]))  最终节点 / final: \(text(route["final_policy"]))")
            }
        }
        if let app = record["app"] as? String, !app.isEmpty { lines.append("  应用: \(text(app))") }
        let metadata = [details["mode"].map { "配置=\(text($0))" }, details["pf"].map { "PF=\(text($0))" },
                        details["outbound_mode"].map { "出站模式=\(text($0))" }, details["duration_ms"].map { "耗时=\(text($0))ms" },
                        record["pid"].map { "pid=\(text($0))" }, details["run_id"].map { "run=\(text($0).prefix(8))" }].compactMap { $0 }
        if !metadata.isEmpty { lines.append("  " + metadata.joined(separator: "  ")) }
        lines.append("  event=\(text(event))")
        return lines.joined(separator: "\n")
    }

    public static func show(path: String, follow: Bool, json: Bool) throws {
        let task = Process(), pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        task.arguments = ["-n", "200"] + (follow ? ["-F"] : []) + [path]
        task.standardOutput = pipe
        try task.run()
        defer { if task.isRunning { task.terminate() } }
        pipe.fileHandleForWriting.closeFile()
        var pending = Data()
        while true {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            pending.append(chunk)
            guard pending.count <= 2_097_152 else { task.terminate(); throw GuardError("Log line exceeded limits") }
            while let newline = pending.firstIndex(of: 10) {
                let line = String(decoding: pending[..<newline], as: UTF8.self)
                let rendered = format(line, json: json) + "\n"
                try FileHandle.standardOutput.write(contentsOf: Data(rendered.utf8))
                pending.removeSubrange(...newline)
            }
        }
        if !pending.isEmpty { print(format(String(decoding: pending, as: UTF8.self), json: json)) }
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw GuardError("Log reader exited with status \(task.terminationStatus)") }
    }
}
