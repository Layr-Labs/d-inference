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
    }

    public static func run(root: URL, keeping: String? = nil, includeStaging: Bool) -> Result {
        var report = Result()
        var path = root.path
        if path.hasPrefix("/var/") || path.hasPrefix("/tmp/") { path = "/private" + path }
        let parts = path.split(separator: "/").map(String.init)
        guard path.hasPrefix("/"), let basename = parts.last,
              !parts.contains("."), !parts.contains("..") else { report.problems.append("invalid cache root"); return report }
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var parent = Darwin.open("/", flags)
        guard parent >= 0 else { report.problems.append("cannot inspect cache root"); return report }
        defer { close(parent) }
        for part in parts.dropLast() {
            let next = openat(parent, part, flags)
            guard next >= 0 else { if errno != ENOENT { report.problems.append("cannot inspect cache path") }; return report }
            close(parent); parent = next
        }
        let fd = openat(parent, basename, flags)
        guard fd >= 0 else { if errno != ENOENT { report.problems.append("cannot open cache root") }; return report }
        defer { close(fd) }
        var s = stat()
        guard fstat(fd, &s) == 0, s.st_uid == getuid() else { report.problems.append("cannot verify cache root"); return report }
        // A live rank holds this directory shared. Its own plan can still be
        // inspected, but no staging/root removal without the exclusive lease.
        let exclusive = includeStaging && flock(fd, LOCK_EX | LOCK_NB) == 0
        let device = s.st_dev
        let listed = ClusterPrefixRecordDirectory.forEachName(in: fd) { name in
            guard name != keeping, ClusterPrefixRecordDirectory.isPlan(name) else { return }
            guard let plan = ClusterPrefixRecordDirectory.openChild(fd, name, device: device) else {
                report.problems.append("\(name): cannot inspect"); return
            }
            defer { close(plan) }
            switch ClusterPrefixRecordDirectory.lease(plan) {
            case .held: report.keptLive += 1
            case .unknown: report.problems.append("\(name): cannot verify lease")
            case .acquired(let lease):
                defer { close(lease) }
                guard clear(plan, device: device, keeping: "in-use"),
                      sameEntry(lease, parent: plan, name: "in-use"),
                      sameEntry(plan, parent: fd, name: name),
                      unlinkat(plan, "in-use", 0) == 0, unlinkat(fd, name, AT_REMOVEDIR) == 0 else {
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
