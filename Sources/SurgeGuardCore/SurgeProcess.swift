import Darwin

public struct SurgeProcess: Equatable {
    public let pid: pid_t
    public let startedSeconds: Int
    public let startedMicroseconds: Int

    public init(pid: pid_t, startedSeconds: Int, startedMicroseconds: Int) {
        self.pid = pid
        self.startedSeconds = startedSeconds
        self.startedMicroseconds = startedMicroseconds
    }
}

public struct SurgeProcessTrust {
    private var verified: SurgeProcess?
    public init() {}

    public mutating func trustedPID(candidates: [SurgeProcess], validate: (pid_t) throws -> Bool) throws -> pid_t? {
        guard candidates.count == 1, let candidate = candidates.first, candidate.pid > 1 else {
            verified = nil
            return nil
        }
        if verified == candidate { return candidate.pid }
        verified = nil
        guard try validate(candidate.pid) else { return nil }
        verified = candidate
        return candidate.pid
    }
}
