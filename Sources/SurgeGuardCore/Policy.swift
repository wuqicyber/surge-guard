import Foundation

public struct Readiness: Codable, Equatable {
    public var trustedProcess: Bool
    public var surgeService: Bool
    public var connected: Bool
    public var vifUp: Bool
    public var ownsDefaultRoute: Bool

    public init(trustedProcess: Bool, surgeService: Bool, connected: Bool,
                vifUp: Bool, ownsDefaultRoute: Bool) {
        self.trustedProcess = trustedProcess
        self.surgeService = surgeService
        self.connected = connected
        self.vifUp = vifUp
        self.ownsDefaultRoute = ownsDefaultRoute
    }

    public var ready: Bool {
        trustedProcess && surgeService && connected && vifUp && ownsDefaultRoute
    }

    public var reasons: [String] {
        [(trustedProcess, "signed Surge process missing"),
         (surgeService, "primary network service is not Surge"),
         (connected, "Surge network extension is not connected"),
         (vifUp, "Surge VIF is not up with its expected IPv4 address"),
         (ownsDefaultRoute, "Surge does not own the IPv4 default route")]
            .filter { !$0.0 }.map { $0.1 }
    }
}

public enum Policy {
    public static let anchor = "io.github.surge-guard"
    public static let anchorPath = "/etc/pf.anchors/" + anchor
    public static let begin = "# BEGIN surge-guard (managed)"
    public static let end = "# END surge-guard (managed)"
    public static let attachment = "anchor \"\(anchor)\""
    public static let configBlock = """
    \(begin)
    \(attachment)
    load anchor "\(anchor)" from "\(anchorPath)"
    \(end)

    """

    // Only local link configuration is exempt. No DNS, APNs, VPN endpoint,
    // captive-portal, general LAN, or general ICMP exception is granted.
    public static let blocked = """
    pass out on ! lo0 inet proto udp from any port 68 to 255.255.255.255 port 67 tag SG_LINK no state
    pass in on ! lo0 inet proto udp from any port 67 to any port 68 tag SG_LINK no state
    pass out on ! lo0 inet6 proto udp from fe80::/10 port 546 to ff02::1:2 port 547 tag SG_LINK no state
    pass in on ! lo0 inet6 proto udp from fe80::/10 port 547 to fe80::/10 port 546 tag SG_LINK no state
    pass out on ! lo0 inet6 proto icmp6 from fe80::/10 to ff02::2 icmp6-type 133 code 0 tag SG_LINK no state
    pass in on ! lo0 inet6 proto icmp6 from fe80::/10 to any icmp6-type 134 code 0 tag SG_LINK no state
    pass out on ! lo0 inet6 proto icmp6 from { ::/128, fe80::/10 } to ff02::1:ff00:0/104 icmp6-type 135 code 0 tag SG_LINK no state
    pass out on ! lo0 inet6 proto icmp6 from fe80::/10 to fe80::/10 icmp6-type 135 code 0 tag SG_LINK no state
    pass out on ! lo0 inet6 proto icmp6 from fe80::/10 to fe80::/10 icmp6-type 136 code 0 tag SG_LINK no state
    pass out on ! lo0 inet6 proto icmp6 from fe80::/10 to ff02::1 icmp6-type 136 code 0 tag SG_LINK no state
    pass in on ! lo0 inet6 proto icmp6 from { ::/128, fe80::/10 } to any icmp6-type 135 code 0 tag SG_LINK no state
    pass in on ! lo0 inet6 proto icmp6 from fe80::/10 to any icmp6-type 136 code 0 tag SG_LINK no state
    block drop quick on ! lo0 all ! tagged SG_LINK label "surge-guard-block"

    """

    public static func removingAttachment(from config: String) throws -> String {
        let lines = config.components(separatedBy: "\n")
        let begins = lines.indices.filter { lines[$0] == begin }
        let ends = lines.indices.filter { lines[$0] == end }
        if begins.isEmpty && ends.isEmpty { return config }
        guard begins.count == 1, ends.count == 1, begins[0] < ends[0] else {
            throw GuardError("Malformed surge-guard markers in pf.conf; refusing to edit")
        }
        let start = begins[0], finish = ends[0]
        // Do not delete user edits inserted between our markers.
        guard lines[start...finish].joined(separator: "\n") + "\n" == configBlock else {
            throw GuardError("Managed PF attachment was edited; refusing to overwrite it")
        }
        return (Array(lines[..<start]) + Array(lines[(finish + 1)...])).joined(separator: "\n")
    }

    public static func attaching(to config: String) throws -> String {
        let base = try removingAttachment(from: config)
        guard !base.contains(anchor) else {
            throw GuardError("Unmanaged surge-guard reference already exists in pf.conf")
        }
        // Restrict automatic installation to a recognizable Apple filter anchor.
        // Live rule ordering is checked separately before allowing any traffic.
        let lines = base.components(separatedBy: "\n")
        let positions = lines.indices.filter { lines[$0].trimmingCharacters(in: .whitespaces) == "anchor \"com.apple/*\"" }
        guard positions.count == 1 else {
            throw GuardError("Expected one Apple filter anchor; custom pf.conf needs manual integration")
        }
        var result = lines
        result.insert(configBlock.trimmingCharacters(in: .newlines), at: positions[0])
        return result.joined(separator: "\n")
    }

    public static func attachedFirst(_ rules: String) -> Bool {
        // macOS -sr also lists normalization rules. They are not packet-filter
        // allow/block rules and may correctly precede our filter anchor.
        let lines = rules.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = lines.first(where: {
            !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("scrub-anchor ") && !$0.hasPrefix("scrub ")
        }) else { return false }
        return first == attachment || first == attachment + " all"
    }

    public static func defaultInterface(_ output: String) -> String? {
        output.split(separator: "\n").compactMap { line -> String? in
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            return fields.count == 2 && fields[0] == "interface:" ? String(fields[1]) : nil
        }.first
    }
}

public struct GuardError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}
