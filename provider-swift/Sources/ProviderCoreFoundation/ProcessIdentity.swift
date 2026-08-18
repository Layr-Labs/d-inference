import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// PID plus kernel-recorded process start time, preventing PID-reuse mistakes.
public struct ProcessIdentity: Codable, Sendable, Equatable {
    public let pid: Int32
    public let startTimeMicros: UInt64

    public init(pid: Int32, startTimeMicros: UInt64) {
        self.pid = pid
        self.startTimeMicros = startTimeMicros
    }

    public static func current() -> ProcessIdentity? {
        read(pid: getpid())
    }

    public static func read(pid: Int32) -> ProcessIdentity? {
        #if canImport(Darwin)
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let size = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(
                pid,
                PROC_PIDTBSDINFO,
                0,
                $0,
                expectedSize
            )
        }
        // proc_pidinfo returns the number of bytes actually written: 0 for a
        // dead/nonexistent PID, a negative value on error, or a short count on
        // a partial read. Require the FULL struct before reading the start-time
        // fields — otherwise a dead PID would yield a zeroed identity
        // (startTimeMicros == 0) that could spuriously match another zeroed
        // identity during stale-lock-owner attribution.
        guard size == expectedSize else {
            return nil
        }
        let micros = UInt64(info.pbi_start_tvsec) * 1_000_000
            + UInt64(info.pbi_start_tvusec)
        return ProcessIdentity(pid: pid, startTimeMicros: micros)
        #else
        return nil
        #endif
    }

    public func isCurrent() -> Bool {
        Self.read(pid: pid) == self
    }
}
