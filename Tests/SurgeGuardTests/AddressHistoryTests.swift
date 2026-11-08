import Darwin
import Foundation
import SurgeGuardCore

func addressHistoryTests() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("address-rollover-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("addresses.json").path
    func fixture(_ addresses: Set<String>) throws {
        let value: [String: Any] = ["version": 1, "boot_id": SystemClock.bootID, "addresses": addresses.sorted()]
        try AtomicFile.write(String(decoding: JSONSerialization.data(withJSONObject: value), as: UTF8.self), to: file, mode: 0o600)
    }
    func stored() throws -> Set<String> {
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: file))) as! [String: Any]
        return Set(value["addresses"] as! [String])
    }
    var largestWrite = 0
    func persist(_ value: String, _ destination: String) throws {
        let object = try JSONSerialization.jsonObject(with: Data(value.utf8)) as! [String: Any]
        let count = (object["addresses"] as! [String]).count
        largestWrite = max(largestWrite, count)
        try check(count <= 1024 && value.utf8.count <= 65_536, "Rollover checkpoint exceeded its hard limits")
        try AtomicFile.write(value, to: destination, mode: 0o600)
    }
    let history = Set((1...512).map { "fe80::" + String($0, radix: 16) })
    let current: Set<String> = ["192.0.2.10"]
    let complete = history.union(current)
    try fixture(history)
    let first = Firewall(historyPath: file, writeHistory: persist)
    try first.rememberAddresses(addresses: { current })
    try check(first.addressHistoryNeedsCompaction && stored() == complete,
              "The 513th address was rejected or not made durable before cleanup")

    // A replacement daemon must recover the transitional checkpoint after a crash.
    let replacement = Firewall(historyPath: file, writeHistory: persist)
    var cleared: [String] = []
    try replacement.clearStates(addresses: { current }) { address in
        try check(try stored() == complete, "An address was forgotten before all remembered states were cleared")
        cleared.append(address)
    }
    try check(Set(cleared) == complete && stored() == current && !replacement.addressHistoryNeedsCompaction,
              "Replacement did not clear the full checkpoint before retaining current addresses")
    print("PASS: a full 512-address history preserves new addresses and survives replacement before verified rollover")

    try fixture(complete)
    let failed = Firewall(historyPath: file, writeHistory: persist)
    try rejects {
        try failed.clearStates(addresses: { current }) { _ in throw GuardError("cleanup failure") }
    }
    try check(try stored() == complete, "Cleanup failure discarded historical addresses")
    cleared = []
    try failed.clearStates(addresses: { current }) { cleared.append($0) }
    try check(Set(cleared) == complete && stored() == current, "Cleanup retry forgot pending addresses")

    try fixture(complete)
    var failFinalWrite = true
    let failedWrite = Firewall(historyPath: file, writeHistory: { value, destination in
        let object = try JSONSerialization.jsonObject(with: Data(value.utf8)) as! [String: Any]
        if failFinalWrite && (object["addresses"] as! [String]).count == current.count {
            throw GuardError("final checkpoint write failed")
        }
        try persist(value, destination)
    })
    try rejects { try failedWrite.clearStates(addresses: { current }) { _ in } }
    try check(try stored() == complete, "Failed final publication replaced the recovery checkpoint")
    failFinalWrite = false
    cleared = []
    try failedWrite.clearStates(addresses: { current }) { cleared.append($0) }
    try check(Set(cleared) == complete, "A failed final write discarded in-memory recovery addresses")
    print("PASS: cleanup and final-write failures retain complete address evidence for retry")

    let rolling = Firewall(historyPath: file, writeHistory: persist)
    var rotations = 0
    for batch in 0..<20 {
        let active = Set((1...100).map { "fe80::1:" + String(batch * 100 + $0, radix: 16) })
        try rolling.rememberAddresses(addresses: { active })
        if rolling.addressHistoryNeedsCompaction {
            rotations += 1
            try rolling.clearStates(addresses: { active }) { _ in }
            try check(try stored() == active, "Rollover did not converge to the active inventory")
        }
    }
    try check(rotations >= 2 && largestWrite <= 1024, "Repeated interface churn was not kept bounded")
    do {
        try RootFiles.verify(directory.appendingPathComponent("missing-status.json").path)
        throw GuardError("Missing state unexpectedly passed verification")
    } catch {
        try check(String(describing: error).contains("does not exist"), "Missing state was mislabeled as an ownership failure")
    }
    print("PASS: repeated address churn rolls over within hard limits and missing state reports an absent file")
}
