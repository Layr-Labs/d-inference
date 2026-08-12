import Foundation
import Testing

@testable import ProviderCore

@Suite("telemetry overflow queue privacy boundary")
struct TelemetryOverflowQueueTests {
    @Test("events are never persisted and legacy files are purged")
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
        queue.push(TelemetryEvent(
            source: .provider,
            severity: .error,
            kind: .log,
            message: "PROMPT_SECRET_NEW_EVENT"))
        #expect(queue.drain(limit: .max).isEmpty)

        queue.purge()
        #expect(!FileManager.default.fileExists(atPath: path.path))
        #expect(!FileManager.default.fileExists(atPath: temporaryRewrite.path))
        #expect(!FileManager.default.fileExists(atPath: path.path + ".lock"))
    }
}
