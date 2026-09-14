import Foundation
import Testing
@testable import ProviderCore

@Suite("Checkpoint coordination path stability", .serialized)
struct SSDCheckpointFileCoordinatorPathTests {
    private func expectCoordination(
        ownerURL: URL, waiterURL: URL, shared: Bool = true,
        beforeWaiter: () throws -> Void = {}
    ) async throws {
        let coordinator = SSDCheckpointFileCoordinator()
        let owner = coordinator.makeAccess(to: ownerURL)
        try await owner.acquire()
        defer { owner.release() }
        try beforeWaiter()
        let waiter = coordinator.makeAccess(to: waiterURL)
        let task = Task { try await waiter.acquire() }
        defer { task.cancel(); waiter.cancel(); waiter.release() }
        try await SSDCheckpointCoordinationTestSupport.waitUntil {
            coordinator.pendingCount(for: waiterURL) == 1 || coordinator.trackedFileCount == 2
        }
        #expect(coordinator.trackedFileCount == (shared ? 1 : 2))
        #expect(coordinator.pendingCount(for: ownerURL) == (shared ? 1 : 0))
        #expect(coordinator.pendingCount(for: waiterURL) == (shared ? 1 : 0))
        owner.release()
        try await task.value
        waiter.release()
        #expect(coordinator.trackedFileCount == 0)
    }

    @Test("the same URL keeps its key across creation and deletion", arguments: ["/private/tmp", "/private/var/tmp"])
    func existenceChanges(root: String) async throws {
        let directory = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent("ssd-path-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("checkpoint.dbk3", isDirectory: false)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        try await expectCoordination(ownerURL: file, waiterURL: file) {
            try Data([0x31]).write(to: file, options: .atomic)
        }
        try await expectCoordination(ownerURL: file, waiterURL: file) {
            try FileManager.default.removeItem(at: file)
        }
    }

    @Test("supported aliases share one key with or without a published target", arguments: ["/tmp", "/var/tmp"])
    func systemAliases(root: String) async throws {
        let directory = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent("ssd-alias-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let alias = directory.appendingPathComponent("checkpoint.dbk3", isDirectory: false)
        let physical = URL(fileURLWithPath: "/private" + alias.path, isDirectory: false)
        for published in [false, true] {
            if published { try Data([0x31]).write(to: physical) }
            try await expectCoordination(ownerURL: alias, waiterURL: physical)
            try await expectCoordination(ownerURL: physical, waiterURL: alias)
        }
    }

    @Test("lexical normalization handles dots, parents, repeated separators, and root bounds")
    func lexicalNormalization() async throws {
        let paths = [
            ("/private/tmp/checkpoints//./nested/../file.dbk3", "/tmp/checkpoints/file.dbk3"),
            ("//private//var/tmp/checkpoints/./file.dbk3", "/var/tmp/checkpoints/file.dbk3"),
            ("/discard/../tmp/checkpoints/file.dbk3", "/private/tmp/checkpoints/file.dbk3"),
            ("/../../tmp/checkpoints/file.dbk3", "/private/tmp/checkpoints/file.dbk3"),
            ("/tmp/../checkpoints/file.dbk3", "/private/checkpoints/file.dbk3"),
            ("/var/../tmp/checkpoints/file.dbk3", "/private/tmp/checkpoints/file.dbk3"),
            ("/private/tmp/../../tmp/checkpoints/file.dbk3", "/private/tmp/checkpoints/file.dbk3"),
            ("/tmp/../../var/tmp/checkpoints/file.dbk3", "/private/var/tmp/checkpoints/file.dbk3"),
            ("/tmp/../../checkpoints/file.dbk3", "/checkpoints/file.dbk3"),
            ("/checkpoints//./nested/../file.dbk3", "/checkpoints/file.dbk3"),
        ]
        for (owner, waiter) in paths {
            try await expectCoordination(ownerURL: URL(fileURLWithPath: owner, isDirectory: false),
                                         waiterURL: URL(fileURLWithPath: waiter, isDirectory: false))
        }
    }

    @Test("alias matching respects component boundaries and preserves unrelated files")
    func unrelatedPaths() async throws {
        let paths = [
            ("/tmp-cache/checkpoint.dbk3", "/private/tmp-cache/checkpoint.dbk3"),
            ("/var-cache/checkpoint.dbk3", "/private/var-cache/checkpoint.dbk3"),
            ("/cache/tmp/checkpoint.dbk3", "/cache/private/tmp/checkpoint.dbk3"),
            ("/tmp/first.dbk3", "/private/tmp/second.dbk3"),
            ("/tmp/checkpoint.dbk3", "/var/checkpoint.dbk3"),
        ]
        for (owner, waiter) in paths {
            try await expectCoordination(ownerURL: URL(fileURLWithPath: owner, isDirectory: false),
                                         waiterURL: URL(fileURLWithPath: waiter, isDirectory: false), shared: false)
        }
    }
}
