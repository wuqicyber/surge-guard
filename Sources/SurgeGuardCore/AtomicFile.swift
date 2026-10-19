import Foundation
import Darwin

public enum AtomicFile {
    // Callers validate the parent/target owner; publish only after permissions are final.
    public static func write(_ value: String, to path: String, mode: mode_t) throws {
        let staged = path + ".new." + UUID().uuidString
        let fd = open(staged, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw GuardError("Cannot stage file: \(path), errno \(errno)") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); unlink(staged) }
        try handle.write(contentsOf: Data(value.utf8))
        guard fchmod(fd, mode) == 0, fsync(fd) == 0 else {
            throw GuardError("Cannot prepare file permissions/content: \(path), errno \(errno)")
        }
        guard rename(staged, path) == 0 else { throw GuardError("Cannot publish file: \(path), errno \(errno)") }
    }
}
