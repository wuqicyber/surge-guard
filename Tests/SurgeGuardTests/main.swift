import Foundation
import SurgeGuardCore

// Standalone checks also work with Command Line Tools, where XCTest may not
// be installed. Throw on failure so checks still work in optimized builds.
func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw GuardError(message) }
}

func rejects(_ operation: () throws -> Void) throws {
    do { try operation() } catch { return }
    throw GuardError("Expected rejection")
}

do {
    for mask in 0..<64 {
        let state = Readiness(trustedProcess: mask & 1 != 0,
                              surgeService: mask & 2 != 0, connected: mask & 4 != 0,
                              vifUp: mask & 8 != 0, ownsDefaultRoute: mask & 16 != 0,
                              ipv6Safe: mask & 32 != 0)
        try check(state.ready == (mask == 63), "Incorrect readiness for mask \(mask)")
        try check(state.reasons.isEmpty == (mask == 63), "Missing failure reason")
    }
    print("PASS: all 64 readiness combinations")

    let config = """
    # Existing configuration
    set skip on lo0
    scrub-anchor "com.apple/*"
    nat-anchor "com.apple/*"
    anchor "com.apple/*"
    load anchor "com.apple" from "/etc/pf.anchors/com.apple"
    # User comment must survive

    """
    let installed = try Policy.attaching(to: config)
    let reinstalled = try Policy.attaching(to: installed)
    let removed = try Policy.removingAttachment(from: installed)
    try check(installed == reinstalled, "Installation must be idempotent")
    try check(removed == config, "Removal must preserve original configuration")
    try check(installed.range(of: Policy.attachment)!.lowerBound <
              installed.range(of: "\nanchor \"com.apple/*\"")!.lowerBound, "Wrong anchor order")
    print("PASS: PF configuration installation/removal round trip")

    for invalid in ["", Policy.begin, Policy.end,
                    "anchor \"com.apple/*\"\nanchor \"com.apple/*\"\n",
                    "# io.github.surge-guard\nanchor \"com.apple/*\"\n"] {
        try rejects { _ = try Policy.attaching(to: invalid) }
    }
    let modified = Policy.configBlock.replacingOccurrences(of: Policy.end, with: "pass quick all\n" + Policy.end)
    try rejects { _ = try Policy.removingAttachment(from: modified) }
    try rejects { _ = try Policy.removingAttachment(from: Policy.configBlock + Policy.configBlock) }
    print("PASS: malformed/edited PF configuration is rejected")

    try check(Policy.attachedFirst(Policy.attachment + " all\nanchor \"com.apple/*\" all\n"), "Valid attachment rejected")
    let liveMacRules = "scrub-anchor \"com.apple/*\" all fragment reassemble\n" + Policy.attachment + " all\nanchor \"com.apple/*\" all\n"
    try check(Policy.attachedFirst(liveMacRules), "macOS normalization rule mistaken for a filter")
    try check(!Policy.attachedFirst("scrub-anchor \"com.apple/*\" all\npass quick all\n" + Policy.attachment + " all\n"), "Filter before guard accepted after normalization")
    for invalid in ["pass quick all\n" + Policy.attachment + " all\n",
                    "anchor \"com.apple/*\" all\n" + Policy.attachment + " all\n",
                    "anchor \"io.github.surge-guard-impostor\" all\n", ""] {
        try check(!Policy.attachedFirst(invalid), "Unsafe filter ordering accepted")
    }
    print("PASS: live PF attachment order")

    try check(Policy.defaultInterface("route to: default\n  interface: utun108\n") == "utun108", "Dynamic utun parsing failed")
    try check(Policy.defaultInterface("   interface: en0\n") == "en0", "Physical interface parsing failed")
    try check(Policy.defaultInterface("route: not in table") == nil, "Missing route accepted")
    try check(Policy.defaultInterface("interface: utun9 extra") == nil, "Malformed route accepted")
    print("PASS: route parser")

    try check(Policy.ipv6Safe(primaryInterface: nil, surgeInterface: "utun9"), "Missing global IPv6 route must be safe")
    try check(Policy.ipv6Safe(primaryInterface: "utun9", surgeInterface: "utun9"), "Surge IPv6 route rejected")
    try check(!Policy.ipv6Safe(primaryInterface: "en0", surgeInterface: "utun9"), "Physical IPv6 route accepted")
    try check(!Policy.ipv6Safe(primaryInterface: "", surgeInterface: "utun9"), "Malformed IPv6 state accepted")
    print("PASS: IPv6 safety gate")

    // -n is parse-only; never enable PF or touch live rules/state in tests.
    let parser = try Command.run("/sbin/pfctl", ["-n", "-a", Policy.anchor, "-f", "-"], input: Policy.blocked)
    try check(parser.status == 0, "PF parser rejected policy: \(parser.combined)")
    print("PASS: native macOS PF parser")

    var started = Date()
    do {
        _ = try Command.run("/bin/sleep", ["5"], timeout: 0.05)
        throw GuardError("Expected timeout")
    } catch {
        try check(String(describing: error).contains("/bin/sleep 5 timed out"), "Timeout omitted command context")
    }
    try check(Date().timeIntervalSince(started) < 2, "Timeout did not terminate child")
    started = Date()
    try rejects { _ = try Command.run("/usr/bin/yes", [], timeout: 0.1) }
    try check(Date().timeIntervalSince(started) < 2, "Full pipe defeated timeout")
    print("PASS: timeout and output backpressure")

    try rejects { _ = try Command.checked("/usr/bin/false", []) }
    let literal = try Command.run("/usr/bin/printf", ["%s", "literal $(not-a-command)"])
    try check(literal.output == "literal $(not-a-command)", "Unexpected shell evaluation")
    // Constant test command only: exercise real stderr/stdout separation.
    let streams = try Command.run("/bin/sh", ["-c", "printf 'rules'; printf 'ALTQ warning' >&2"])
    try check(streams.output == "rules" && streams.diagnostics == "ALTQ warning", "Diagnostics contaminated structured output")
    print("PASS: command errors and literal arguments")
    // Read-only regression for the group-writable /var/run found on macOS.
    try check(!Paths.runtime.hasPrefix("/var/run/"), "Runtime state must not depend on a non-writable /var/run")
    try RootFiles.verify(URL(fileURLWithPath: Paths.runtime).deletingLastPathComponent().path, directory: true)
    print("PASS: protected runtime parent")
    print("All checks passed. Live packet blocking has NOT been tested by this program.")
} catch {
    fputs("FAIL: \(error)\n", stderr)
    exit(1)
}
