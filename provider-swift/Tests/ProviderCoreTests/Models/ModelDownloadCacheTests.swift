import Foundation
import Testing
@testable import ProviderCore

@Suite("Model download cache preparation")
struct ModelDownloadCacheTests {
    @Test("existing directories and valid directory links retain staged downloads", arguments: [false, true])
    func preservesExistingDirectory(linked: Bool) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("model-cache-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let target = root.appendingPathComponent("target", isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let partial = target.appendingPathComponent("snapshots/.local-staging-build/model.safetensors.part")
        try fm.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("keep partial weights".utf8).write(to: partial)
        let model = linked ? root.appendingPathComponent("models--test", isDirectory: true) : target
        if linked { try fm.createSymbolicLink(atPath: model.path, withDestinationPath: "target") }

        try ModelDownloader.prepareModelCacheDirectory(at: model)

        #expect(try Data(contentsOf: partial) == Data("keep partial weights".utf8))
        if linked { #expect(try fm.destinationOfSymbolicLink(atPath: model.path) == "target") }
        #expect(try fm.contentsOfDirectory(atPath: root.path).filter { $0.contains("unavailable-link") }.isEmpty)
    }

    @Test("relative dangling links are backed up unchanged")
    func preservesRelativeDanglingLink() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("model-cache-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let model = root.appendingPathComponent("models--test", isDirectory: true)
        try fm.createSymbolicLink(atPath: model.path, withDestinationPath: "offline/model")

        try ModelDownloader.prepareModelCacheDirectory(at: model)
        // A second attempt reuses the replacement, without making more backups.
        try ModelDownloader.prepareModelCacheDirectory(at: model)

        var isDirectory: ObjCBool = false
        #expect(fm.fileExists(atPath: model.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        let backups = try fm.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".models--test.unavailable-link-") }
        #expect(backups.count == 1)
        let backup = try #require(backups.first)
        #expect(try fm.destinationOfSymbolicLink(atPath: root.appendingPathComponent(backup).path) == "offline/model")
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("offline").path))
    }

    @Test("regular files and links to files are rejected without modification", arguments: [false, true])
    func preservesConflictingFiles(linked: Bool) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("model-cache-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("file")
        try Data("keep me".utf8).write(to: file)
        let model = linked ? root.appendingPathComponent("models--test", isDirectory: true) : file
        if linked { try fm.createSymbolicLink(atPath: model.path, withDestinationPath: "file") }

        do {
            try ModelDownloader.prepareModelCacheDirectory(at: model)
            Issue.record("expected a conflicting-file error")
        } catch let error as ModelCatalogError {
            #expect(error.description.contains("not a directory"))
            #expect(error.description.contains(model.path))
        }

        #expect(try Data(contentsOf: file) == Data("keep me".utf8))
        if linked { #expect(try fm.destinationOfSymbolicLink(atPath: model.path) == "file") }
        #expect(try fm.contentsOfDirectory(atPath: root.path).filter { $0.contains("unavailable-link") }.isEmpty)
    }

    @Test("an unavailable cache root is never replaced")
    func preservesUnavailableCacheRoot() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("model-cache-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let hub = root.appendingPathComponent("hub", isDirectory: true)
        try fm.createSymbolicLink(atPath: hub.path, withDestinationPath: "offline/hub")
        let model = hub.appendingPathComponent("models--test", isDirectory: true)

        #expect(throws: ModelCatalogError.self) {
            try ModelDownloader.prepareModelCacheDirectory(at: model)
        }

        #expect(try fm.destinationOfSymbolicLink(atPath: hub.path) == "offline/hub")
        #expect(try fm.contentsOfDirectory(atPath: root.path) == ["hub"])
    }

    @Test("link resolution errors other than missing targets preserve the link",
          arguments: ["models--test", "file/child"])
    func preservesUnresolvableLinks(target: String) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("model-cache-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("keep me".utf8).write(to: root.appendingPathComponent("file"))
        let model = root.appendingPathComponent("models--test", isDirectory: true)
        // A self-loop reports ELOOP; traversing a file reports ENOTDIR.
        try fm.createSymbolicLink(atPath: model.path, withDestinationPath: target)

        #expect(throws: ModelCatalogError.self) {
            try ModelDownloader.prepareModelCacheDirectory(at: model)
        }

        #expect(try fm.destinationOfSymbolicLink(atPath: model.path) == target)
        #expect(try fm.contentsOfDirectory(atPath: root.path).sorted() == ["file", "models--test"])
    }
}
