import Foundation
import SurgeGuardCore
import Darwin

enum Admin {
    static var plist: String { """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>Label</key><string>\(Paths.label)</string>
      <key>ProgramArguments</key><array><string>\(Paths.binary)</string><string>run</string></array>
      <key>RunAtLoad</key><true/>
      <key>KeepAlive</key><true/>
      <key>ThrottleInterval</key><integer>3</integer>
      <key>Umask</key><integer>63</integer>
    </dict></plist>

    """ }

    static func loaded() throws -> Bool {
        try Command.run("/bin/launchctl", ["print", "system/" + Paths.label]).status == 0
    }

    static func install() throws {
        let upgrading = try loaded()
        for path in ["/Library/PrivilegedHelperTools", "/Library/LaunchDaemons", "/private/etc", "/private/etc/pf.anchors"] {
            if !FileManager.default.fileExists(atPath: path) {
                try RootFiles.verify(URL(fileURLWithPath: path).deletingLastPathComponent().path, directory: true)
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o755])
            }
            try RootFiles.verify(path, directory: true)
        }
        try RootFiles.verify(Paths.pfConfig)
        let original = try String(contentsOfFile: Paths.pfConfig)
        let updated = try Policy.attaching(to: original)
        try RootFiles.preparePublicState()
        if FileManager.default.fileExists(atPath: Paths.configuration) { _ = try Configuration.load() }
        // A signed/compiled source executable may be user-owned; it is copied
        // once into the protected system path. No root-executed user script.
        let source = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath().path
        guard source != Paths.binary else { throw GuardError("Install using the freshly built binary, not the installed copy") }
        var existing = stat()
        if lstat(Paths.binary, &existing) == 0 { try RootFiles.verify(Paths.binary) }
        try Command.checked("/sbin/pfctl", ["-n", "-f", "-"], input: updated)
        let stagedBinary = Paths.binary + ".new." + UUID().uuidString
        try Command.checked("/usr/bin/install", ["-o", "root", "-g", "wheel", "-m", "755", source, stagedBinary])
        defer { try? FileManager.default.removeItem(atPath: stagedBinary) }
        if upgrading, let config = try? Configuration.load(), config.mode == "routes" {
            // Verify the new privilege-drop/CLI path before stopping the old gate.
            _ = try Probe.privilegedSession(configuration: config, helperPath: stagedBinary)
            EventLog.write("upgrade_probe_verified", message: "New user-session probe succeeded before service replacement")
        }
        if upgrading {
            // The old daemon handles TERM by blocking. Never unlock to update.
            try Command.checked("/bin/launchctl", ["bootout", "system/" + Paths.label], timeout: 15)
        }
        do {
            let lock = try RuntimeLock()
            defer { withExtendedLifetime(lock) {} }
            if upgrading {
                let firewall = Firewall()
                try firewall.prepareAttachment()
                try firewall.block()
            }
            try RootFiles.write(Policy.blocked, to: Policy.anchorPath, mode: 0o644)
            let backup = Paths.pfConfig + ".surge-guard.backup"
            if !FileManager.default.fileExists(atPath: backup) {
                try RootFiles.write(original, to: backup)
            }
            guard rename(stagedBinary, Paths.binary) == 0 else { throw GuardError("Cannot atomically replace installed binary") }
            try RootFiles.write(updated, to: Paths.pfConfig, mode: 0o644)
            try RootFiles.write(plist, to: Paths.plist, mode: 0o644)
            if !FileManager.default.fileExists(atPath: Paths.configuration) {
                try RootFiles.write(try JSON.encode(Configuration.enhanced, pretty: true), to: Paths.configuration, mode: 0o644)
            }
        }
        if upgrading { try start() }
        EventLog.write(upgrading ? "installation_updated" : "installation_created", message: "Root components installed; existing policy retained")
        print(upgrading ? "Updated and restarted. Verify status." : "Installed. Start with: sudo \(Paths.binary) start")
        print("The daemon will also be loaded at the next boot. Keep the unlock command available offline.")
    }

    static func start() throws {
        guard try !loaded() else { throw GuardError("Service is already loaded; use status") }
        try RootFiles.verify(Paths.binary)
        try RootFiles.verify(Paths.plist)
        try RootFiles.verify(Policy.anchorPath)
        try Firewall().prepareAttachment()
        if FileManager.default.fileExists(atPath: Paths.unlockMarker) {
            try RootFiles.verify(Paths.unlockMarker)
            try FileManager.default.removeItem(atPath: Paths.unlockMarker)
        }
        // Clear a persisted launchd disable override so subsequent boots load it.
        try Command.checked("/bin/launchctl", ["enable", "system/" + Paths.label])
        try Command.checked("/bin/launchctl", ["bootstrap", "system", Paths.plist], timeout: 10)
        print("Service loaded. Verify with sudo \(Paths.binary) status")
    }

    static func unlock() throws {
        if try loaded() {
            try Command.checked("/bin/launchctl", ["bootout", "system/" + Paths.label], timeout: 15)
        }
        // Serialize with the daemon's final block operation before flushing.
        let lock = try RuntimeLock()
        defer { withExtendedLifetime(lock) {} }
        try Firewall().unlock()
        try? FileManager.default.removeItem(atPath: Paths.snapshot)
        try RootFiles.preparePublicState()
        let marker = try JSONSerialization.data(withJSONObject: ["boot_id": SystemClock.bootID])
        try RootFiles.write(String(decoding: marker, as: UTF8.self), to: Paths.unlockMarker, mode: 0o644)
        EventLog.write("manual_unlock", level: "warning", message: "Service stopped and gate removed; start/reboot re-arms protection")
        print("Surge Guard unloaded and its block removed. Other firewall rules are untouched.")
        print("This is temporary: start or reboot arms protection again. Use uninstall to remove it permanently.")
    }

    static func restart() throws {
        guard try loaded() else { throw GuardError("Service is not loaded; use start") }
        // launchd sends TERM, allowing the daemon to install block rules.
        try Command.checked("/bin/launchctl", ["kill", "SIGTERM", "system/" + Paths.label])
        EventLog.write("restart_requested", message: "Requested normal stop; launchd KeepAlive restarts the service")
        print("Restart requested. Inspect status after launchd starts the new process.")
    }

    static func uninstall() throws {
        try RootFiles.verify(Paths.pfConfig)
        let config = try String(contentsOfFile: Paths.pfConfig)
        let updated = try Policy.removingAttachment(from: config)
        guard config != updated else { throw GuardError("No exact managed attachment found; refusing automatic uninstall") }
        try Command.checked("/sbin/pfctl", ["-n", "-f", "-"], input: updated)
        try unlock()
        try RootFiles.write(updated, to: Paths.pfConfig, mode: 0o644)
        // The now-empty live anchor is harmless until PF is next reloaded.
        // Avoid reloading the main ruleset just to remove this empty call.
        for path in [Paths.plist, Policy.anchorPath, Paths.binary] {
            if FileManager.default.fileExists(atPath: path) {
                try RootFiles.verify(path)
                try FileManager.default.removeItem(atPath: path)
            }
        }
        print("Removed binary, LaunchDaemon, anchor file and managed pf.conf lines. Original backup retained at \(Paths.pfConfig).surge-guard.backup")
    }
}
