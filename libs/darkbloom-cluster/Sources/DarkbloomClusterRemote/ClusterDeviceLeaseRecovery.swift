import Foundation
import Darwin
import DarkbloomClusterProcess

/// Explicit operator recovery of a device journal that outlived its owner.
///
/// An owner clears its own journal once it has observed its child's exit, so a
/// journal survives only when the owner process ended first. Recovery proves,
/// on this Mac, that nothing the journal names is still running before it
/// clears anything:
///
/// 1. No live process holds the device scope. Every owner (and a solo engine)
///    keeps an exclusive lock on the journal file for as long as it runs, so
///    taking that lock here shows there is none.
/// 2. No process carries the recorded membership epoch on its command line.
///    Each native worker is started with its session's epoch, which is unique
///    to that session, so this cannot match a recycled process number.
///
/// It refuses, and changes nothing, when either check finds a process or when
/// the journal cannot be read as a record. It never signals anything.
public enum ClusterDeviceLeaseRecovery {
    public struct Record: Equatable, Sendable {
        public let clusterID: String
        public let peerID: String
        public let rank: Int
        public let membershipEpoch: String
        public let leaseID: String
        public let ownerIncarnation: String
        public let nativeLaunchID: String
        public init(clusterID: String, peerID: String, rank: Int, membershipEpoch: String, leaseID: String,
                    ownerIncarnation: String, nativeLaunchID: String) {
            self.clusterID = clusterID; self.peerID = peerID; self.rank = rank; self.membershipEpoch = membershipEpoch
            self.leaseID = leaseID; self.ownerIncarnation = ownerIncarnation; self.nativeLaunchID = nativeLaunchID
        }
    }

    public enum Outcome: Equatable, Sendable {
        /// No journal file, or an empty one: nothing was stranded.
        case nothingToRecover
        /// The journal was stranded, nothing it names is running, and it is now empty.
        case cleared(Record)
        /// A running process holds this Mac's device scope. It clears its own journal.
        case refusedLiveOwner
        /// A running process still carries the recorded membership epoch.
        case refusedLiveWorker(processIdentifier: Int32, record: Record)
        /// The journal is not a record this build wrote; nothing can be proven about it.
        case refusedUnreadable
    }

    public static func recover(directoryURL: URL) throws -> Outcome {
        try recover(directoryURL: directoryURL, runningProcesses: ClusterProcessTable.running)
    }

    // The process list is a seam for deterministic checks only.
    static func recover(directoryURL: URL, runningProcesses: () -> [ClusterProcessTable.Entry]) throws -> Outcome {
        var directoryStat = stat()
        guard directoryURL.isFileURL, directoryURL.path.hasPrefix("/") else {
            throw ClusterDeviceLeaseRecoveryError.invalid("Invalid lease directory")
        }
        if lstat(directoryURL.path, &directoryStat) != 0, errno == ENOENT { return .nothingToRecover }
        let directory = Darwin.open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw ClusterDeviceLeaseRecoveryError.invalid("Lease directory is missing or follows a link") }
        defer { Darwin.close(directory) }
        guard fstat(directory, &directoryStat) == 0, directoryStat.st_uid == geteuid(),
              directoryStat.st_mode & S_IFMT == S_IFDIR, directoryStat.st_mode & 0o077 == 0 else {
            throw ClusterDeviceLeaseRecoveryError.invalid("Lease directory must be private and owned")
        }
        let descriptor = openat(directory, "native-device.lease", O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if descriptor < 0, errno == ENOENT { return .nothingToRecover }
        guard descriptor >= 0 else { throw ClusterDeviceLeaseRecoveryError.invalid("Cannot open device lease") }
        defer { Darwin.close(descriptor) }
        var value = stat(), named = stat()
        guard fstat(descriptor, &value) == 0, fstatat(directory, "native-device.lease", &named, AT_SYMLINK_NOFOLLOW) == 0,
              value.st_dev == named.st_dev, value.st_ino == named.st_ino, value.st_uid == geteuid(), value.st_nlink == 1,
              value.st_mode & S_IFMT == S_IFREG, value.st_mode & 0o077 == 0 else {
            throw ClusterDeviceLeaseRecoveryError.invalid("Device lease is unsafe")
        }
        // Held to the end of this call: no owner can start while recovery decides.
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return .refusedLiveOwner }
        defer { _ = flock(descriptor, LOCK_UN) }
        guard fstat(descriptor, &value) == 0 else { throw ClusterDeviceLeaseRecoveryError.invalid("Device lease is unsafe") }
        if value.st_size == 0 { return .nothingToRecover }
        guard value.st_size <= 16_384, let record = try parse(read(descriptor, count: Int(value.st_size))) else {
            return .refusedUnreadable
        }
        for process in runningProcesses() where process.processIdentifier != getpid() {
            if process.arguments.contains(record.membershipEpoch) {
                return .refusedLiveWorker(processIdentifier: process.processIdentifier, record: record)
            }
        }
        guard fstatat(directory, "native-device.lease", &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_dev == value.st_dev, named.st_ino == value.st_ino else {
            throw ClusterDeviceLeaseRecoveryError.invalid("Lease journal replaced")
        }
        guard ftruncate(descriptor, 0) == 0, fsync(descriptor) == 0, fsync(directory) == 0 else {
            throw ClusterDeviceLeaseRecoveryError.invalid("Lease clear failed")
        }
        return .cleared(record)
    }

    private static func read(_ descriptor: Int32, count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let received = bytes.withUnsafeMutableBytes { Darwin.pread(descriptor, $0.baseAddress!.advanced(by: offset), count - offset, off_t(offset)) }
            if received < 0 && errno == EINTR { continue }
            guard received > 0 else { throw ClusterDeviceLeaseRecoveryError.invalid("Device lease read failed") }
            offset += received
        }
        return Data(bytes)
    }

    private static func parse(_ data: Data) -> Record? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["schema"] as? String == "darkbloom_native_lease_v1",
              let cluster = object["clusterID"] as? String, let peer = object["peerID"] as? String,
              let rank = object["rank"] as? Int, (0...1).contains(rank),
              let epoch = canonical(object["membershipEpoch"]), let lease = canonical(object["leaseID"]),
              let incarnation = canonical(object["ownerIncarnation"]), let launch = canonical(object["nativeLaunchID"]) else {
            return nil
        }
        return .init(clusterID: cluster, peerID: peer, rank: rank, membershipEpoch: epoch, leaseID: lease,
            ownerIncarnation: incarnation, nativeLaunchID: launch)
    }

    private static func canonical(_ value: Any?) -> String? {
        guard let text = value as? String, let uuid = UUID(uuidString: text), uuid.uuidString.lowercased() == text else { return nil }
        return text
    }
}

public enum ClusterDeviceLeaseRecoveryError: Error, Equatable, CustomStringConvertible {
    case invalid(String)
    public var description: String { switch self { case .invalid(let message): return message } }
}
