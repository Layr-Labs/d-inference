import Foundation
import Testing
@testable import ProviderCore

private final class MetallibBinderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [String] = []
    private var recordedLoaderPaths: [String] = []

    func event(_ value: String) {
        lock.lock()
        recordedEvents.append(value)
        lock.unlock()
    }

    func loaderPath(_ value: String) {
        lock.lock()
        recordedLoaderPaths.append(value)
        lock.unlock()
    }

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }

    var loaderPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedLoaderPaths
    }
}

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

    @Test("explicit test-bundle URL binds and hashes the anonymous snapshot")
    func explicitTestBundleURLBinding() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("explicit-bundle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let macOSDirectory = root
            .appendingPathComponent("ProviderCorePackageTests.xctest", isDirectory: true)
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(
            at: macOSDirectory, withIntermediateDirectories: true)
        let explicitURL = macOSDirectory.appendingPathComponent("mlx.metallib")
        try Data("explicit-test-bundle-metallib".utf8).write(to: explicitURL)
        let recorder = MetallibBinderRecorder()
        let binder = RuntimeMetallibBinder(
            locateDefault: {
                recorder.event("default-locator")
                return nil
            },
            setLoaderPath: { recorder.loaderPath($0) }
        )

        let digest = try #require(binder.bind(from: explicitURL))
        let loaderPath = try #require(recorder.loaderPaths.first)
        #expect(recorder.events.isEmpty)
        #expect(recorder.loaderPaths.count == 1)
        #expect(digest == hashFile(atPath: explicitURL.path))
        #expect(hashFile(atPath: loaderPath) == digest)
        #expect(binder.bindingInfo() == RuntimeMetallibBindingInfo(
            sourceURL: explicitURL.standardizedFileURL.resolvingSymlinksInPath(),
            loaderPath: loaderPath,
            digest: digest
        ))

        #expect(binder.bind(from: explicitURL) == digest)
        #expect(recorder.loaderPaths.count == 1)
    }

    @Test("nil bind resolves the production locator")
    func nilBindingUsesProductionLocator() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("default-bind-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let productionURL = root.appendingPathComponent("mlx.metallib")
        try Data("production-colocated-metallib".utf8).write(to: productionURL)
        let recorder = MetallibBinderRecorder()
        let binder = RuntimeMetallibBinder(
            locateDefault: {
                recorder.event("default-locator")
                return productionURL
            },
            setLoaderPath: { recorder.loaderPath($0) }
        )

        let digest = try #require(binder.bind(from: nil))
        #expect(recorder.events == ["default-locator"])
        #expect(digest == hashFile(atPath: productionURL.path))
        #expect(hashFile(atPath: try #require(recorder.loaderPaths.first)) == digest)
    }

    @Test("bound source rejects a different path or changed digest")
    func conflictingBindingFailsClosed() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("conflicting-bind-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let firstURL = root.appendingPathComponent("first.metallib")
        let secondURL = root.appendingPathComponent("second.metallib")
        try Data("first-approved-bytes".utf8).write(to: firstURL)
        try Data("second-approved-bytes".utf8).write(to: secondURL)
        let recorder = MetallibBinderRecorder()
        let binder = RuntimeMetallibBinder(
            locateDefault: { nil },
            setLoaderPath: { recorder.loaderPath($0) }
        )

        let firstDigest = try #require(binder.bind(from: firstURL))
        let retainedLoaderPath = try #require(recorder.loaderPaths.first)
        #expect(binder.bind(from: secondURL) == nil)

        try Data("mutated-after-bind".utf8).write(to: firstURL)
        #expect(binder.bind(from: firstURL) == nil)
        #expect(recorder.loaderPaths.count == 1)
        #expect(binder.bindingInfo()?.digest == firstDigest)
        #expect(hashFile(atPath: retainedLoaderPath) == firstDigest)
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
