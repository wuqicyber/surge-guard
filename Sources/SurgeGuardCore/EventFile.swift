import Foundation
import Darwin

public enum EventFile {
    public static let maximumBytes = 1_048_576

    public static func append(_ record: Data, to path: String, owner: uid_t, lockPath: String) throws {
        let line = record + Data([10])
        guard line.count <= maximumBytes else { throw GuardError("Event exceeds the 1 MiB log limit") }
        func verify(_ fd: Int32) throws -> stat {
            var info = stat()
            guard fd >= 0, fstat(fd, &info) == 0, info.st_uid == owner,
                  info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0 else {
                throw GuardError("Unsafe event log or lock permissions")
            }
            return info
        }
        let lock = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard lock >= 0 else { throw GuardError("Cannot open event log lock") }
        defer { close(lock) }
        _ = try verify(lock)
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw GuardError("Event log busy") }
        var fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw GuardError("Cannot open event log") }
        defer { if fd >= 0 { close(fd) } }
        let info = try verify(fd)
        if info.st_size + off_t(line.count) > maximumBytes {
            let backup = path + ".1"
            var saved = stat()
            if lstat(backup, &saved) == 0 {
                guard saved.st_uid == owner, saved.st_mode & S_IFMT == S_IFREG, saved.st_mode & 0o077 == 0 else {
                    throw GuardError("Unsafe rotated event log")
                }
            } else if errno != ENOENT { throw GuardError("Cannot inspect rotated event log") }
            guard rename(path, backup) == 0 else { throw GuardError("Cannot rotate event log") }
            close(fd)
            fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
            _ = try verify(fd)
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        try handle.write(contentsOf: line)
    }
}
