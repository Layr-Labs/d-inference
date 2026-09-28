import Darwin
import Foundation

enum QwenCandidateExportInput {
    /// One bounded regular-file snapshot. Flags reject symlinks and keep FIFO
    /// opening nonblocking; fstat rejects every non-regular descriptor before read.
    /// Equality and raw-byte pins do not claim future path contents are unchanged.
    static func read(_ url: URL, maximumBytes: Int) throws -> Data {
        guard (1...QwenCandidateExport.maximumNamesBytes).contains(maximumBytes) else {
            throw ProbeError("Candidate input byte limit is invalid")
        }
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw ProbeError("Candidate input could not be opened") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat(), after = stat()
        guard fstat(descriptor, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
              before.st_size > 0, before.st_size <= maximumBytes else {
            throw ProbeError("Candidate input must be a nonempty bounded regular file") }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count == Int(before.st_size), fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_mode == after.st_mode, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw ProbeError("Candidate input descriptor changed during its bounded snapshot")
        }
        try handle.close()
        return data
    }
}
