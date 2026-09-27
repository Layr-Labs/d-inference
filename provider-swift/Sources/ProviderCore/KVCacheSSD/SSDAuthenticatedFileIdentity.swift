import Darwin
import Foundation

enum SSDAuthenticatedFileChange: Error { case changedDuringRead }

/// Binds successful authentication to the same unchanged regular file. A
/// metadata-only check avoids decrypting gigabytes again for a repeated hit.
struct SSDAuthenticatedFileIdentity: Equatable, Sendable {
    private let device: Int32
    private let inode: UInt64
    private let bytes: Int64
    private let modifiedSeconds: Int
    private let modifiedNanoseconds: Int
    private let changedSeconds: Int
    private let changedNanoseconds: Int

    init(handle: FileHandle) throws {
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw SSDBlockStoreError.ioFailure("authenticated file identity unavailable")
        }
        device = info.st_dev
        inode = info.st_ino
        bytes = info.st_size
        modifiedSeconds = info.st_mtimespec.tv_sec
        modifiedNanoseconds = info.st_mtimespec.tv_nsec
        changedSeconds = info.st_ctimespec.tv_sec
        changedNanoseconds = info.st_ctimespec.tv_nsec
    }

    func matches(url: URL) -> Bool {
        guard let handle = try? SSDNoFollowIO.openRegularFileForReading(at: url) else { return false }
        defer { try? handle.close() }
        return (try? Self(handle: handle)) == self
    }
}
