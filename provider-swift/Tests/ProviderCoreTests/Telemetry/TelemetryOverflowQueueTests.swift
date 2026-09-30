import Foundation
import Testing

@testable import ProviderCore

@Suite("telemetry overflow queue privacy boundary")
struct TelemetryOverflowQueueTests {
    @Test("legacy queue files are purged without creating anything")
    func queueDropsAndPurges() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("telemetry-queue-\(UUID().uuidString).jsonl")
        let temporaryRewrite = path.appendingPathExtension("tmp")
        defer {
            try? FileManager.default.removeItem(at: path)
            try? FileManager.default.removeItem(at: temporaryRewrite)
        }

        try "PROMPT_SECRET_LEGACY_QUEUE".write(
            to: path, atomically: true, encoding: .utf8)
        try "PROMPT_SECRET_INTERRUPTED_REWRITE".write(
            to: temporaryRewrite, atomically: true, encoding: .utf8)

        let queue = TelemetryOverflowQueue(path: path)
        queue.purge()
        #expect(!FileManager.default.fileExists(atPath: path.path))
        #expect(!FileManager.default.fileExists(atPath: temporaryRewrite.path))
        #expect(!FileManager.default.fileExists(atPath: path.path + ".lock"))
    }

    @Test("purge leaves symlinks and non-regular artifacts untouched")
    func purgeRejectsNonRegularArtifacts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("telemetry-purge-\(UUID().uuidString)")
        let target = root.appendingPathComponent("target.txt")
        let queuePath = root.appendingPathComponent("telemetry-queue.jsonl")
        let temporaryRewrite = queuePath.appendingPathExtension("tmp")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "LEGACY_SECRET".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: queuePath,
            withDestinationURL: target)
        try FileManager.default.createDirectory(
            at: temporaryRewrite,
            withIntermediateDirectories: false)

        TelemetryOverflowQueue(path: queuePath).purge()

        #expect(FileManager.default.fileExists(atPath: queuePath.path))
        #expect(FileManager.default.fileExists(atPath: temporaryRewrite.path))
        #expect(try String(contentsOf: target, encoding: .utf8) == "LEGACY_SECRET")
    }
}
