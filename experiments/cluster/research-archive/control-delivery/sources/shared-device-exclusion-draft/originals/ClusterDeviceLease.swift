import Foundation
import Darwin

/// One configured per-user device lock, shared by every cluster on that device.
/// An unresolved nonempty journal is sticky. This class never probes a saved PID
/// or automatically recovers ownership after owner death.
final class ClusterDeviceLease {
    private let directory: Int32
    private let descriptor: Int32
    private let directoryPath: String
    private let directoryIdentity: stat
    private var identity: stat
    private var resolved = false

    init(directoryURL: URL) throws {
        guard directoryURL.isFileURL, directoryURL.path.hasPrefix("/"),
              !directoryURL.pathComponents.contains("..") && !directoryURL.pathComponents.contains(".") else { throw OwnerWire.invalid("Invalid lease directory") }
        let dir = Darwin.open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { throw OwnerWire.invalid("Cannot open lease directory") }
        var dirStat = stat()
        guard fstat(dir, &dirStat) == 0, dirStat.st_uid == geteuid(),
              dirStat.st_mode & S_IFMT == S_IFDIR, dirStat.st_mode & 0o077 == 0 else {
            Darwin.close(dir); throw OwnerWire.invalid("Lease directory must be private and owned")
        }
        let fd = openat(dir, "native-device.lease", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { Darwin.close(dir); throw OwnerWire.invalid("Cannot open device lease") }
        var s = stat(), path = stat()
        guard fstat(fd, &s) == 0, fstatat(dir, "native-device.lease", &path, AT_SYMLINK_NOFOLLOW) == 0,
              s.st_dev == path.st_dev, s.st_ino == path.st_ino, s.st_uid == geteuid(), s.st_nlink == 1,
              s.st_mode & S_IFMT == S_IFREG, s.st_mode & 0o077 == 0,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd); Darwin.close(dir); throw OwnerWire.invalid("Device lease unavailable or unsafe")
        }
        guard fstat(fd, &s) == 0, s.st_size == 0 else {
            Darwin.close(fd); Darwin.close(dir); throw OwnerWire.invalid("Unresolved native ownership journal; explicit recovery required")
        }
        self.directory = dir; descriptor = fd; identity = s
        directoryPath = directoryURL.path; directoryIdentity = dirStat
    }

    func record(binding: ClusterOwnerBinding, launchID: UUID) throws {
        try requireSameFile()
        var data = try JSONSerialization.data(withJSONObject: ["schema": "darkbloom_native_lease_v1",
            "clusterID": binding.route.clusterID, "leaseID": binding.route.leaseID.uuidString.lowercased(),
            "ownerIncarnation": binding.route.ownerIncarnation.uuidString.lowercased(),
            "membershipEpoch": binding.route.membershipEpoch.uuidString.lowercased(),
            "nativeLaunchID": launchID.uuidString.lowercased(), "peerID": binding.route.ownerPeerID,
            "rank": binding.rank], options: [.sortedKeys])
        data.append(10)
        guard data.count <= 16_384 else { throw OwnerWire.invalid("Lease journal exceeded bound") }
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { Darwin.pwrite(descriptor, $0.baseAddress!.advanced(by: offset), data.count - offset, off_t(offset)) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw OwnerWire.invalid("Lease journal write failed") }; offset += count
        }
        guard fsync(descriptor) == 0, fsync(directory) == 0 else { throw OwnerWire.invalid("Lease journal sync failed") }
        try requireSameFile()
    }

    /// Only after independently observed native cleanup and owner release ACK.
    func resolve() throws {
        guard !resolved else { throw OwnerWire.invalid("Device lease already released") }
        try requireSameFile()
        guard ftruncate(descriptor, 0) == 0, fsync(descriptor) == 0 else { throw OwnerWire.invalid("Lease clear failed") }
        resolved = true
    }

    private func requireSameFile() throws {
        var current = stat(), path = stat(), directoryNow = stat(), directoryName = stat()
        guard fstat(directory, &directoryNow) == 0, lstat(directoryPath, &directoryName) == 0,
              directoryNow.st_dev == directoryIdentity.st_dev, directoryNow.st_ino == directoryIdentity.st_ino,
              directoryName.st_dev == directoryIdentity.st_dev, directoryName.st_ino == directoryIdentity.st_ino,
              directoryNow.st_uid == geteuid(), directoryNow.st_mode & 0o077 == 0, directoryNow.st_nlink > 0,
              fstat(descriptor, &current) == 0, fstatat(directory, "native-device.lease", &path, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_dev == identity.st_dev, current.st_ino == identity.st_ino,
              path.st_dev == identity.st_dev, path.st_ino == identity.st_ino, current.st_nlink == 1,
              current.st_uid == geteuid(), current.st_mode & S_IFMT == S_IFREG, current.st_mode & 0o077 == 0 else {
            throw OwnerWire.invalid("Lease journal replaced")
        }
    }
    deinit { Darwin.close(descriptor); Darwin.close(directory) }
}
