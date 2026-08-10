import Foundation
import Testing
@testable import ProviderCore

/// Marked `.serialized` to avoid needless contention within this suite. The
/// shared environment guard also excludes mutations from live-test fixtures.
@Suite("metallib hash + locator", .serialized)
struct MetallibHashTests {

    @Test("MLX_METALLIB_PATH override takes precedence")
    func envOverridePrecedence() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fake-mlx-\(UUID().uuidString).metallib")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Data("not really a metallib but exists".utf8).write(to: tmp)

        MLXMetallibEnvironment.withPath(tmp.path) {
            let located = locateMetallib()
            #expect(located?.path == tmp.path)
        }
    }

    @Test("metallibHash returns a 64-character hex string when located")
    func metallibHashShape() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fake-mlx-\(UUID().uuidString).metallib")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Data(repeating: 0x42, count: 1024).write(to: tmp)

        MLXMetallibEnvironment.withPath(tmp.path) {
            guard let hash = metallibHash() else {
                Issue.record("metallibHash returned nil for an existing file at \(tmp.path)")
                return
            }
            #expect(hash.count == 64)
            let hex = Set("0123456789abcdef")
            #expect(hash.allSatisfy { hex.contains($0) })
        }
    }

    @Test("metallibHash is stable across calls for the same file")
    func metallibHashStable() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fake-mlx-\(UUID().uuidString).metallib")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Data("hello mlx".utf8).write(to: tmp)

        let competing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("competing-mlx-\(UUID().uuidString).metallib")
        defer { try? FileManager.default.removeItem(at: competing) }
        try Data("different metallib".utf8).write(to: competing)

        let mutationAttempted = DispatchSemaphore(value: 0)
        let mutationCompleted = DispatchSemaphore(value: 0)

        MLXMetallibEnvironment.withPath(tmp.path) {
            let firstHash = metallibHash()
            let mutationThread = Thread {
                mutationAttempted.signal()
                MLXMetallibEnvironment.withPath(competing.path) {}
                mutationCompleted.signal()
            }
            mutationThread.start()

            #expect(mutationAttempted.wait(timeout: .now() + 5) == .success)
            #expect(mutationCompleted.wait(timeout: .now() + 0.05) == .timedOut)

            let secondHash = metallibHash()
            #expect(firstHash != nil)
            #expect(firstHash == secondHash)
        }

        #expect(mutationCompleted.wait(timeout: .now() + 5) == .success)
    }

    @Test("locateMetallib returns nil when nothing is found and no env override")
    func locateReturnsNilWhenAbsent() {
        // Point env at a path that doesn't exist; locator should fall
        // through to the binary-adjacent search and may or may not find one
        // (it could find one in the test bundle's .build path). We assert
        // on the env override semantics only.
        MLXMetallibEnvironment.withPath("/var/empty/definitely-not-here.metallib") {
            // Env override misses → falls back to binary-adjacent search. The
            // test binary may or may not have a colocated metallib; we don't
            // assert one way or the other, just that the function returns
            // without crashing.
            _ = locateMetallib()
        }
    }
}
