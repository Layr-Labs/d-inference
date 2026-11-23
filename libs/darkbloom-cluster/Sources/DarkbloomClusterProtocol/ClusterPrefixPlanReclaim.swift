// Copyright © 2026 Eigen Labs.

import Darwin
import Foundation

/// Deliberate whole-plan removal on switch-off or unpair, distinct from TTL
/// expiry. Unknown means retry, never authorization to remove shared staging.
public enum ClusterPrefixPlanReclaim {
    public struct Result: Sendable, Equatable {
        public var removedPlans = 0
        public var keptLive = 0
        public var rootRemoved = false
        public var problems: [String] = []
        public var needsRetry: Bool { keptLive > 0 || !problems.isEmpty }
        public init() {}
    }

    /// Mount identity for the durable unpair intent; the same UUID is checked
    /// on the descriptor used for removal, not merely when this intent is made.
    public static func identityForRoot(_ root: URL) -> (volume: String, inode: UInt64?)? {
        guard let components = components(root) else { return nil }
        var fd = Darwin.open("/", dirFlags)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        for name in components {
            let child = openat(fd, name, dirFlags)
            if child < 0 { return errno == ENOENT ? volumeID(fd).map { ($0, nil) } : nil }
            close(fd); fd = child
        }
        var s = stat()
        guard fstat(fd, &s) == 0, s.st_uid == getuid() else { return nil }
        return volumeID(fd).map { ($0, UInt64(s.st_ino)) }
    }

    private static func volumeID(_ fd: Int32) -> String? {
        var attr = attrlist()
        attr.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attr.volattr = UInt32(ATTR_VOL_INFO) | UInt32(ATTR_VOL_UUID)
        var bytes = [UInt8](repeating: 0, count: 20)
        guard bytes.withUnsafeMutableBytes({ fgetattrlist(fd, &attr, $0.baseAddress, $0.count, 0) }) == 0,
              bytes.dropFirst(4).contains(where: { $0 != 0 }) else { return nil }
        return bytes.withUnsafeBufferPointer { NSUUID(uuidBytes: $0.baseAddress!.advanced(by: 4)).uuidString.lowercased() }
    }

    private static let dirFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    /// Text-only spelling: the durable identity must not change when an
    /// absent directory returns (`standardizedFileURL` can change its prefix).
    public static func canonicalRoot(_ input: String) -> String? {
        var path = input
        if path.hasPrefix("/var/") || path.hasPrefix("/tmp/") { path = "/private" + path }
        let parts = path.split(separator: "/").map(String.init)
        guard path.hasPrefix("/"), !parts.isEmpty, !parts.contains("."), !parts.contains(".."),
              !path.utf8.contains(0) else { return nil }
        return "/" + parts.joined(separator: "/")
    }
    private static func components(_ url: URL) -> [String]? {
        canonicalRoot(url.path)?.split(separator: "/").map(String.init)
    }

    public static func run(root: URL, keeping: String? = nil, includeStaging: Bool, expectedVolume: String? = nil,
                           expectedInode: UInt64? = nil) -> Result {
        run(root: root, keeping: keeping, includeStaging: includeStaging, expectedVolume: expectedVolume, expectedInode: expectedInode,
            removeRetired: { unlinkat($0, $1, AT_REMOVEDIR) })
    }

