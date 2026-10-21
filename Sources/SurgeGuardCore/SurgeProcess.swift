import Darwin

public struct SurgeProcess: Codable, Equatable {
    public let pid: pid_t
    public let startedSeconds: Int
    public let startedMicroseconds: Int

    public init(pid: pid_t, startedSeconds: Int, startedMicroseconds: Int) {
        self.pid = pid
        self.startedSeconds = startedSeconds
        self.startedMicroseconds = startedMicroseconds
    }

    public static func read(pid: pid_t) throws -> SurgeProcess? {
        guard pid > 1 else { throw GuardError("Invalid process ID") }
        var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        let result = sysctl(&query, u_int(query.count), &info, &size, nil, 0)
        if result != 0, errno == ESRCH { return nil }
        guard result == 0 else { throw GuardError("Cannot inspect process identity: errno \(errno)") }
        if size == 0 { return nil }
        guard size == MemoryLayout<kinfo_proc>.size, info.kp_proc.p_pid == pid else {
            throw GuardError("Unexpected native process identity")
        }
        if info.kp_proc.p_stat == SZOMB { return nil }
        let birth = info.kp_proc.p_un.__p_starttime
        return SurgeProcess(pid: pid, startedSeconds: birth.tv_sec, startedMicroseconds: Int(birth.tv_usec))
    }
}

public struct SurgeProcessTrust {
    private var verified: SurgeProcess?
    private var observed: [SurgeProcess] = []
    public private(set) var revision: UInt64 = 0
    public init() {}

    public func matches(candidates: [SurgeProcess]) -> Bool {
        candidates.count == 1 && verified != nil && candidates.first == verified
    }

    @discardableResult
    public mutating func observe(candidates: [SurgeProcess]) -> Bool {
        if candidates != observed {
            observed = candidates
            verified = nil
            revision &+= 1
        }
        return matches(candidates: candidates)
    }

    public mutating func trustedPID(candidates: [SurgeProcess], validate: (pid_t) throws -> Bool,
                                    recheck: (() throws -> [SurgeProcess])? = nil) throws -> pid_t? {
        observe(candidates: candidates)
        guard candidates.count == 1, let candidate = candidates.first, candidate.pid > 1 else {
            verified = nil
            return nil
        }
        if verified == candidate { return candidate.pid }
        verified = nil
        guard try validate(candidate.pid) else { return nil }
        if let recheck {
            let current = try recheck()
            guard current == candidates else { observe(candidates: current); return nil }
        }
        verified = candidate
        return candidate.pid
    }
}
