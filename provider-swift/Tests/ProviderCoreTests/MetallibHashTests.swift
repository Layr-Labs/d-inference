import Foundation
import Testing
@testable import ProviderCore

@Suite("metallib hash + runtime-loader locator", .serialized)
struct MetallibHashTests {
    @Test("env override cannot replace the colocated runtime metallib")
    func conflictingEnvironmentAndColocatedFiles() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mlx-loader-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let executable = root.appendingPathComponent("darkbloom")
        let colocated = root.appendingPathComponent("mlx.metallib")
        let environmentOnly = root.appendingPathComponent("approved-env.metallib")
        try Data("executable".utf8).write(to: executable)
        try Data("runtime-colocated".utf8).write(to: colocated)
        try Data("different-approved-env".utf8).write(to: environmentOnly)

        MLXMetallibEnvironment.withPath(environmentOnly.path) {
            let exists: (URL) -> Bool = {
                FileManager.default.fileExists(atPath: $0.path)
            }
            #expect(locateRuntimeMetallib(
                executableURL: executable,
                fileExists: exists
            )?.path == colocated.path)
            #expect(runtimeMetallibHash(
                executableURL: executable,
                fileExists: exists
            ) == hashFile(atPath: colocated.path))
            #expect(runtimeMetallibHash(
                executableURL: executable,
                fileExists: exists
            ) != hashFile(atPath: environmentOnly.path))
        }
    }

    @Test("runtime locator mirrors colocated then Resources precedence")
    func runtimeLoaderPrecedence() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mlx-precedence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("darkbloom")
        let resourceMetallib = resources.appendingPathComponent("mlx.metallib")
        try Data("executable".utf8).write(to: executable)
        try Data("resource".utf8).write(to: resourceMetallib)
        let exists: (URL) -> Bool = {
            FileManager.default.fileExists(atPath: $0.path)
        }

        #expect(locateRuntimeMetallib(
            executableURL: executable,
            fileExists: exists
        )?.path == resourceMetallib.path)

        let colocated = root.appendingPathComponent("mlx.metallib")
        try Data("colocated".utf8).write(to: colocated)
        #expect(locateRuntimeMetallib(
            executableURL: executable,
            fileExists: exists
        )?.path == colocated.path)
    }

    @Test("anonymous runtime snapshot survives post-registration path swap")
    func boundSnapshotSurvivesSourceSwap() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mlx-snapshot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("mlx.metallib")
        try Data("approved-runtime-bytes".utf8).write(to: source)
        var namedWriterOpened = false
        let snapshot = try makeRuntimeMetallibSnapshot(
            sourceURL: source,
            onAnonymousReady: { temporaryPath in
                namedWriterOpened =
                    FileHandle(forWritingAtPath: temporaryPath) != nil
            }
        )
        #expect(!namedWriterOpened)
        let approvedDigest = snapshot.digest
        try Data("swapped-after-registration".utf8).write(to: source)

        #expect(hashFile(atPath: source.path) != approvedDigest)
        #expect(hashFile(atPath: snapshot.loaderPath) == approvedDigest)
    }

    @Test("runtime locator fails closed when loader-visible files are absent")
    func runtimeLocatorAbsent() {
        let executable = URL(fileURLWithPath: "/no/such/provider/darkbloom")
        #expect(locateRuntimeMetallib(
            executableURL: executable,
            fileExists: { _ in false }
        ) == nil)
        #expect(runtimeMetallibHash(
            executableURL: executable,
            fileExists: { _ in false }
        ) == nil)
    }
}
