#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import XCTest

@testable import ProviderCoreFoundation

/// Metadata-only fixtures. No process cache configuration or model payload is used.
final class ModelScannerSnapshotSymlinkTests: XCTestCase {
    private final class Fixture {
        let root: URL
        let home: URL
        let snapshots: URL
        let targets: URL
        let modelID = "example/snapshot-model"

        init() throws {
            let temporaryPath = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
            defer { free(temporaryPath) }
            root = URL(fileURLWithPath: String(cString: temporaryPath), isDirectory: true)
                .appendingPathComponent("snapshot-symlink-\(UUID().uuidString)", isDirectory: true)
            home = root.appendingPathComponent("home", isDirectory: true)
            snapshots = home.appendingPathComponent(
                ".cache/huggingface/hub/models--example--snapshot-model/snapshots", isDirectory: true)
            targets = root.appendingPathComponent("targets", isDirectory: true)
            try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: targets, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func directory(_ parent: URL, _ name: String) throws -> URL {
            let url = parent.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            return url
        }

        func link(_ name: String, to destination: URL) throws -> URL {
            let url = snapshots.appendingPathComponent(name)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: destination)
            return url
        }

        /// Set the entry itself, never the symlink's target, to a deterministic date.
        func setEntryTime(_ url: URL, seconds: Int) throws {
            let times = [timespec(tv_sec: seconds, tv_nsec: 0), timespec(tv_sec: seconds, tv_nsec: 0)]
            let result = times.withUnsafeBufferPointer { buffer in
                url.path.withCString { utimensat(AT_FDCWD, $0, buffer.baseAddress, AT_SYMLINK_NOFOLLOW) }
            }
            guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        }

        func resolve() -> URL? {
            ModelScanner.resolveLocalPath(
                modelID: modelID, environment: [:], homeDirectory: home, configuredDirectory: nil)
        }

        var refs: URL { snapshots.deletingLastPathComponent().appendingPathComponent("refs", isDirectory: true) }

        func selectedAndLegacy() throws -> (selected: URL, legacy: URL) {
            let selected = try directory(snapshots, ".revision-selected")
            let legacy = try directory(snapshots, "visible-legacy")
            try setEntryTime(selected, seconds: 1_700_001_000)
            try setEntryTime(legacy, seconds: 1_700_002_000)
            return (selected, legacy)
        }

        @discardableResult
        func writeRef(_ bytes: Data) throws -> URL {
            try FileManager.default.createDirectory(at: refs, withIntermediateDirectories: true)
            let ref = refs.appendingPathComponent("main")
            try bytes.write(to: ref)
            return ref
        }
    }

    func testLinkedSnapshotResolvesThroughNormalResolver() throws {
        let f = try Fixture()
        let target = try f.directory(f.targets, "real-revision")
        let link = try f.link("revision", to: target)
        let values = try link.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        XCTAssertEqual(values.isSymbolicLink, true)
        #if canImport(Darwin)
        // This is the Foundation distinction that caused the regression.
        XCTAssertEqual(values.isDirectory, false)
        #endif
        XCTAssertEqual(ModelScanner.findLatestSnapshot(in: f.snapshots)?.path, target.path)
        XCTAssertEqual(f.resolve()?.path, target.path)
    }

    func testOrdinaryDirectoryOrderingStillUsesModificationDate() throws {
        let f = try Fixture()
        let z = try f.directory(f.snapshots, "z-revision")
        let a = try f.directory(f.snapshots, "a-revision")
        try f.setEntryTime(z, seconds: 1_700_001_000)
        try f.setEntryTime(a, seconds: 1_700_002_000)
        XCTAssertEqual(f.resolve()?.path, a.path)
        try f.setEntryTime(z, seconds: 1_700_003_000)
        XCTAssertEqual(f.resolve()?.path, z.path)
    }

    func testMixedOrderingUsesLinkEntryDateNotTargetDate() throws {
        let f = try Fixture()
        let target = try f.directory(f.targets, "target-with-newer-date")
        let plain = try f.directory(f.snapshots, "plain")
        let link = try f.link("linked", to: target)
        try f.setEntryTime(target, seconds: 1_700_100_000)
        try f.setEntryTime(link, seconds: 1_700_001_000)
        try f.setEntryTime(plain, seconds: 1_700_002_000)
        XCTAssertEqual(f.resolve()?.path, plain.path)
        try f.setEntryTime(link, seconds: 1_700_003_000)
        XCTAssertEqual(f.resolve()?.path, target.path)
    }

