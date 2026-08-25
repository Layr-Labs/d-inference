import Foundation
import Testing
@testable import ProviderCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite("Update atomic filesystem")
struct UpdateAtomicFilesystemTests {
    @Test("full sync success does not invoke the fallback")
    func fullSyncSuccess() throws {
        var calls: [String] = []
        try UpdateAtomicFilesystem.synchronizeRegularFile(
            fullSync: {
                calls.append("full")
                return .success
            },
            fallbackSync: {
                calls.append("fallback")
                return .success
            },
            operation: "test sync"
        )
        #expect(calls == ["full"])
    }

    @Test("full sync failure falls back to retrying fsync")
    func fullSyncFallbackRetriesInterruptions() throws {
        var fullResults: [UpdateAtomicFilesystem.DurabilitySyncResult] = [
            .failure(EINTR),
            .failure(ENOTSUP),
        ]
        var fallbackResults: [UpdateAtomicFilesystem.DurabilitySyncResult] = [
            .failure(EINTR),
            .success,
        ]
        try UpdateAtomicFilesystem.synchronizeRegularFile(
            fullSync: {
                fullResults.removeFirst()
            },
            fallbackSync: {
                fallbackResults.removeFirst()
            },
            operation: "test sync"
        )
        #expect(fullResults.isEmpty)
        #expect(fallbackResults.isEmpty)
    }

    @Test("fallback fsync error is surfaced with its errno")
    func fallbackErrorIsSurfaced() {
        do {
            try UpdateAtomicFilesystem.synchronizeRegularFile(
                fullSync: { .failure(ENOTSUP) },
                fallbackSync: { .failure(EIO) },
                operation: "test sync"
            )
            Issue.record("expected sync failure")
        } catch {
            let cocoa = error as NSError
            #expect(cocoa.domain == NSPOSIXErrorDomain)
            #expect(cocoa.code == Int(EIO))
            #expect(cocoa.localizedDescription.contains("test sync"))
        }
    }

    @Test("platforms without full sync use retrying fsync directly")
    func fsyncOnlyPathRetriesInterruptions() throws {
        var results: [UpdateAtomicFilesystem.DurabilitySyncResult] = [
            .failure(EINTR),
            .success,
        ]
        try UpdateAtomicFilesystem.synchronizeRegularFile(
            fullSync: nil,
            fallbackSync: {
                results.removeFirst()
            },
            operation: "test sync"
        )
        #expect(results.isEmpty)
    }

    @Test("durable write replaces regular files and removes temporary files")
    func durableWriteRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "update-atomic-filesystem-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("state.json")

        try UpdateAtomicFilesystem.write(Data("first".utf8), to: file)
        try UpdateAtomicFilesystem.write(Data("second".utf8), to: file)

        #expect(try Data(contentsOf: file) == Data("second".utf8))
        let entries = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )
        #expect(entries.map(\.lastPathComponent) == ["state.json"])
    }

    @Test("tree persistence syncs regular files and fsyncs directories")
    func fsyncTreeAndDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "update-fsync-tree-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(
            at: child,
            withIntermediateDirectories: true
        )
        try Data("durable".utf8).write(
            to: child.appendingPathComponent("artifact")
        )

        try UpdateAtomicFilesystem.fsyncTree(root)
        try UpdateAtomicFilesystem.syncDirectory(root)
    }
}
