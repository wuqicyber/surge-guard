import Foundation
import CryptoKit

public struct RouteCheck: Codable, Equatable {
    public var url: String
    public var requiredGroup: String
    public var allowedFinalPolicies: [String]

    public init(url: String, requiredGroup: String, allowedFinalPolicies: [String]) {
        self.url = url
        self.requiredGroup = requiredGroup
        self.allowedFinalPolicies = allowedFinalPolicies
    }
}

public struct Configuration: Codable, Equatable {
    public var version: Int
    public var mode: String
    public var routeChecks: [RouteCheck]

    public static let enhanced = Configuration(version: 1, mode: "enhanced", routeChecks: [])

    public init(version: Int, mode: String, routeChecks: [RouteCheck]) {
        self.version = version
        self.mode = mode
        self.routeChecks = routeChecks
    }

    public func validate() throws {
        guard version == 1, ["enhanced", "routes"].contains(mode), routeChecks.count <= 8 else {
            throw GuardError("Configuration requires version 1, mode enhanced/routes, and at most eight route checks")
        }
        guard (mode == "enhanced" && routeChecks.isEmpty) || (mode == "routes" && !routeChecks.isEmpty) else {
            throw GuardError("enhanced mode requires no route checks; routes mode requires at least one")
        }
        var urls = Set<String>()
        for check in routeChecks {
            guard let url = URLComponents(string: check.url),
                  ["https", "http"].contains(url.scheme), url.host?.isEmpty == false,
                  url.user == nil, url.password == nil, url.fragment == nil,
                  check.url.count <= 2048, urls.insert(check.url).inserted,
                  validName(check.requiredGroup), !check.allowedFinalPolicies.isEmpty,
                  check.allowedFinalPolicies.count <= 128,
                  Set(check.allowedFinalPolicies).count == check.allowedFinalPolicies.count,
                  check.allowedFinalPolicies.allSatisfy({ validName($0) && !["DIRECT", "REJECT", "REJECT-DROP", "REJECT-TINYGIF"].contains($0.uppercased()) }) else {
                throw GuardError("Each route check needs a unique HTTP(S) URL without credentials, an exact group and nonempty proxy allowlist")
            }
        }
    }

    private func validName(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 512 && value == value.trimmingCharacters(in: .whitespacesAndNewlines) &&
            !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    public static func decode(_ data: Data) throws -> Configuration {
        guard data.count <= 65_536,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["version", "mode", "route_checks"],
              let routes = object["route_checks"] as? [[String: Any]],
              routes.allSatisfy({ Set($0.keys) == ["url", "required_group", "allowed_final_policies"] }) else {
            throw GuardError("Invalid or unknown configuration fields")
        }
        let result = try JSON.decode(Configuration.self, from: data)
        try result.validate()
        return result
    }

    public static func load() throws -> Configuration {
        try RootFiles.verify(Paths.configuration)
        return try decode(Data(contentsOf: URL(fileURLWithPath: Paths.configuration)))
    }

    public func fingerprint() throws -> String {
        SHA256.hash(data: Data(try JSON.encode(self).utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public enum JSON {
    public static func encode<T: Encodable>(_ value: T, pretty: Bool = false) throws -> String {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(type, from: data)
    }
}

public struct RouteResult: Codable, Equatable {
    public var url: String
    public var expectedGroup: String
    public var actualGroup: String?
    public var finalPolicy: String?
    public var ready: Bool
    public var reason: String

    public static func evaluate(_ data: Data, check: RouteCheck) throws -> RouteResult {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let group = object["rule-policy"] as? String,
              let final = object["final"] as? String,
              let type = object["final-type"] as? String,
              let steps = object["steps"] as? [[String: Any]],
              !group.isEmpty, !final.isEmpty, !type.isEmpty else {
            throw GuardError("Surge returned an incomplete rule explanation")
        }
        let proxy = !["DIRECT", "REJECT", "REJECT-DROP", "REJECT-TINYGIF"].contains(final.uppercased()) &&
            !["direct", "reject", "reject-drop", "reject-tinygif"].contains(type.lowercased())
        let groupMatches = group == check.requiredGroup && steps.contains { $0["group"] as? String == check.requiredGroup }
        let ready = groupMatches && proxy && check.allowedFinalPolicies.contains(final)
        return RouteResult(url: check.url, expectedGroup: check.requiredGroup, actualGroup: group,
                           finalPolicy: final, ready: ready,
                           reason: ready ? "route_matched" : "route_policy_mismatch")
    }
}

public struct SessionObservation: Codable {
    public var policyFingerprint: String
    public var mode: String
    public var enhancedMode: Bool
    public var routes: [RouteResult]
    public var ready: Bool { mode == "rule" && enhancedMode && !routes.isEmpty && routes.allSatisfy(\.ready) }
}
