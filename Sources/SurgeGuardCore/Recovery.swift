import Foundation

public struct BackupManifest: Codable {
    public let version: Int
    public let id: String
    public let kind: String
    public let createdAt: Date
    public let files: [String]

    public init(kind: String, includesLauncher: Bool = false) throws {
        version = includesLauncher ? 2 : 1; id = UUID().uuidString; self.kind = kind; createdAt = Date()
        files = kind == "update" ? ["surge-guard", "daemon.plist", "anchor", "policy.json"] + (includesLauncher ? ["surge-guard-launch"] : []) : ["policy.json"]
        try validate()
    }
    public func validate() throws {
        let expected = kind == "update" ? ["surge-guard", "daemon.plist", "anchor", "policy.json"] + (version == 2 ? ["surge-guard-launch"] : []) : ["policy.json"]
        guard [1, 2].contains(version), version != 2 || kind == "update",
              ["update", "policy"].contains(kind), UUID(uuidString: id)?.uuidString == id,
              files == expected else { throw GuardError("Invalid recovery backup manifest") }
    }
    public static func pointer(_ kind: String) -> String { Paths.publicState + "/backup-\(kind).json" }
}