    func testBrokenSnapshotLinksAreExcluded() throws {
        let f = try Fixture()
        _ = try f.link("broken", to: f.targets.appendingPathComponent("missing"))
        XCTAssertNil(f.resolve())
        let good = try f.directory(f.snapshots, "good")
        XCTAssertEqual(f.resolve()?.path, good.path)
    }

    func testFilesAndFileLinksAreExcluded() throws {
        let f = try Fixture()
        let file = f.targets.appendingPathComponent("file")
        try Data([0]).write(to: file, options: .withoutOverwriting)
        _ = try f.link("linked-file", to: file)
        try Data([0]).write(to: f.snapshots.appendingPathComponent("plain-file"), options: .withoutOverwriting)
        XCTAssertNil(f.resolve())
        let good = try f.directory(f.snapshots, "good")
        XCTAssertEqual(f.resolve()?.path, good.path)
    }

    func testFIFOLinksAreExcludedWithoutOpeningPayload() throws {
        let f = try Fixture()
        let fifo = f.targets.appendingPathComponent("pipe")
        guard mkfifo(fifo.path, mode_t(0o600)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        _ = try f.link("linked-fifo", to: fifo)
        XCTAssertNil(f.resolve())
        let good = try f.directory(f.snapshots, "good")
        XCTAssertEqual(f.resolve()?.path, good.path)
    }

    func testHiddenSnapshotsRemainExcluded() throws {
        let f = try Fixture()
        let target = try f.directory(f.targets, "target")
        _ = try f.link(".hidden-link", to: target)
        _ = try f.directory(f.snapshots, ".hidden-directory")
        XCTAssertNil(f.resolve())
        let good = try f.directory(f.snapshots, "good")
        XCTAssertEqual(f.resolve()?.path, good.path)
    }

    func testSymlinkCyclesAreExcluded() throws {
        let f = try Fixture()
        _ = try f.link("cycle-a", to: f.snapshots.appendingPathComponent("cycle-b"))
        _ = try f.link("cycle-b", to: f.snapshots.appendingPathComponent("cycle-a"))
        XCTAssertNil(f.resolve())
        let good = try f.directory(f.snapshots, "good")
        XCTAssertEqual(f.resolve()?.path, good.path)
    }

    func testExplicitRefSelectsHiddenRevisionInsteadOfNewerVisibleLegacy() throws {
        let f = try Fixture()
        let revisions = try f.selectedAndLegacy()
        XCTAssertEqual(f.resolve()?.path, revisions.legacy.path)
        try f.writeRef(Data((revisions.selected.lastPathComponent + "\n").utf8))
        XCTAssertEqual(f.resolve()?.path, revisions.selected.path)
        try f.writeRef(Data(revisions.legacy.lastPathComponent.utf8))
        XCTAssertEqual(f.resolve()?.path, revisions.legacy.path)
    }

    func testAbsentMainRefPreservesLegacyFallbackWithMissingOrEmptyRefsDirectory() throws {
        let f = try Fixture()
        let revisions = try f.selectedAndLegacy()
        XCTAssertEqual(f.resolve()?.path, revisions.legacy.path)
        try FileManager.default.createDirectory(at: f.refs, withIntermediateDirectories: false)
        XCTAssertEqual(f.resolve()?.path, revisions.legacy.path)
    }

    func testMalformedAndNonUTF8RefsDoNotFallBackToVisibleLegacy() throws {
        let f = try Fixture()
        let revisions = try f.selectedAndLegacy()
        try f.writeRef(Data(revisions.selected.lastPathComponent.utf8))
        XCTAssertEqual(f.resolve()?.path, revisions.selected.path)
        let malformed = [Data([0xff]), Data(), Data(" \n".utf8), Data(".".utf8),
            Data("..".utf8), Data("../visible-legacy".utf8), Data("\\visible-legacy".utf8),
            Data("missing-revision".utf8), Data("visible-legacy\0ignored".utf8)]
        for bytes in malformed {
            try f.writeRef(bytes)
            XCTAssertNil(ModelScanner.findLatestSnapshot(in: f.snapshots))
            XCTAssertNil(f.resolve())
        }
    }

    func testValidRefsDirectoryReferenceAndSnapshotSymlinksRemainSupported() throws {
        let f = try Fixture()
        let target = try f.directory(f.targets, "canonical-revision")
        let selected = try f.link(".revision-selected", to: target)
        let legacy = try f.directory(f.snapshots, "visible-legacy")
        try f.setEntryTime(selected, seconds: 1_700_001_000)
        try f.setEntryTime(legacy, seconds: 1_700_002_000)
        let references = try f.directory(f.targets, "reference-directory")
        try FileManager.default.createSymbolicLink(at: f.refs, withDestinationURL: references)
        let pointer = f.targets.appendingPathComponent("selection")
        try Data((selected.lastPathComponent + "\n").utf8).write(to: pointer)
        try FileManager.default.createSymbolicLink(
            at: references.appendingPathComponent("main"), withDestinationURL: pointer)
        XCTAssertEqual(ModelScanner.findLatestSnapshot(in: f.snapshots)?.path, target.path)
        XCTAssertEqual(f.resolve()?.path, target.path)
    }

    func testBrokenCyclicAndDirectoryMainRefsDoNotFallBack() throws {
        let f = try Fixture()
        _ = try f.selectedAndLegacy()
        try FileManager.default.createDirectory(at: f.refs, withIntermediateDirectories: false)
        let main = f.refs.appendingPathComponent("main")
        try FileManager.default.createSymbolicLink(at: main, withDestinationURL: f.targets.appendingPathComponent("missing"))
        XCTAssertNil(f.resolve())
        try FileManager.default.removeItem(at: main)
        let other = f.refs.appendingPathComponent("cycle")
        try FileManager.default.createSymbolicLink(at: main, withDestinationURL: other)
        try FileManager.default.createSymbolicLink(at: other, withDestinationURL: main)
        XCTAssertNil(f.resolve())
        try FileManager.default.removeItem(at: main)
        try FileManager.default.removeItem(at: other)
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: false)
        XCTAssertNil(f.resolve())
    }

