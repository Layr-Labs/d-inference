import Foundation
import ProviderCoreFoundation
import Testing
@testable import darkbloom

private final class ProcessLockBundleAnchor {}

@Suite("ProcessLifecycle cross-process exclusion", .serialized)
struct ProcessLifecycleSubprocessTests {
    private struct OwnerRecord: Decodable {
        let schema: Int
        let processIdentity: ProcessIdentity

        enum CodingKeys: String, CodingKey {
            case schema
            case processIdentity = "process_identity"
        }
    }

    private var binary: URL {
        let anchor = Bundle(for: ProcessLockBundleAnchor.self).bundleURL
        let productsDirectory = anchor.pathExtension == "xctest"
            ? anchor.deletingLastPathComponent()
            : anchor
        return productsDirectory.appendingPathComponent("darkbloom")
    }

    @Test("concurrent contenders cannot replace a record while another process holds the kernel lock")
    func concurrentContendersRemainExcluded() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let owner = try launchProbe(
            pidFile: fixture.pidFile,
            readyFile: fixture.file("owner.ready"),
            releaseFile: fixture.file("owner.release")
        )
        defer {
            if owner.isRunning { owner.terminate() }
        }
        try await requireFile(fixture.file("owner.ready"))

        // Simulate a corrupt/legacy owner record while the real owner retains
        // the sidecar flock. No contender can safely signal it, and none may
        // replace the record merely because PID attribution is unavailable.
        try Data("123\n".utf8).write(to: fixture.pidFile, options: .atomic)

        var contenders: [Process] = []
        for index in 0..<6 {
            contenders.append(try launchProbe(
                pidFile: fixture.pidFile,
                readyFile: fixture.file("contender-\(index).ready"),
                releaseFile: fixture.file("contender-\(index).release"),
                terminationGrace: 0.1
            ))
        }
        defer {
            contenders.forEach {
                if $0.isRunning { $0.terminate() }
            }
        }

        for (index, contender) in contenders.enumerated() {
            try await requireExit(contender)
            #expect(contender.terminationStatus != 0)
            #expect(!FileManager.default.fileExists(
                atPath: fixture.file("contender-\(index).ready").path
            ))
        }
        #expect(owner.isRunning)
        #expect(try String(contentsOf: fixture.pidFile, encoding: .utf8) == "123\n")

        try fixture.touch("owner.release")
        try await requireExit(owner)
        #expect(owner.terminationStatus == 0)
    }

    @Test("a successor terminates only the recorded identity and takes the released lock")
    func identitySafeTakeover() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let owner = try launchProbe(
            pidFile: fixture.pidFile,
            readyFile: fixture.file("owner.ready"),
            releaseFile: fixture.file("owner.release")
        )
        defer {
            if owner.isRunning { owner.terminate() }
        }
        try await requireFile(fixture.file("owner.ready"))

        let successor = try launchProbe(
            pidFile: fixture.pidFile,
            readyFile: fixture.file("successor.ready"),
            releaseFile: fixture.file("successor.release")
        )
        defer {
            if successor.isRunning { successor.terminate() }
        }
        try await requireFile(fixture.file("successor.ready"))
        try await requireExit(owner)

        #expect(!owner.isRunning)
        #expect(successor.isRunning)
        let ownerData = try Data(contentsOf: fixture.pidFile)
        let record = try JSONDecoder().decode(OwnerRecord.self, from: ownerData)
        let successorIdentity = try #require(
            ProcessIdentity.read(pid: Int32(successor.processIdentifier))
        )
        #expect(record.schema == 1)
        #expect(record.processIdentity == successorIdentity)

        try fixture.touch("successor.release")
        try await requireExit(successor)
        #expect(successor.terminationStatus == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.pidFile.path))
    }

    private func launchProbe(
        pidFile: URL,
        readyFile: URL,
        releaseFile: URL,
        terminationGrace: Double = 1
    ) throws -> Process {
        let process = Process()
        process.executableURL = binary
        process.arguments = [
            "_runtime-lock-probe",
            "--pid-file", pidFile.path,
            "--ready-file", readyFile.path,
            "--release-file", releaseFile.path,
            "--termination-grace", String(terminationGrace),
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["DARKBLOOM_NO_UPDATE_CHECK"] = "1"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    private func requireFile(
        _ file: URL,
        timeout: Duration = .seconds(5)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if FileManager.default.fileExists(atPath: file.path) {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for \(file.lastPathComponent)")
        throw TestFailure.timeout
    }

    private func requireExit(
        _ process: Process,
        timeout: Duration = .seconds(5)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if !process.isRunning {
                process.waitUntilExit()
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for process \(process.processIdentifier)")
        throw TestFailure.timeout
    }

    private enum TestFailure: Error {
        case timeout
    }

    private struct Fixture {
        let directory: URL
        let pidFile: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "darkbloom-process-lock-\(UUID().uuidString)",
                    isDirectory: true
                )
            pidFile = directory.appendingPathComponent("provider.pid")
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }

        func file(_ name: String) -> URL {
            directory.appendingPathComponent(name)
        }

        func touch(_ name: String) throws {
            try Data().write(to: file(name), options: .atomic)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
