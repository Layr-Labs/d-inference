import Darwin
import Foundation
import Testing

@testable import ProviderCore

@Suite("Atomic file")
struct AtomicFileTests {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("atomic-file-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func mode(_ url: URL) -> mode_t {
        var info = stat()
        _ = lstat(url.path, &info)
        return info.st_mode & 0o7777
    }

    @Test("the file gets exactly the mode asked for, its folder is created, and no sibling is left")
    func writesWithMode() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("nested/config.json")
        try AtomicFile.write(Data("one".utf8), to: target, mode: 0o640)
        #expect(try String(contentsOf: target, encoding: .utf8) == "one")
        #expect(mode(target) == 0o640)
        // Group write is outside the usual umask (022): only an exact chmod gives it.
        try AtomicFile.write(Data("two".utf8), to: target, mode: 0o660)
        #expect(try String(contentsOf: target, encoding: .utf8) == "two")
        #expect(mode(target) == 0o660)
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path)
            == ["config.json"])
    }

    @Test("a failure just before the rename removes the new bytes and leaves the old file as it was")
    func failureBeforeReplace() throws {
        struct Interrupted: Error {}
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("config.yaml")
        try AtomicFile.write(Data("old".utf8), to: target, mode: 0o600)
        var sawSibling = false
        #expect(throws: Interrupted.self) {
            try AtomicFile.write(Data("new".utf8), to: target, mode: 0o600) {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
                sawSibling = names.contains { $0.hasPrefix(".config.yaml.darkbloom-") }
                throw Interrupted()
            }
        }
        #expect(sawSibling)
        #expect(try String(contentsOf: target, encoding: .utf8) == "old")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["config.yaml"])
    }
}
