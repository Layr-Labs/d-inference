import Darwin
import Foundation
import Testing
@testable import ProviderCore

/// The update hashes read files in bounded chunks: when a hash returns, no
/// copy of the file's bytes stays resident on the thread that ran it, even
/// before that thread drains its autorelease pool.
@Suite("Update file hash memory")
struct UpdateFileHashMemoryTests {
    private static let fileBytes: UInt64 = 256 << 20
    private static let allowedGrowth: UInt64 = 64 << 20

    @Test("sha256(file:) and treeHash(root:) of a 256 MiB file keep none of its chunks resident")
    func hashesKeepNoChunkResident() throws {
        let fm = FileManager.default
        // The real path, so the tree's entries are relative to the root.
        let temporary = try #require(realpath(fm.temporaryDirectory.path, nil).map {
            defer { free($0) }
            return String(cString: $0)
        })
        let root = URL(fileURLWithPath: temporary)
            .appendingPathComponent("update-hash-memory-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        // Sparse: 256 MiB of zero bytes to read, none on disk.
        let file = root.appendingPathComponent("darkbloom")
        try #require(fm.createFile(atPath: file.path, contents: nil))
        let writer = try FileHandle(forWritingTo: file)
        try writer.truncate(atOffset: Self.fileBytes)
        try writer.close()

        let before = try #require(Self.footprint())
        let digest = try UpdateAtomicFilesystem.sha256(file: file)
        let tree = try UpdateAtomicFilesystem.treeHash(root: root)
        let after = try #require(Self.footprint())

        // SHA-256 of the zero bytes, and of "F darkbloom\n", the bytes, "\n".
        #expect(digest == "a6d72ac7690f53be6ae46ba88506bd97302a093f7108472bd9efc3cefda06484")
        #expect(tree == "20335c32fd646d6caa1c158d99ece27f150afb3057ea9ababcd885a44b5950f8")
        let growth = after > before ? after - before : 0
        #expect(growth < Self.allowedGrowth, "hashing 2 x 256 MiB left \(growth) bytes resident")
    }

    private static func footprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }
}
