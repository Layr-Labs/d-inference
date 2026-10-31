import Darwin
import Foundation

/// Refuses to start a rank over memory a dead process left wired.
///
/// A rank that ends without its release (a crash, a SIGKILL, an exit the
/// kernel could not finish) can leave its pages wired with no process that
/// owns them; the owner's tools saw 92-176 GB stay wired until a restart.
/// A rank loaded over that memory is admitted against memory the Mac does not
/// have and fails later and less clearly. So a worker, and the owner that
/// would launch one, first compares the Mac's wired memory with its idle
/// baseline, but only when no other Darkbloom process runs on the Mac (one
/// that does may hold that memory legitimately, and is never second-guessed).
///
/// The idle baseline is the most macOS holds wired by itself, with margin: the
/// larger of 16 GiB and a tenth of physical memory, the same reserve the stage
/// residency leaves unwired. Measured idle wired memory on the two Macs of the
/// pair before 691 earlier launches: 6.6-14.6 GiB on the 256 GiB Mac (median
/// 8.9), 4.6-9.9 GiB on the 128 GiB Mac (median 5.2); their baselines are
/// 25.6 GiB and 16 GiB.
///
/// Fail-open by contract: a probe that cannot read the counters reports
/// `skipped` and the start goes on; only a measurement can refuse.
public enum ClusterOrphanWiredGuard {
    public enum Decision: Equatable, Sendable {
        case clear(wiredBytes: UInt64, baselineBytes: UInt64)
        case skipped(String)
        case refused(String)
    }

    public static let gibibyte: UInt64 = 1 << 30

    /// What an idle Mac of this size may hold wired by itself.
    public static func idleBaselineBytes(physicalBytes: UInt64) -> UInt64 {
        max(16 * gibibyte, physicalBytes / 10 + (physicalBytes % 10 == 0 ? 0 : 1))
    }

    /// The pure decision, from measured values.
    public static func decide(wiredBytes: UInt64, physicalBytes: UInt64, otherDarkbloomProcesses: [String]) -> Decision {
        guard physicalBytes > 0 else { return .skipped("physical memory unknown") }
        let baseline = idleBaselineBytes(physicalBytes: physicalBytes)
        if !otherDarkbloomProcesses.isEmpty {
            return .skipped("\(otherDarkbloomProcesses.count) other Darkbloom process\(otherDarkbloomProcesses.count == 1 ? "" : "es") running ("
                + otherDarkbloomProcesses.prefix(4).joined(separator: ", ") + ")")
        }
        guard wiredBytes > baseline else { return .clear(wiredBytes: wiredBytes, baselineBytes: baseline) }
        return .refused("\(gib(wiredBytes)) GiB of memory is wired on this Mac and no other Darkbloom process is running; "
            + "its idle baseline is \(gib(baseline)) GiB (the larger of 16 GiB and a tenth of its \(gib(physicalBytes)) GiB). "
            + "Memory that a process left wired when it ended without releasing it comes back only with a restart: "
            + "restart this Mac, then start again. If another application holds this memory, quit it first.")
    }

    /// Measures and decides. `role` names the caller in the log line.
    public static func evaluate(role: String) -> Decision {
        guard let wired = wiredBytes() else { return .skipped("wired memory could not be read") }
        return decide(wiredBytes: wired, physicalBytes: physicalBytes(), otherDarkbloomProcesses: otherDarkbloomProcesses())
    }

    /// Throws on a refusal; writes one line to standard error either way.
    public static func check(role: String) throws {
        let decision = evaluate(role: role)
        let line: String
        switch decision {
        case .clear(let wired, let baseline):
            line = "darkbloom-orphan-wired-v1 role=\(role) decision=clear wired=\(wired) baseline=\(baseline)"
        case .skipped(let why):
            // Reports keep only lines of lowercase letters, digits, ' ', '-', '=' and '_'.
            let token = String(why.lowercased().map { ("a"..."z").contains($0) || ("0"..."9").contains($0) ? $0 : "_" })
            line = "darkbloom-orphan-wired-v1 role=\(role) decision=skipped reason=\(token)"
        case .refused:
            line = "darkbloom-orphan-wired-v1 role=\(role) decision=refused"
        }
        FileHandle.standardError.write(Data((line + "\n").utf8))
        if case .refused(let message) = decision { throw ClusterWorkerOwnerError.invalid(message) }
    }

    // MARK: Probes

    /// The Mac's wired pages, in bytes; nil when the counters cannot be read.
    public static func wiredBytes() -> UInt64? {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &statistics) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        var page: vm_size_t = 0
        guard result == KERN_SUCCESS, host_page_size(mach_host_self(), &page) == KERN_SUCCESS, page > 0 else { return nil }
        return UInt64(statistics.wire_count) * UInt64(page)
    }

    public static func physicalBytes() -> UInt64 { ProcessInfo.processInfo.physicalMemory }

    /// Running processes whose executable name starts with "darkbloom", other
    /// than this process and its ancestors (the owner, a driver, a provider
    /// that launched it). A process that is already a zombie holds nothing
    /// and does not count.
    public static func otherDarkbloomProcesses() -> [String] {
        let capacity = Int(proc_listallpids(nil, 0))
        guard capacity > 0 else { return [] }
        var identifiers = [Int32](repeating: 0, count: capacity + 64)
        let filled = identifiers.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard filled > 0 else { return [] }
        var excluded = Set<Int32>()
        var current = getpid()
        while current > 1, excluded.insert(current).inserted, let info = bsdInfo(current) { current = Int32(info.pbi_ppid) }
        var result: [String] = []
        for identifier in identifiers.prefix(Int(filled)) where identifier > 0 && !excluded.contains(identifier) {
            guard let name = executableName(identifier), name.hasPrefix("darkbloom") else { continue }
            if let info = bsdInfo(identifier), info.pbi_status == UInt32(SZOMB) { continue }
            result.append(name)
        }
        return result.sorted()
    }

    private static func executableName(_ identifier: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(identifier, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return path.split(separator: "/").last.map(String.init)
    }

    private static func bsdInfo(_ identifier: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        return proc_pidinfo(identifier, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    private static func gib(_ bytes: UInt64) -> String { String(format: "%.1f", Double(bytes) / Double(gibibyte)) }
}
