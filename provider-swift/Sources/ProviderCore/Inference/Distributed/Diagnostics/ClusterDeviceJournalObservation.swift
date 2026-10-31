import Foundation
import Darwin

public enum ClusterDeviceJournalObservation: String, Codable, Sendable {
    case absent, emptyJournal, ownershipUnproven, unsafeOrChanging

    /// Metadata-only and deliberately lock-free. Empty/absent does not prove an
    /// available device: a live solo process can hold an empty exclusive gate.
    static func read(paths: ClusterUserPaths) -> Self {
        var directoryStat = stat()
        if lstat(paths.deviceDirectory.path, &directoryStat) != 0, errno == ENOENT { return .absent }
        do {
            let parent = try ClusterConfigurationFiles.directory(paths.deviceDirectory, privateMode: true)
            defer { Darwin.close(parent.descriptor) }
            let fd = openat(parent.descriptor, "native-device.lease", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            if fd < 0, errno == ENOENT { try parent.check(); return .absent }
            guard fd >= 0 else { return .unsafeOrChanging }
            defer { Darwin.close(fd) }
            var value = stat(), named = stat()
            guard fstat(fd, &value) == 0,
                  fstatat(parent.descriptor, "native-device.lease", &named, AT_SYMLINK_NOFOLLOW) == 0,
                  value.st_uid == geteuid(), value.st_mode & S_IFMT == S_IFREG,
                  value.st_mode & 0o077 == 0, value.st_nlink == 1,
                  value.st_dev == named.st_dev, value.st_ino == named.st_ino,
                  value.st_mode == named.st_mode, value.st_size == named.st_size,
                  value.st_mtimespec.tv_sec == named.st_mtimespec.tv_sec,
                  value.st_mtimespec.tv_nsec == named.st_mtimespec.tv_nsec else { return .unsafeOrChanging }
            try parent.check()
            return value.st_size == 0 ? .emptyJournal : .ownershipUnproven
        } catch { return .unsafeOrChanging }
    }
}