    static func run(root: URL, keeping: String?, includeStaging: Bool, expectedVolume: String?, expectedInode: UInt64? = nil,
                    removeRetired: (Int32, String) -> Int32) -> Result {
        var report = Result()
        guard let parts = components(root), let basename = parts.last else { report.problems.append("invalid cache root"); return report }
        let flags = dirFlags
        var parent = Darwin.open("/", flags)
        guard parent >= 0 else { report.problems.append("cannot inspect cache root"); return report }
        defer { close(parent) }
        for part in parts.dropLast() {
            let next = openat(parent, part, flags)
            guard next >= 0 else {
                if errno != ENOENT || (expectedVolume != nil && volumeID(parent) != expectedVolume) {
                    report.problems.append("cannot verify original cache volume")
                }
                return report
            }
            close(parent); parent = next
        }
        let fd = openat(parent, basename, flags)
        guard fd >= 0 else {
            if errno != ENOENT || (expectedVolume != nil && volumeID(parent) != expectedVolume) {
                report.problems.append("cannot verify original cache volume")
            }
            return report
        }
        defer { close(fd) }
        var s = stat()
        guard fstat(fd, &s) == 0, s.st_uid == getuid(), expectedVolume == nil || volumeID(fd) == expectedVolume,
              expectedInode == nil || UInt64(s.st_ino) == expectedInode else {
            report.problems.append("cannot verify original cache root"); return report
        }
        // A live rank holds this directory shared. Its own plan can still be
        // inspected, but no staging/root removal without the exclusive lease.
        var exclusive = includeStaging && flock(fd, LOCK_EX | LOCK_NB) == 0
        // Switch-off takes the root only when a plan has lost its lock file.
        func holdsRootExclusively() -> Bool {
            if !exclusive && !includeStaging { exclusive = flock(fd, LOCK_EX | LOCK_NB) == 0 }
            return exclusive
        }
        let device = s.st_dev
        let listed = ClusterPrefixRecordDirectory.forEachName(in: fd) { name in
            let prefix = ".retiring-"
            let retired = name.hasPrefix(prefix)
            let original = retired ? String(name.dropFirst(prefix.count).prefix(27)) : name
            guard original != keeping, ClusterPrefixRecordDirectory.isPlan(original) else { return }
            guard let plan = ClusterPrefixRecordDirectory.openChild(fd, name, device: device) else {
                report.problems.append("\(name): cannot inspect"); return
            }
            defer { close(plan) }
            var info = stat()
            guard fstat(plan, &info) == 0 else { report.problems.append("cannot identify retiring plan"); return }
            let retirement = "\(prefix)\(original)-\(info.st_ino)"
            if retired {
                guard name == retirement else { report.problems.append("unrecognized retirement"); return }
                var marker = stat()
                if fstatat(plan, "in-use", &marker, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT {
                    // Only the identified, already-renamed directory may finish
                    // without a lease, and only via an empty-directory removal.
                    if sameEntry(plan, parent: fd, name: name), removeRetired(fd, name) == 0 { report.removedPlans += 1 }
                    else { report.problems.append("\(name): retirement pending") }
                    return
                }
            }
            var leased = ClusterPrefixRecordDirectory.lease(plan)
            if case .unknown = leased, ClusterPrefixRecordDirectory.leaseMissing(plan), holdsRootExclusively() {
                leased = ClusterPrefixRecordDirectory.repairLease(plan)
            }
            switch leased {
            case .held: report.keptLive += 1
            case .unknown: report.problems.append("\(name): cannot verify lease")
            case .acquired(let lease):
                defer { close(lease) }
                guard clear(plan, device: device, keeping: "in-use"),
                      retireEmptyPlan(root: fd, plan: plan, lease: lease, name: name, retirement: retirement,
                                      removeRetired: removeRetired) else {
                    report.problems.append("\(name): removal incomplete"); return
                }
                report.removedPlans += 1
            }
        }
        if !listed { report.problems.append("incomplete plan listing") }
        guard includeStaging, !report.needsRetry else { return report }
        guard exclusive else { report.problems.append("cache root still in use"); return report }
        if fstatat(fd, "staging", &s, AT_SYMLINK_NOFOLLOW) == 0 {
            guard let stage = ClusterPrefixRecordDirectory.openChild(fd, "staging", device: device) else {
                report.problems.append("cannot inspect staging"); return report
            }
            defer { close(stage) }
            guard clear(stage, device: device), sameEntry(stage, parent: fd, name: "staging"),
                  unlinkat(fd, "staging", AT_REMOVEDIR) == 0 else { report.problems.append("staging not empty"); return report }
        } else if errno != ENOENT { report.problems.append("cannot inspect staging"); return report }
        guard sameEntry(fd, parent: parent, name: basename) else { report.problems.append("cache root changed"); return report }
        if unlinkat(parent, basename, AT_REMOVEDIR) == 0 { report.rootRemoved = true }
        else if errno != ENOTEMPTY && errno != EEXIST { report.problems.append("root not removed") }
        return report
    }

    /// Rename the leased inode before detaching the lease, including for
    /// load-time empty-plan pruning. The encoded inode is the recovery record.
    public static func retireEmptyPlan(root: Int32, plan: Int32, lease: Int32, name: String) -> Bool {
        var s = stat()
        guard ClusterPrefixRecordDirectory.isPlan(name), fstat(plan, &s) == 0 else { return false }
        return retireEmptyPlan(root: root, plan: plan, lease: lease, name: name, retirement: ".retiring-\(name)-\(s.st_ino)",
                               removeRetired: { unlinkat($0, $1, AT_REMOVEDIR) })
    }

    private static func retireEmptyPlan(root: Int32, plan: Int32, lease: Int32, name: String, retirement: String,
                                        removeRetired: (Int32, String) -> Int32) -> Bool {
        sameEntry(lease, parent: plan, name: "in-use") && sameEntry(plan, parent: root, name: name)
            && (name == retirement || renameatx_np(root, name, root, retirement, UInt32(RENAME_EXCL)) == 0)
            && sameEntry(plan, parent: root, name: retirement) && fsync(root) == 0
            && unlinkat(plan, "in-use", 0) == 0 && removeRetired(root, retirement) == 0
    }

    static func sameEntry(_ opened: Int32, parent: Int32, name: String) -> Bool {
        var current = stat(), named = stat()
        return fstat(opened, &current) == 0 && fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0
            && current.st_dev == named.st_dev && current.st_ino == named.st_ino
    }

    private static func clear(_ folder: Int32, device: dev_t, keeping: String? = nil, depth: Int = 0) -> Bool {
        guard depth < 12 else { return false }
        var ok = true
        let listed = ClusterPrefixRecordDirectory.forEachName(in: folder) { name in
            if name == keeping { return }
            var s = stat()
            guard fstatat(folder, name, &s, AT_SYMLINK_NOFOLLOW) == 0, s.st_uid == getuid(), s.st_dev == device else {
                ok = false; return
            }
            if s.st_mode & S_IFMT == S_IFDIR {
                guard let child = ClusterPrefixRecordDirectory.openChild(folder, name, device: device) else { ok = false; return }
                defer { close(child) }
                if !clear(child, device: device, depth: depth + 1) || !sameEntry(child, parent: folder, name: name)
                    || unlinkat(folder, name, AT_REMOVEDIR) != 0 { ok = false }
            } else if unlinkat(folder, name, 0) != 0 { ok = false }
        }
        return listed && ok
    }
}
