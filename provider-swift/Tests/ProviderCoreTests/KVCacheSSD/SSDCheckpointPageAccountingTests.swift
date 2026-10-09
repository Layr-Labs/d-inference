import Foundation
import Testing
@testable import ProviderCore

@Suite("Shared checkpoint accounting path identity")
struct SSDCheckpointPageAccountingTests {
    @Test("system path aliases register, reconcile and retire one endpoint identity")
    func systemAliases() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("page-accounting-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = root.appendingPathComponent("0123456789ab")
        try SSDBlockStore.prepareModelRoot(dedicatedRoot: root, modelRoot: model)
        let first = SSDBlockStore.fileURL(root: model, tag16Hex: String(repeating: "a", count: 32))
        let second = SSDBlockStore.fileURL(root: model, tag16Hex: String(repeating: "b", count: 32))
        try SSDNoFollowIO.prepareDirectory(first.deletingLastPathComponent())
        try SSDNoFollowIO.prepareDirectory(second.deletingLastPathComponent())
        try Data(count: 7).write(to: first)
        try Data(count: 11).write(to: second)
        let sharedID = String(repeating: "c", count: 64)
        let firstPage = SSDCheckpointPageFiles.pageURL(checkpoint: first, id: sharedID)
        let secondPage = SSDCheckpointPageFiles.pageURL(checkpoint: second, id: sharedID)
        try SSDNoFollowIO.prepareDirectory(firstPage.deletingLastPathComponent())
        try Data(count: 100).write(to: firstPage)
        try SSDCheckpointPageFiles.link(from: firstPage, to: secondPage,
            strictFsync: false, authenticate: { _ in })

        func alternateSystemAlias(_ file: URL) -> URL {
            let path = file.path
            return URL(fileURLWithPath: path.hasPrefix("/private/var/")
                ? String(path.dropFirst("/private".count)) : "/private" + path)
        }
        let firstAlias = alternateSystemAlias(first)
        let secondAlias = alternateSystemAlias(second)
        #expect(first.path != firstAlias.path)
        #expect(SSDCheckpointFileCoordinator.pathKey(for: first)
            == SSDCheckpointFileCoordinator.pathKey(for: firstAlias))
        let accounting = SSDCheckpointPageAccounting()
        accounting.register(checkpoint: firstAlias)
        accounting.register(checkpoint: secondAlias)
        accounting.register(checkpoint: first)
        #expect(accounting.diskBytes(indexedBytes: 218) == 118)
        accounting.remove(checkpoint: first)
        // The real shared inode remains charged once to its second endpoint.
        #expect(accounting.diskBytes(indexedBytes: 111) == 111)
        accounting.reconcile(indexedCheckpoints: [second])
        #expect(accounting.diskBytes(indexedBytes: 111) == 111)
        accounting.remove(checkpoint: secondAlias)
        #expect(accounting.diskBytes(indexedBytes: 0) == 0)
    }
}
