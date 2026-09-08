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
        guard try !loaded() else { throw GuardError("Run the installed binary's unlock command before reinstalling") }
        let lock = try RuntimeLock()
        defer { withExtendedLifetime(lock) {} }
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
        // A signed/compiled source executable may be user-owned; it is copied
        // once into the protected system path. No root-executed user script.
        let source = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath().path
        guard source != Paths.binary else { throw GuardError("Install using the freshly built binary, not the installed copy") }
        var existing = stat()
        if lstat(Paths.binary, &existing) == 0 { try RootFiles.verify(Paths.binary) }
        try RootFiles.write(Policy.blocked, to: Policy.anchorPath, mode: 0o644)
        try Command.checked("/sbin/pfctl", ["-n", "-f", "-"], input: updated)
        let backup = Paths.pfConfig + ".surge-guard.backup"
        if !FileManager.default.fileExists(atPath: backup) {
            try RootFiles.write(original, to: backup)
        }
        try Command.checked("/usr/bin/install", ["-o", "root", "-g", "wheel", "-m", "755", source, Paths.binary])
        try RootFiles.write(updated, to: Paths.pfConfig, mode: 0o644)
        try RootFiles.write(plist, to: Paths.plist, mode: 0o644)
        print("Installed. Not active yet. Start with: sudo \(Paths.binary) start")
        print("The daemon will also be loaded at the next boot. Keep the unlock command available offline.")
    }

    static func start() throws {
        guard try !loaded() else { throw GuardError("Service is already loaded; use status") }
        try RootFiles.verify(Paths.binary)
        try RootFiles.verify(Paths.plist)
        try RootFiles.verify(Policy.anchorPath)
        try Firewall().prepareAttachment()
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
        print("Surge Guard unloaded and its block removed. Other firewall rules are untouched.")
        print("This is temporary: start or reboot arms protection again. Use uninstall to remove it permanently.")
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
