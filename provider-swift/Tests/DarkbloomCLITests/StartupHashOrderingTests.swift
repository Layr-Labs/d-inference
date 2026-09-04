import Foundation
import Testing

@testable import darkbloom

/// T4-02 (a): the startup weight-hash pass must run AFTER the auto-update
/// check, and never at all when the update path takes over the process
/// (an exec into the new binary surfaces here as a throw).
@Suite("Startup hash ordering")
struct StartupHashOrderingTests {
    private final class OrderRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []
        func record(_ step: String) { lock.withLock { entries.append(step) } }
        var snapshot: [String] { lock.withLock { entries } }
    }

    private struct ExecTookOver: Error {}

    @Test("the update check completes before the hash pass starts")
    func updateCheckPrecedesHashing() async throws {
        let order = OrderRecorder()
        let hashes = try await StartupHashOrdering.run(
            checkForUpdate: { order.record("update-check") },
            hashModels: { () -> [String: String] in
                order.record("hash-pass")
                return ["model": "hash"]
            })
        #expect(order.snapshot == ["update-check", "hash-pass"])
        #expect(hashes == ["model": "hash"])
    }

    @Test("an update that takes over the process never runs the hash pass")
    func execSkipsHashing() async {
        let order = OrderRecorder()
        await #expect(throws: ExecTookOver.self) {
            _ = try await StartupHashOrdering.run(
                checkForUpdate: {
                    order.record("update-check")
                    throw ExecTookOver()
                },
                hashModels: { () -> Int in
                    order.record("hash-pass")
                    return 0
                })
        }
        #expect(order.snapshot == ["update-check"])
    }
}
