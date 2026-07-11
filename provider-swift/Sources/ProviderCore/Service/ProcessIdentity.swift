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
        let size = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(
                pid,
                PROC_PIDTBSDINFO,
                0,
                $0,
                Int32(MemoryLayout<proc_bsdinfo>.size)
            )
        }
        guard size == Int32(MemoryLayout<proc_bsdinfo>.size) else {
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
