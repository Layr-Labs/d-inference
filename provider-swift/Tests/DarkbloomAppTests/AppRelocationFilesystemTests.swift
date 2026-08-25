import Foundation
import Testing
@testable import DarkbloomApp

@Suite("App relocation filesystem")
struct AppRelocationFilesystemTests {
    @Test("bin candidate hash stays stable when its app targets appear")
    func binCandidateHashDoesNotResolveSymlinkTargets() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "app-relocation-filesystem-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }

        let installRoot = root.appendingPathComponent(
            ".darkbloom",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: installRoot,
            withIntermediateDirectories: true
        )
        let candidate = try AppRelocationBinLayout(
            installRoot: installRoot,
            fileManager: fileManager
        ).prepareCandidate(
            transactionID: "00000000-0000-0000-0000-000000000001"
        ).url

        let before = try AppRelocationFilesystem.synchronizedState(at: candidate)

        let appBin = installRoot.appendingPathComponent(
            "Darkbloom.app/Contents/MacOS",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: appBin,
            withIntermediateDirectories: true
        )
        for name in ["darkbloom", "darkbloom-enclave", "mlx.metallib"] {
            try Data("published-\(name)".utf8).write(
                to: appBin.appendingPathComponent(name)
            )
        }

        let after = try AppRelocationFilesystem.synchronizedState(at: candidate)

        #expect(after.identity == before.identity)
        #expect(after.contentHash == before.contentHash)
    }

    @Test("tree hash remains bound to lexical symlink targets")
    func treeHashDetectsSymlinkTargetMutation() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "app-relocation-symlink-hash-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let link = root.appendingPathComponent("tool")
        try fileManager.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: "../first/tool"
        )
        let before = try AppRelocationFilesystem.synchronizedState(at: root)

        try fileManager.removeItem(at: link)
        try fileManager.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: "../second/tool"
        )
        let after = try AppRelocationFilesystem.synchronizedState(at: root)

        #expect(after.identity == before.identity)
        #expect(after.contentHash != before.contentHash)
    }
}
