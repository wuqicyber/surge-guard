import Foundation

public struct BackupManifest: Codable {
    public let version: Int
    public let id: String
    public let kind: String
    public let createdAt: Date
    public let files: [String]

    public init(kind: String) throws {
        version = 1; id = UUID().uuidString; self.kind = kind; createdAt = Date()
        files = kind == "update" ? ["surge-guard", "daemon.plist", "anchor", "policy.json"] : ["policy.json"]
        try validate()
    }
    public func validate() throws {
        let expected = kind == "update" ? ["surge-guard", "daemon.plist", "anchor", "policy.json"] : ["policy.json"]
        guard version == 1, ["update", "policy"].contains(kind), UUID(uuidString: id)?.uuidString == id,
              files == expected else { throw GuardError("Invalid recovery backup manifest") }
    }
    public static func pointer(_ kind: String) -> String { Paths.publicState + "/backup-\(kind).json" }
}
