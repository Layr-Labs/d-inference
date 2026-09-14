import Darwin
import SandboxGuestProtocol

/// A completed API mutation must survive an immediate VM stop. On macOS fsync
/// alone does not request the storage-cache flush supplied by F_FULLFSYNC.
/// Synchronize the inode first, then require that stronger persistence barrier.
enum GuestWorkspaceDurability {
    static func synchronize(_ descriptor: Int32) throws {
        while fsync(descriptor) != 0 {
            guard errno == EINTR else { throw GuestProtocolError.publicationUncertain }
        }
        while fcntl(descriptor, F_FULLFSYNC) != 0 {
            guard errno == EINTR else { throw GuestProtocolError.publicationUncertain }
        }
    }
}
