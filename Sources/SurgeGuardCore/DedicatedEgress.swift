import Foundation
import Darwin

public enum DedicatedEgress {
    public static let groupName = "_surge_guard"
    public static let launcher = "/Library/PrivilegedHelperTools/surge-guard-launch"
    public static let groupRecord = Paths.runtime + "/egress-group.json"

    public static func group() throws -> gid_t {
        try RootFiles.verify(launcher)
        var info = stat()
        guard lstat(launcher, &info) == 0, info.st_mode & 0o7777 == 0o2755,
              (60_000...60_999).contains(info.st_gid),
              let entry = getgrnam(groupName), entry.pointee.gr_gid == info.st_gid,
              entry.pointee.gr_mem.pointee == nil else {
            throw GuardError("Dedicated Surge launcher/group is not installed or has unexpected permissions/members")
        }
        return info.st_gid
    }

    public static func identityMatches(pid: pid_t, uid: uid_t, group: gid_t) throws -> Bool {
        guard pid > 1, uid >= 501, (60_000...60_999).contains(group) else { return false }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else {
            throw GuardError("Cannot verify Surge socket identity: errno \(errno)")
        }
        return identityMatches(info, returnedSize: size, uid: uid, group: group)
    }

    public static func identityMatches(_ info: kinfo_proc, returnedSize: Int, uid: uid_t, group: gid_t) -> Bool {
        guard returnedSize == MemoryLayout<kinfo_proc>.size,
              uid >= 501, (60_000...60_999).contains(group) else { return false }
        return info.kp_eproc.e_ucred.cr_uid == uid &&
               info.kp_eproc.e_pcred.p_ruid == uid &&
               info.kp_eproc.e_ucred.cr_groups.0 == group &&
               info.kp_eproc.e_pcred.p_rgid == group
    }
}
