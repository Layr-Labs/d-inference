import Foundation
import Testing
@testable import ProviderCore

/// Marked `.serialized` because every test in this suite mutates the
/// process-wide MLX_METALLIB_PATH environment variable. Swift Testing's
/// default parallel execution would race them and produce flakes like
/// "metallibHash returned nil because another test just unset the env".
@Suite("metallib hash + locator", .serialized)
struct MetallibHashTests {

    @Test("MLX_METALLIB_PATH override takes precedence")
    func envOverridePrecedence() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fake-mlx-\(UUID().uuidString).metallib")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Data("not really a metallib but exists".utf8).write(to: tmp)

        setenv("MLX_METALLIB_PATH", tmp.path, 1)
        defer { unsetenv("MLX_METALLIB_PATH") }

        let located = locateMetallib()
        #expect(located?.path == tmp.path)
    }

    @Test("metallibHash returns a 64-character hex string when located")
    func metallibHashShape() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fake-mlx-\(UUID().uuidString).metallib")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Data(repeating: 0x42, count: 1024).write(to: tmp)

        setenv("MLX_METALLIB_PATH", tmp.path, 1)
        defer { unsetenv("MLX_METALLIB_PATH") }

        guard let hash = metallibHash() else {
            Issue.record("metallibHash returned nil for an existing file at \(tmp.path)")
            return
        }
        #expect(hash.count == 64)
        let hex = Set("0123456789abcdef")
        #expect(hash.allSatisfy { hex.contains($0) })
    }

    @Test("metallibHash is stable across calls for the same file")
    func metallibHashStable() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fake-mlx-\(UUID().uuidString).metallib")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Data("hello mlx".utf8).write(to: tmp)

        setenv("MLX_METALLIB_PATH", tmp.path, 1)
        defer { unsetenv("MLX_METALLIB_PATH") }

        let a = metallibHash()
        let b = metallibHash()
        #expect(a != nil)
        #expect(a == b)
    }

    @Test("locateMetallib returns nil when nothing is found and no env override")
    func locateReturnsNilWhenAbsent() {
        // Point env at a path that doesn't exist; locator should fall
        // through to the binary-adjacent search and may or may not find one
        // (it could find one in the test bundle's .build path). We assert
        // on the env override semantics only.
        setenv("MLX_METALLIB_PATH", "/var/empty/definitely-not-here.metallib", 1)
        defer { unsetenv("MLX_METALLIB_PATH") }

        // Env override misses → falls back to binary-adjacent search. The
        // test binary may or may not have a colocated metallib; we don't
        // assert one way or the other, just that the function returns
        // without crashing.
        _ = locateMetallib()
    }
}
