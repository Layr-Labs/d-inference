import Foundation
import Testing

@Suite("SSD test working-directory selection", .serialized)
struct SSDTestDirectoryTests {
    @Test func absentOverrideRetainsFoundationDefault() throws {
        #expect(try SSDTestDirectory.parent(environment: [:])
            == FileManager.default.temporaryDirectory.resolvingSymlinksInPath())
    }

    @Test func explicitParentPreservesSpacesAndRejectsInvalidPaths() throws {
        let parent = try SSDTestDirectory.parent()
        let root = parent.appendingPathComponent("ssd-parent-\(UUID().uuidString) spaces", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Failed to remove owned test-parent fixture: \(error)") }
        }
        #expect(try SSDTestDirectory.parent(environment: [SSDTestDirectory.environmentKey: root.path]) == root)
        let file = root.appendingPathComponent("not-a-directory")
        try Data([0x31]).write(to: file)
        let link = root.appendingPathComponent("linked-parent")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        for invalid in ["", "relative-parent", root.appendingPathComponent("missing").path,
                        file.path, link.path, root.path + "\0suffix"] {
            #expect(throws: SSDTestDirectory.SelectionError.self) {
                try SSDTestDirectory.parent(environment: [SSDTestDirectory.environmentKey: invalid])
            }
        }
        #expect(FileManager.default.fileExists(atPath: parent.path))
    }
}
