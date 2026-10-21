import Foundation
import Darwin
import SurgeGuardCore

enum PacketAuditAdmin {
    static func command(_ args: [String]) throws {
        let action = args[0]
        if action == "audit-request-sample" {
            guard args.count == 1 else { throw GuardError("Unexpected request sample arguments") }
            print(try JSON.encode(SurgeRequestAuditBatch.collect()))
            return
        }
        if action == "audit-status" {
            guard args.count == 1 || args == ["audit-status", "--json"] else { throw GuardError("Usage: audit-status [--json]") }
            if let value = PacketAuditSnapshot.read() { print(try JSON.encode(value, pretty: !args.contains("--json"))) }
            else { print("{\"state\":\"unknown_or_stopped\",\"no_bypass_verified\":false,\"reason\":\"no_fresh_verified_capture_status\"}") }
            return
        }
        guard ["audit-install", "audit-start", "audit-stop", "audit-uninstall", "audit-preview", "audit-coverage", "audit-run", "audit-capture"].contains(action) else {
            throw GuardError("Unknown audit command")
        }
        guard geteuid() == 0 else { throw GuardError("\(action) requires administrator privileges; recording is not enabled") }
        var configuration: PacketAuditConfiguration?
        if action == "audit-install" {
            configuration = FileManager.default.fileExists(atPath: PacketAudit.configuration) ? try PacketAuditConfiguration.load() : PacketAuditConfiguration()
            var index = 1, seen = Set<String>()
            while index < args.count {
                let option = args[index]
                guard index + 1 < args.count, seen.insert(option).inserted else { throw GuardError("Invalid or duplicate audit option") }
                if option == "--megabytes", let value = Int(args[index + 1]) { configuration!.capacityMegabytes = value }
                else if option == "--timezone" { configuration!.timeZone = args[index + 1] }
                else { throw GuardError("Unknown audit option") }
                index += 2
            }
            try configuration!.validate()
        } else { guard args.count == 1 else { throw GuardError("Unexpected audit arguments") } }
        let management = ["audit-install", "audit-start", "audit-stop", "audit-uninstall"].contains(action) ? try RuntimeLock(management: true) : nil
        defer { withExtendedLifetime(management) {} }
        switch action {
        case "audit-install": try install(configuration!)
        case "audit-start": try start()
        case "audit-stop":
            try Command.checked("/bin/launchctl", ["disable", "system/" + PacketAudit.label])
            try stop()
            print("Packet recording stopped and automatic startup disabled. Captures retained; audit-start re-enables recording. PF was not changed.")
        case "audit-uninstall":
            try stop()
            for path in [PacketAudit.plist, PacketAudit.binary] where FileManager.default.fileExists(atPath: path) {
                try RootFiles.verify(path); try FileManager.default.removeItem(atPath: path)
            }
            print("Packet recorder removed; private captures retained. PF was not changed.")
        case "audit-preview": try preview()
        case "audit-coverage":
            try PacketAudit.prepare()
            let config = try PacketAuditConfiguration.load()
            var files: [PacketCaptureRange] = []
            for name in PacketAudit.fileNames where FileManager.default.fileExists(atPath: PacketAudit.directory + "/" + name) {
                do {
                    files.append(try PacketCaptureRange.read(PacketAudit.directory + "/" + name,
                                                            maximumBytes: Int64(config.capacityMegabytes / 8) * 1_000_000 + 65_536))
                } catch { files.append(PacketCaptureRange(file: name, readError: String(describing: error))) }
            }
            var displayFiles = try JSONSerialization.jsonObject(with: Data(JSON.encode(files).utf8)) as! [[String: Any]]
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: config.timeZone)
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS XXXXX"
            for index in files.indices {
                displayFiles[index]["earliest_display"] = files[index].earliest.map { formatter.string(from: $0) }
                displayFiles[index]["latest_display"] = files[index].latest.map { formatter.string(from: $0) }
            }
            let report: [String: Any] = ["files": displayFiles,
                                       "no_bypass_verified": false, "continuous_coverage_verified": false,
                                       "earlier_overwritten_history": "unavailable", "time_zone": config.timeZone,
                                       "note": "Ranges describe retained observed packets, not proof that every packet was captured"]
            print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]), as: UTF8.self))
        case "audit-run": try PacketAuditService().run()
        case "audit-capture":
            // Foundation starts children in another process group; rejoin so launchd also reaps tcpdump after a supervisor crash.
            try PacketAudit.joinParentProcessGroup()
            let config = try PacketAuditConfiguration.load()
            let arguments = ["/usr/sbin/tcpdump"] + (try PacketAudit.arguments(megabytes: config.capacityMegabytes))
            let pointers = arguments.map { strdup($0) } + [nil]
            defer { pointers.forEach { free($0) } }
            execv("/usr/sbin/tcpdump", pointers)
            throw GuardError("Cannot execute fixed packet recorder: errno \(errno)")
        default: break
        }
    }

    static var plist: String { """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>Label</key><string>\(PacketAudit.label)</string>
      <key>ProgramArguments</key><array><string>\(PacketAudit.binary)</string><string>audit-run</string></array>
      <key>RunAtLoad</key><true/>
      <key>KeepAlive</key><true/>
      <key>ThrottleInterval</key><integer>10</integer>
      <key>ExitTimeOut</key><integer>10</integer>
      <key>AbandonProcessGroup</key><false/>
      <key>Umask</key><integer>63</integer>
      <key>StandardOutPath</key><string>/dev/null</string>
      <key>StandardErrorPath</key><string>/dev/null</string>
    </dict></plist>
    """ }

    static func loaded() throws -> Bool {
        let query = try Command.run("/bin/launchctl", ["print", "system/" + PacketAudit.label])
        if query.status == 0 { return true }
        _ = try StatusReport.serviceRunning(query)
        return false
    }

    static func waitForExit() throws {
        let fd = open(PacketAudit.directory + "/capture.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw GuardError("Cannot open audit service lock") }
        defer { close(fd) }
        try RootFiles.verify(PacketAudit.directory + "/capture.lock")
        try RuntimeLock.acquire(fd, timeout: 20)
    }

    static func stop() throws {
        try PacketAudit.prepare()
        var capturePID: Int32?
        if (try? RootFiles.verify(PacketAudit.snapshot)) != nil,
           let data = try? Data(contentsOf: URL(fileURLWithPath: PacketAudit.snapshot)),
           let status = try? JSON.decode(PacketAuditSnapshot.self, from: data), status.bootId == SystemClock.bootID,
           let pid = status.capturePid, pid > 1 { capturePID = pid }
        if try loaded() { try Command.checked("/bin/launchctl", ["bootout", "system/" + PacketAudit.label], timeout: 15) }
        try waitForExit()
        if let pid = capturePID {
            let deadline = SystemClock.seconds + 20
            while true {
                if kill(pid, 0) != 0 {
                    guard errno == ESRCH else { throw GuardError("Cannot confirm capture child exit") }
                    break
                }
                guard SystemClock.seconds < deadline else { throw GuardError("Capture child has not exited; refusing to replace recording files") }
                usleep(50_000)
            }
        }
    }

    static func start(previousRun: String? = nil) throws {
        try RootFiles.verify(PacketAudit.binary)
        try RootFiles.verify(PacketAudit.plist)
        _ = try PacketAuditConfiguration.load()
        try Command.checked("/bin/launchctl", ["enable", "system/" + PacketAudit.label])
        if try !loaded() { try Command.checked("/bin/launchctl", ["bootstrap", "system", PacketAudit.plist], timeout: 5) }
        let deadline = SystemClock.seconds + 20
        while SystemClock.seconds < deadline {
            if let status = PacketAuditSnapshot.read(), status.captureReadyAt != nil, status.counters != nil,
               let measured = status.countersUptime, measured <= SystemClock.seconds, SystemClock.seconds - measured < 10,
               status.state == "capturing" || status.reason == "capture_drops_reported",
               previousRun == nil || status.runId != previousRun {
                print("Packet capture opened: \(status.state). Packet attribution and no-bypass completeness remain unverified.")
                return
            }
            usleep(100_000)
        }
        throw GuardError("Cannot verify fresh packet capture; inspect audit status/events. No PF changes were made")
    }

    static func install(_ configuration: PacketAuditConfiguration) throws {
        try configuration.validate()
        try PacketAudit.prepare()
        try RootFiles.preparePublicState()
        for path in ["/Library/PrivilegedHelperTools", "/Library/LaunchDaemons"] {
            if !FileManager.default.fileExists(atPath: path) {
                try RootFiles.verify("/Library", directory: true)
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o755])
            }
            try RootFiles.verify(path, directory: true)
        }
        let source = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath().path
        guard source != PacketAudit.binary else { throw GuardError("Install from the newly built binary") }
        let components = [PacketAudit.binary, PacketAudit.plist, PacketAudit.configuration]
        let backup = PacketAudit.directory + "/previous"
        if !FileManager.default.fileExists(atPath: backup) {
            try FileManager.default.createDirectory(atPath: backup, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try RootFiles.verify(backup, directory: true)
        let wasLoaded = try loaded()
        let previousRun = PacketAuditSnapshot.read()?.runId
        var saved = Set<String>()
        for path in components where FileManager.default.fileExists(atPath: path) {
            try RootFiles.verify(path)
            let destination = backup + "/" + URL(fileURLWithPath: path).lastPathComponent
            if FileManager.default.fileExists(atPath: destination) { try RootFiles.verify(destination) }
            try Command.checked("/usr/bin/install", ["-o", "root", "-g", "wheel", "-m", "600", path, destination])
            saved.insert(path)
        }
        let staged = PacketAudit.binary + ".new." + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: staged) }
        try Command.checked("/usr/bin/install", ["-o", "root", "-g", "wheel", "-m", "755", source, staged])
        try stop()
        do {
            guard rename(staged, PacketAudit.binary) == 0 else { throw GuardError("Cannot install packet audit helper") }
            try RootFiles.write(try JSON.encode(configuration), to: PacketAudit.configuration)
            try RootFiles.write(plist, to: PacketAudit.plist, mode: 0o644)
            try start(previousRun: previousRun)
        } catch {
            let original = String(describing: error)
            do {
                try stop()
                for path in components {
                    if saved.contains(path) {
                        let savedPath = backup + "/" + URL(fileURLWithPath: path).lastPathComponent
                        try RootFiles.verify(savedPath)
                        let mode = path == PacketAudit.binary ? "755" : path == PacketAudit.plist ? "644" : "600"
                        try Command.checked("/usr/bin/install", ["-o", "root", "-g", "wheel", "-m", mode, savedPath, path])
                    } else if FileManager.default.fileExists(atPath: path) {
                        try RootFiles.verify(path)
                        try FileManager.default.removeItem(atPath: path)
                    }
                }
                if wasLoaded { try start() }
            } catch { throw GuardError("Audit install failed: \(original); rollback also failed: \(error). PF was not changed") }
            throw GuardError("Audit install failed: \(original); previous audit installation restored. PF was not changed")
        }
    }

    static func preview() throws {
        try PacketAudit.prepare()
        let configuration = try PacketAuditConfiguration.load()
        let files = PacketAudit.fileNames.filter { FileManager.default.fileExists(atPath: PacketAudit.directory + "/" + $0) }
        print("Capture preview: first 25 packets in each retained file, up to 200 packets; time zone \(configuration.timeZone).")
        print("This is a limited preview, not a completeness/bypass verdict. Live files may change while being read.")
        for file in files {
            print("=== \(file) ===")
            let result = try Command.run("/usr/bin/env", ["TZ=" + configuration.timeZone, "/usr/sbin/tcpdump", "-n", "-q", "-tttt",
                                         "-k", "INPD", "-c", "25", "-r", PacketAudit.directory + "/" + file], timeout: 5)
            let safeOutput = String(result.output.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t" })
            print(safeOutput, terminator: "")
            if result.status != 0 { print("Incomplete/live capture read: \(result.diagnostics)") }
        }
        print("Use the private pcap-ng files for full retained packet analysis; overwritten or uncaptured history is unavailable.")
    }
}
