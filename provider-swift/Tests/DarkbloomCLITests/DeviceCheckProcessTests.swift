import Foundation
import Testing
@testable import darkbloom

@Suite("DeviceCheck log process")
struct DeviceCheckProcessTests {
    @Test func timeoutKillsAChildThatIgnoresTerminationWithoutWaitingForever() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("log-timeout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("child.pid")
        let started = ContinuousClock.now
        #expect(throws: CocoaError.self) {
            try DeviceCheckEvidence.runLog(
                ["-c", "trap '' TERM; echo $$ > \"$1\"; exec /bin/sleep 30", "log-test", pidFile.path],
                executable: URL(fileURLWithPath: "/bin/sh"), timeout: 0.5, terminationGrace: 0.1, directory: directory)
        }
        #expect(started.duration(to: .now) < .seconds(3))
        let pidText = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try #require(Int32(pidText))
        // Reaping is asynchronous, but the timed-out process must not survive.
        let reapDeadline = Date().addingTimeInterval(2)
        while kill(pid, 0) == 0 && Date() < reapDeadline { Thread.sleep(forTimeInterval: 0.01) }
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["child.pid"])
    }

    @Test func capturesExitOutputAndCleansFilesOnSuccessOrLaunchFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("log-output-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try DeviceCheckEvidence.runLog(["-c", "echo output; echo denied >&2; exit 77"],
            executable: URL(fileURLWithPath: "/bin/sh"), timeout: 2, directory: directory)
        #expect(result.status == 77)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "output\n")
        #expect(result.stderr == "denied\n")
        #expect(throws: (any Error).self) {
            try DeviceCheckEvidence.runLog([], executable: directory.appendingPathComponent("absent"), directory: directory)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
}