    func testBrokenOrNonDirectoryRefsParentDoesNotRestoreLegacyFallback() throws {
        let f = try Fixture()
        _ = try f.selectedAndLegacy()
        try FileManager.default.createSymbolicLink(at: f.refs, withDestinationURL: f.targets.appendingPathComponent("missing"))
        XCTAssertNil(f.resolve())
        try FileManager.default.removeItem(at: f.refs)
        try Data("not a directory".utf8).write(to: f.refs)
        XCTAssertNil(f.resolve())
    }

    func testGenuinelyUnreadableMainRefDoesNotFallBack() throws {
        let f = try Fixture()
        let revisions = try f.selectedAndLegacy()
        let main = try f.writeRef(Data(revisions.selected.lastPathComponent.utf8))
        XCTAssertEqual(chmod(main.path, mode_t(0o000)), 0)
        defer { _ = chmod(main.path, mode_t(0o600)) }
        // Establish a real denied read; running as a privileged bypassing user
        // is a fixture failure, never a fabricated successful unreadability test.
        let descriptor = open(main.path, O_RDONLY | O_NONBLOCK)
        let observedError = errno
        guard descriptor < 0, observedError == EACCES || observedError == EPERM else {
            if descriptor >= 0 { close(descriptor) }
            XCTFail("unreadable-reference fixture requires an actual permission-denied read")
            return
        }
        XCTAssertNil(f.resolve())
    }

    func testOversizedAndFIFORefsAreRefusedWithoutPayloadParsing() throws {
        let f = try Fixture()
        let revisions = try f.selectedAndLegacy()
        let selectedName = Data(revisions.selected.lastPathComponent.utf8)
        var padded = Data(repeating: 32, count: 1_048_576 - selectedName.count)
        padded.append(selectedName)
        let main = try f.writeRef(padded)
        XCTAssertEqual(f.resolve()?.path, revisions.selected.path)
        padded.append(32)
        try f.writeRef(padded)
        guard f.resolve() == nil else {
            XCTFail("oversized ref metadata must not select a snapshot")
            return
        }
        try FileManager.default.removeItem(at: main)
        guard mkfifo(main.path, mode_t(0o600)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        XCTAssertNil(f.resolve())
    }
}
