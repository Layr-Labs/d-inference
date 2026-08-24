import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
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
        #elseif canImport(Glibc)
        return readLinuxProcIdentity(pid: pid)
        #else
        return nil
        #endif
    }

    public func isCurrent() -> Bool {
        Self.read(pid: pid) == self
    }
}

#if canImport(Glibc)
/// Linux exposes process start time as field 22 of `/proc/<pid>/stat`, in
/// clock ticks since boot. Add the kernel-recorded boot epoch before converting
/// to microseconds: ticks alone can repeat after a reboot, which would let a
/// stale persisted identity collide with a later process that received the
/// same PID at the same offset into a different boot.
private func readLinuxProcIdentity(pid: Int32) -> ProcessIdentity? {
    guard pid > 0,
          let bootTimeMicros = linuxBootTimeMicros,
          let stat = try? String(
              contentsOfFile: "/proc/\(pid)/stat",
              encoding: .utf8
          ),
          let commandEnd = stat.lastIndex(of: ")")
    else {
        return nil
    }

    // The suffix begins with field 3 (`state`). A process name may contain
    // spaces or parentheses, so splitting the entire line is not safe.
    let suffix = stat[stat.index(after: commandEnd)...]
        .split(whereSeparator: \.isWhitespace)
    let startTimeIndex = 22 - 3
    guard suffix.indices.contains(startTimeIndex),
          let startTicks = UInt64(suffix[startTimeIndex])
    else {
        return nil
    }

    let ticksPerSecond = sysconf(Int32(_SC_CLK_TCK))
    guard ticksPerSecond > 0 else { return nil }
    let frequency = UInt64(ticksPerSecond)
    let elapsedMicros = (startTicks / frequency) * 1_000_000
        + (startTicks % frequency) * 1_000_000 / frequency
    let (startTimeMicros, overflow) = bootTimeMicros.addingReportingOverflow(
        elapsedMicros
    )
    guard !overflow else { return nil }
    return ProcessIdentity(pid: pid, startTimeMicros: startTimeMicros)
}

/// `btime` is seconds since the Unix epoch and is immutable for this boot.
/// Cache it once so frequent endpoint trust checks only read the target
/// process's stat record.
private let linuxBootTimeMicros: UInt64? = {
    guard let stat = try? String(
        contentsOfFile: "/proc/stat",
        encoding: .utf8
    ),
          let bootLine = stat.split(separator: "\n").first(where: {
              $0.hasPrefix("btime ")
          }),
          let bootSeconds = UInt64(
              bootLine.dropFirst("btime ".count)
                  .trimmingCharacters(in: .whitespaces)
          )
    else {
        return nil
    }
    let (micros, overflow) = bootSeconds.multipliedReportingOverflow(
        by: 1_000_000
    )
    return overflow ? nil : micros
}()
#endif
