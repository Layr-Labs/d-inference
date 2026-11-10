import Darwin
import Foundation
import Testing
@testable import ProviderCore

/// The stderr tail keeps only its last `captureStderrTail` bytes resident
/// while a child runs: a tail kept as a slice of its buffer, or reads left in
/// an undrained autorelease pool, keep every byte the child wrote. Real child
/// processes only.
@Suite("Bounded child process stderr memory")
struct BoundedProcessStderrMemoryTests {
    private static let stderrBytes = 256 << 20
    private static let tailBytes = 4096
    private static let allowedGrowth: UInt64 = 64 << 20

    @Test("BoundedProcess keeps only its stderr tail while the child runs")
    func stderrTailStaysBounded() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bounded-process-stderr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let written = directory.appendingPathComponent("written")
        let release = directory.appendingPathComponent("release")
        // Writes the bytes to stderr, marks `written` (by then the reader has
        // taken all but one pipe buffer of them), waits at most 60 s for
        // `release`, then fails so the tail is reported.
        let script = """
            head -c \(Self.stderrBytes) /dev/zero >&2
            : > '\(written.path)'
            i=0
            while [ ! -e '\(release.path)' ] && [ "$i" -lt 1200 ]; do sleep 0.05; i=$((i + 1)); done
            exit 3
            """

        let before = try #require(Self.footprint())
        let run = Task.detached { () -> (any Error)? in
            do {
                try BoundedProcess.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], timeout: 120,
                                       captureStderrTail: Self.tailBytes)
                return nil
            } catch {
                return error
            }
        }
        let finished = try await Self.waitForFile(written)
        let during = try #require(Self.footprint())
        #expect(FileManager.default.createFile(atPath: release.path, contents: nil))
        let failure = await run.value

        #expect(finished, "the child never finished writing")
        if case .exited(let status, let tail)? = failure as? BoundedProcess.Failure {
            #expect(status == 3)
            #expect(tail == String(repeating: "\u{0}", count: Self.tailBytes))
        } else {
            Issue.record("expected exit 3 with its stderr tail, got \(String(describing: failure))")
        }
        let growth = during > before ? during - before : 0
        #expect(growth < Self.allowedGrowth, "the stderr reader held \(growth) bytes of \(Self.stderrBytes) read")
    }

    /// True once `url` exists; false after 60 s.
    private static func waitForFile(_ url: URL) async throws -> Bool {
        for _ in 0..<3000 {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    private static func footprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }
}
