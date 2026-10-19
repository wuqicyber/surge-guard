import Foundation

public enum LogReader {
    private static func reason(_ message: String) -> String {
        let labels = ["route_policy_mismatch": "分流策略与配置不一致", "rule_probe_failed": "无法查询 Surge 分流",
                      "rule_probe_expired": "分流结果已过期，等待重新验证", "rule_probe_pending": "等待第一次分流检查",
                      "configuration_invalid": "联网规则配置无效", "enhanced_mode_disabled": "增强模式已关闭",
                      "outbound_mode_is_direct": "Surge 当前为 Direct 模式，需要 Rule 模式",
                      "outbound_mode_is_proxy": "Surge 当前为 Global Proxy 模式，需要 Rule 模式",
                      "readiness_probe_failed": "无法确认增强模式接管状态",
                      "incomplete_route_results": "分流检查结果不完整", "rule_probe_configuration_changed": "分流查询期间配置已变化，等待重新检查",
                      "signed Surge process missing": "未找到签名有效的 Surge 进程",
                      "Surge network extension is not connected": "Surge 网络扩展未连接",
                      "primary network service is not Surge": "主网络服务不属于 Surge",
                      "Surge VIF is not up with its expected IPv4 address": "Surge 虚拟网卡或地址未就绪",
                      "Surge does not own the IPv4 default route": "IPv4 默认路由未由 Surge 接管",
                      "the global IPv6 route is not owned by Surge": "IPv6 主路由未由 Surge 接管"]
        return message.components(separatedBy: "; ").map { part in
            guard let key = labels.keys.first(where: { part == $0 || part.hasPrefix($0 + ":") }) else { return text(part) }
            if key == "rule_probe_failed" {
                let cause: String
                if part.contains("Surge isn't running on the local machine") { cause = "Surge CLI 暂时无法连接本机 Surge" }
                else if part.contains("timed out") { cause = "Surge CLI 查询超时" }
                else {
                    let last = part.components(separatedBy: .newlines).last ?? part
                    let brief = last.replacingOccurrences(of: "surge-guard: ", with: "")
                        .components(separatedBy: " UserInfo=")[0]
                    cause = String(text(brief).prefix(240)) + "（完整错误见 --json）"
                }
                return labels[key]! + " [\(key)]：" + cause
            }
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
        let legacyProgress = event == "gate_state" && message.hasSuffix(" application(s) pending") ? Int(message.split(separator: " ").first ?? "") : nil
        let unavailable = event == "gate_status_unavailable" || (event == "gate_state" && message.hasPrefix("unknown:"))
        let permissionDenied = (details["reason"] as? String ?? message).contains("Permission denied") ||
            (details["reason"] as? String ?? message).contains("permission to view")
        let titles = ["daemon_started": "守护启动", "daemon_stopped": "守护停止，保留阻断",
                      "route_decision_changed": "分流结果变化", "configuration_loaded": "配置已加载",
                      "configuration_installed": "配置已应用", "rule_probe_failed": "分流查询失败",
                      "pf_reconciled": "PF 规则已重新校验", "pf_unverified": "无法确认防火墙保护",
                      "manual_unlock": "已手动解除保护", "restart_requested": "已请求正常重启",
                      "backup_created": "恢复备份已保存", "backup_restored": "已恢复上一次备份",
                      "upgrade_failed": "升级失败", "rollback_completed": "升级失败，上一版已恢复",
                      "rollback_failed": "自动恢复失败，请使用离线恢复入口",
                      "installation_updated": "系统守护升级完成", "installation_created": "系统守护安装完成",
                      "upgrade_probe_verified": "升级前的用户会话检查通过", "command_failed": "操作失败",
                      "reconciliation_failed": "守护检查失败，正在尝试阻断并重启", "fail_closed": "已验证阻断，等待守护恢复",
                      "gate_started": "应用恢复服务启动", "application_restored": "应用启动请求已完成",
                      "application_already_running": "应用已在运行，无需重新启动", "surge_launch_requested": "已请求启动 Surge",
                      "gate_state": "应用门禁状态变化", "gate_ready": "应用门禁已就绪",
                      "gate_restore_progress": "正在恢复应用", "gate_waiting": "等待系统门禁放行",
                      "gate_status_unavailable": "系统门禁状态暂不可读", "gate_status_recovered": "系统门禁状态读取已恢复",
                      "gate_error": "应用门禁异常",
                      "application_restore_failed": "应用启动失败，保留待重试", "shutdown_started": "开始有序退出",
                      "shutdown_aborted": "关机已中止，会话已保留", "shutdown_requested": "已请求系统关机",
                      "legacy_migrated": "旧配置已迁移", "migration_app_unresolved": "旧应用名称需要补全 Bundle ID"]
        let title = unavailable ? "系统门禁状态暂不可读" : legacyProgress.map { $0 == 0 ? "应用门禁已就绪" : "正在恢复应用" } ??
            (event == "gate_changed" ? (message == "allowed" ? "ALLOWED / 已放行" : "BLOCKED / 已阻断") : titles[event] ?? event)
        var timestamp = record["time"] as? String ?? "—"
        if let date = ISO8601DateFormatter().date(from: timestamp) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss XXXXX"
            timestamp = formatter.string(from: date)
        }
        let level = unavailable ? "WARNING" : (record["level"] as? String ?? "info").uppercased()
        let component = record["component"] as? String ?? (record["app"] != nil || event.hasPrefix("application_") || event == "gate_state" ? "SurgeGate" : "SurgeGuard")
        var lines = ["\(text(timestamp))  [\(text(level))] \(text(component)) · \(text(title))"]
        let pending = (details["pending_count"] as? Int) ?? legacyProgress
        if unavailable {
            let serviceQueryFailed = (details["reason"] as? String ?? message).contains("service_query_failed")
            lines.append(permissionDenied ? "  原因：读取 status.json 时权限被拒绝（EACCES/13）" : serviceQueryFailed ? "  原因：无法查询系统守护进程状态" : "  原因：无法取得近期有效的系统门禁状态")
            lines.append("  影响：应用恢复暂停；这条日志本身不能判定网络已断开")
            lines.append("  处理：待读取恢复后继续；持续出现时查看完整诊断")
        } else if event == "gate_status_recovered" {
            lines.append(details["guard_state"] as? String == "allowed" ? "  状态：系统门禁读取已恢复，可以继续恢复应用" : "  状态：系统门禁读取已恢复，当前未放行，应用恢复仍暂停")
        } else if event == "gate_waiting" || (event == "gate_state" && ["blocked:", "stopped:", "unlocked:"].contains(where: { message.hasPrefix($0) })) {
            let state = details["guard_state"] as? String ?? String(message.prefix(while: { $0 != ":" }))
            let cause = details["reason"] as? String ?? message.split(separator: ":", maxSplits: 1).dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
            let states = ["blocked": "系统门禁已阻断", "stopped": "未验证到运行中的系统守护", "unlocked": "系统保护已手动解除"]
            lines.append("  状态：\(states[state] ?? "等待系统门禁")，应用恢复暂停")
            if !cause.isEmpty { lines.append("  原因：\(reason(cause))") }
        } else if event == "gate_ready" || legacyProgress == 0 {
            lines.append("  状态：应用恢复完成，等待后续状态变化")
        } else if event == "gate_restore_progress" || legacyProgress != nil {
            lines.append("  状态：按配置顺序恢复应用")
        } else if event == "application_already_running" {
            lines.append("  结果：沿用正在运行的应用，本次没有发送启动请求")
        } else if event == "application_restored" {
            lines.append(record["component"] == nil ? "  结果：应用恢复步骤已完成（旧版事件不能区分原本已运行的应用）" : "  结果：已完成应用启动请求")
        } else if event == "gate_changed" {
            lines.append(message == "allowed" ? "  状态：普通联网已放行，配置条件与 PF 检查通过" : "  状态：普通联网已阻断，条件通过后自动恢复")
            if message != "allowed" { lines.append("  原因：\(reason(message))") }
        } else if !message.isEmpty && message != "allowed" { lines.append("  说明：\(reason(message))") }
        if let pending { lines.append("  恢复进度：剩余 \(pending) 个应用") }
        if let routes = details["routes"] as? [[String: Any]] {
            for route in routes {
                lines.append("  \((route["ready"] as? Bool) == true ? "✓" : "✗") \(text(route["url"]))")
                lines.append("    预期分流组：\(text(route["expected_group"]))")
                lines.append("    实际分流组：\(text(route["actual_group"]))\n    最终策略：\(text(route["final_policy"]))")
            }
        }
        if let app = record["app"] as? String, !app.isEmpty { lines.append("  应用: \(text(app))") }
        let metadata = [details["mode"].map { "配置=\(text($0))" }, details["pf"].map { "PF=\(text($0))" },
                        details["outbound_mode"].map { "出站模式=\(text($0))" }, details["duration_ms"].map { "耗时=\(text($0))ms" },
                        details["guard_state"].map { "系统门禁=\(text($0))" },
                        details["backup_id"].map { "备份=\(text($0))" }, details["kind"].map { "备份类型=\(text($0))" }].compactMap { $0 }
        if !metadata.isEmpty { lines.append("  " + metadata.joined(separator: "  ")) }
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
        try render(pipe.fileHandleForReading, json: json)
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw GuardError("Log reader exited with status \(task.terminationStatus)") }
    }

    public static func render(_ input: FileHandle, json: Bool = false) throws {
        var pending = Data()
        while true {
            let chunk = input.availableData
            if chunk.isEmpty { break }
            pending.append(chunk)
            guard pending.count <= 2_097_152 else { throw GuardError("Log line exceeded limits") }
            while let newline = pending.firstIndex(of: 10) {
                let line = String(decoding: pending[..<newline], as: UTF8.self)
                let rendered = format(line, json: json) + "\n"
                try FileHandle.standardOutput.write(contentsOf: Data(rendered.utf8))
                pending.removeSubrange(...newline)
            }
        }
        if !pending.isEmpty { print(format(String(decoding: pending, as: UTF8.self), json: json)) }
    }
}
