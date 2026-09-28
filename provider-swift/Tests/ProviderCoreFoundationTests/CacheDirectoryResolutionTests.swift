#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import Testing

@testable import ProviderCoreFoundation

/// Cache precedence and filesystem traversal boundaries. Fixtures never depend
/// on the process cache configuration or mutate the process working directory.
@Suite("HuggingFace cache directory resolution")
struct CacheDirectoryResolutionTests {

    /// Fixture roots for one test instance; removed when the suite value dies.
    private final class FixtureRoots: @unchecked Sendable {
        var urls: [URL] = []
        deinit {
            for url in urls { try? FileManager.default.removeItem(at: url) }
        }
    }

    private let roots = FixtureRoots()

    /// A real directory under a *resolved* temp root, so the expectation side
    /// needs no symlink resolution of its own and comparisons stay exact.
    private func makeDir(_ name: String) throws -> URL {
        let temporaryPath = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(temporaryPath) }
        let url = URL(fileURLWithPath: String(cString: temporaryPath), isDirectory: true)
            .appendingPathComponent("hf-cache-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.urls.append(url)
        return url
    }

    private func fakeHome() throws -> URL { try makeDir("home") }

    // MARK: - Runtime selection and explicit imports

    @Test("runtime uses saved configuration or the home default")
    func runtimeSelection() throws {
        let home = try fakeHome()
        let saved = try makeDir("configured")
        let configured = ModelScanner.resolveCache(homeDirectory: home, configuredDirectory: saved.path)
        #expect(configured.url.path == saved.path)
        #expect(configured.environmentKey == nil)
        #expect(configured.isConfigured)

        let fallback = ModelScanner.resolveCache(homeDirectory: home)
        #expect(fallback.url.path == home.appendingPathComponent(".cache/huggingface/hub").path)
        #expect(fallback.environmentKey == nil)
        #expect(!fallback.isConfigured)
    }

    @Test("explicit environment import selects the highest-priority valid variable")
    func environmentImportPrecedence() throws {
        let home = try fakeHome()
        let sources = [
            ("HF_HUB_CACHE", ""),
            ("HUGGINGFACE_HUB_CACHE", ""),
            ("HF_HOME", "/hub"),
            ("XDG_CACHE_HOME", "/huggingface/hub"),
        ]
        let bases = try sources.map { try makeDir($0.0) }
        var environment = Dictionary(uniqueKeysWithValues: zip(sources, bases).map { ($0.0.0, $0.1.path) })

        for (source, base) in zip(sources, bases) {
            let result = try #require(ModelScanner.resolveEnvironmentCache(
                environment: environment, homeDirectory: home))
            #expect(result.url.path == base.path + source.1)
            #expect(result.environmentKey == source.0)
            #expect(!result.isConfigured)
            environment.removeValue(forKey: source.0)
        }

        #expect(ModelScanner.resolveEnvironmentCache(environment: environment, homeDirectory: home) == nil)
    }

    // MARK: - Invalid and significant path values

    @Test("invalid path values fall through without redirecting to a truncated path",
        arguments: ["", " \t\n", "\0", "hub\0else"])
    func invalidValuesIgnored(raw: String) throws {
        let home = try fakeHome()
        let nextBase = try makeDir("valid-env")
        let next = try #require(ModelScanner.resolveEnvironmentCache(
            environment: ["HF_HUB_CACHE": raw, "HF_HOME": nextBase.path], homeDirectory: home))
        #expect(next.url.path == nextBase.path + "/hub")
        #expect(next.environmentKey == "HF_HOME")

        let environment = Dictionary(uniqueKeysWithValues:
            ["HF_HUB_CACHE", "HUGGINGFACE_HUB_CACHE", "HF_HOME", "XDG_CACHE_HOME"].map { ($0, raw) })
        #expect(ModelScanner.resolveEnvironmentCache(environment: environment, homeDirectory: home) == nil)

        let fallback = ModelScanner.resolveCache(homeDirectory: home, configuredDirectory: raw)
        #expect(fallback.url.path == home.path + "/.cache/huggingface/hub")
        #expect(fallback.environmentKey == nil)
        #expect(!fallback.isConfigured)
        #expect(ModelScanner.normalizedCacheDirectory(raw, homeDirectory: home) == nil)
    }

    /// A directory name may legitimately end in a space (or a non-breaking
    /// space) on APFS, so the path itself must be used verbatim -- trimming it
    /// would silently point at a different, likely nonexistent, directory.
    /// huggingface_hub does not trim either.
    @Test("a path whose name ends in whitespace is used verbatim")
    func whitespaceInPathPreserved() throws {
        let parent = try makeDir("wsparent")
        let spaced = parent.appendingPathComponent("hub ", isDirectory: true)
        try FileManager.default.createDirectory(at: spaced, withIntermediateDirectories: true)

        let resolved = ModelScanner.resolveCache(
            homeDirectory: try fakeHome(), configuredDirectory: spaced.path)

        #expect(resolved.url.path == spaced.path)
        #expect(resolved.url.lastPathComponent == "hub ")
    }

    @Test("a non-breaking space in a path is not stripped")
    func nonBreakingSpacePreserved() throws {
        let parent = try makeDir("nbsp")
        let odd = parent.appendingPathComponent("\u{00A0}hf\u{00A0}", isDirectory: true)
        try FileManager.default.createDirectory(at: odd, withIntermediateDirectories: true)

        let resolved = ModelScanner.resolveCache(
            homeDirectory: try fakeHome(), configuredDirectory: odd.path)

        #expect(resolved.url.path == odd.path)
    }

    @Test("a leading tilde expands against the home directory")
    func tildeExpanded() throws {
        let home = try fakeHome()

        let resolved = ModelScanner.resolveEnvironmentCache(
            environment: ["HF_HOME": "~/models/hf"],
            homeDirectory: home
        )

        #expect(resolved?.url.path == home.appendingPathComponent("models/hf/hub").path)
    }

    // MARK: - Symlink resolution

    @Test("symlinks are followed before .., including when the leaf is missing", arguments: [false, true])
    func symlinkBeforeParentTraversal(leafExists: Bool) throws {
        let root = try makeDir("traversal")
        let child = root.appendingPathComponent("real/child", isDirectory: true)
        let expected = root.appendingPathComponent("real/cache", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        if leafExists {
            try FileManager.default.createDirectory(at: expected, withIntermediateDirectories: true)
        }
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: child)
        // Lexically collapsing link/.. would incorrectly choose root/cache.
        let raw = link.path + "/../cache"
        let result = try #require(ModelScanner.resolveEnvironmentCache(
            environment: ["HF_HUB_CACHE": raw], homeDirectory: root))
        #expect(result.url.path == expected.path)
        #expect(FileManager.default.fileExists(atPath: expected.path) == leafExists)

        let saved = ModelScanner.resolveCache(homeDirectory: root, configuredDirectory: raw)
        #expect(saved.url.path == expected.path)
        #expect(saved.isConfigured)
    }

    @Test("missing suffixes under a symlinked parent use its real directory")
    func missingSuffixUnderSymlink() throws {
        let root = try makeDir("missing-symlink")
        let target = root.appendingPathComponent("café-模型", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.lastPathComponent)

        let result = ModelScanner.resolveCache(
            homeDirectory: root, configuredDirectory: link.path + "/cache/new")
        #expect(result.url.path == target.path + "/cache/new")
        #expect(!FileManager.default.fileExists(atPath: target.path + "/cache"))
    }

    @Test("relative and tilde paths preserve symlink parent traversal")
    func relativeAndTildeSymlinkTraversal() throws {
        let root = try makeDir("relative-link")
        let target = root.appendingPathComponent("real/child", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: target)

        for raw in ["link/../cache", "~/link/../cache"] {
            let result = ModelScanner.normalizedCacheDirectory(raw, homeDirectory: root, relativeTo: root)
            #expect(result?.path == root.path + "/real/cache")
            let absolute = ModelScanner.absoluteCachePathValue(raw, relativeTo: root, homeDirectory: root)
            #expect(absolute == root.path + "/link/../cache")
        }
        #expect(ModelScanner.normalizedCacheDirectory("~", homeDirectory: root)?.path == root.path)
    }

    @Test("missing, nondirectory and looping components cannot be erased by ..",
        arguments: ["missing", "file", "loop"])
    func invalidTraversalIsNotSimplified(component: String) throws {
        let root = try makeDir("invalid-traversal")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("cache"), withIntermediateDirectories: true)
        try "file".write(to: root.appendingPathComponent("file"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: root.path + "/loop", withDestinationPath: "loop")
        let raw = root.path + "/" + component + "/../cache"
        var metadata = stat()
        let status = stat(raw, &metadata)
        let error = errno
        #expect(status == -1)
        #expect(error == (component == "file" ? ENOTDIR : component == "loop" ? ELOOP : ENOENT))
        let result = ModelScanner.resolveCache(homeDirectory: root, configuredDirectory: raw)
        #expect(result.url.path == raw)
        #expect(result.isConfigured)
    }

    @Test("a missing component below a symlink cannot redirect into an unrelated cache")
    func nestedMissingTraversalIsNotSimplified() throws {
        let root = try makeDir("nested-missing-traversal")
        let target = root.appendingPathComponent("real/child", isDirectory: true)
        let unrelated = root.appendingPathComponent("real/cache", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let suffix = "/missing/../../cache"
        let raw = link.path + suffix
        var metadata = stat()
        let status = stat(raw, &metadata)
        let error = errno
        #expect(status == -1)
        #expect(error == ENOENT)
        let result = ModelScanner.resolveCache(homeDirectory: root, configuredDirectory: raw)
        #expect(result.url.path == target.path + suffix)
        let resolvedStatus = stat(result.url.path, &metadata)
        let resolvedError = errno
        #expect(resolvedStatus == -1)
        #expect(resolvedError == ENOENT)
    }

    @Test("a symlinked HF_HOME resolves to its real path")
    func hfHomeSymlinkResolved() throws {
        let real = try makeDir("real")
        let hub = real.appendingPathComponent("hub", isDirectory: true)
        try FileManager.default.createDirectory(at: hub, withIntermediateDirectories: true)

        let linkParent = try makeDir("linkparent")
        let link = linkParent.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let resolved = ModelScanner.resolveEnvironmentCache(
            environment: ["HF_HOME": link.path],
            homeDirectory: try fakeHome()
        )

        #expect(resolved?.url.path == hub.path)
    }

    @Test("a symlinked HF_HUB_CACHE resolves to its real path")
    func hfHubCacheSymlinkResolved() throws {
        let real = try makeDir("realhub")
        let linkParent = try makeDir("linkparent2")
        let link = linkParent.appendingPathComponent("hub-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let resolved = ModelScanner.resolveEnvironmentCache(
            environment: ["HF_HUB_CACHE": link.path],
            homeDirectory: try fakeHome()
        )

        #expect(resolved?.url.path == real.path)
    }

    @Test("a symlinked home resolves even before its cache exists", arguments: [false, true])
    func homeFallbackSymlinkResolved(cacheExists: Bool) throws {
        let realHome = try makeDir("realhome")
        let cache = realHome.appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
        if cacheExists {
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        }

        let linkParent = try makeDir("linkparent3")
        let homeLink = linkParent.appendingPathComponent("home-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: homeLink, withDestinationURL: realHome)

        let resolved = ModelScanner.cacheDirectory(homeDirectory: homeLink)

        #expect(resolved.path == cache.path)
    }

    @Test("an explicit import keeps a nonexistent candidate without creating directories")
    func nonexistentPathResolves() throws {
        let home = try fakeHome()
        let missing = home.appendingPathComponent("not-created-yet")
        let resolved = try #require(ModelScanner.resolveEnvironmentCache(
            environment: ["HF_HOME": missing.path, "XDG_CACHE_HOME": home.path],
            homeDirectory: home))

        #expect(resolved.url.path == missing.path + "/hub")
        #expect(resolved.environmentKey == "HF_HOME")
        #expect(!resolved.isConfigured)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    // MARK: - Hostile / malformed values

    /// `~user` must not silently become a CWD-relative literal directory named
    /// "~user".
    @Test("a ~user path expands against the user's home directory")
    func tildeUserDoesNotBecomeRelative() throws {
        let username = NSUserName()
        let expected = ("~\(username)" as NSString).expandingTildeInPath + "/link/../models"
        let path = ModelScanner.absoluteCachePathValue("~\(username)/link/../models", homeDirectory: try fakeHome())
        #expect(path == expected)
    }

    /// An unknown user cannot be expanded; falling through to the next source
    /// beats building a garbage relative path.
    @Test("an unexpandable ~user falls through to the next source")
    func unexpandableTildeUserFallsThrough() throws {
        let home = try fakeHome()
        let raw = "~nosuchuser-\(UUID().uuidString)/x"

        #expect(ModelScanner.resolveEnvironmentCache(
            environment: ["HF_HOME": raw], homeDirectory: home) == nil)
        let next = ModelScanner.resolveEnvironmentCache(
            environment: ["HF_HUB_CACHE": raw, "HF_HOME": home.path], homeDirectory: home)
        #expect(next?.url.path == home.path + "/hub")
        #expect(next?.environmentKey == "HF_HOME")
        #expect(ModelScanner.normalizedCacheDirectory(raw, homeDirectory: home) == nil)
        let fallback = ModelScanner.resolveCache(homeDirectory: home, configuredDirectory: raw)
        #expect(fallback.url.path == home.path + "/.cache/huggingface/hub")
        #expect(!fallback.isConfigured)
    }

    @Test("paths at component and total byte limits are never silently truncated",
        arguments: [255, 256, 1023, 1024, 1025, 5000])
    func overLongPathNotTruncated(length: Int) throws {
        let raw = "/" + String(repeating: "a", count: length - 1)
        let resolved = ModelScanner.resolveCache(
            homeDirectory: try fakeHome(), configuredDirectory: raw)
        #expect(resolved.url.path == raw)
        #expect(resolved.isConfigured)
    }

    @Test("path limits count UTF-8 bytes, without splitting non-ASCII characters")
    func multibytePathNotTruncated() throws {
        let raw = "/" + String(repeating: "é", count: 600)
        let resolved = ModelScanner.resolveCache(
            homeDirectory: try fakeHome(), configuredDirectory: raw)
        #expect(resolved.url.path == raw)
    }

    // MARK: - Relative paths and model lookup

    @Test("a relative cache path is made absolute against its supplied base")
    func relativePathMadeAbsolute() throws {
        let base = try makeDir("cwd")

        let out = ModelScanner.normalizedCacheDirectory("models/hf", relativeTo: base)

        #expect(out?.path == base.appendingPathComponent("models/hf").path)
    }

    /// A round trip: place a snapshot at the downloader's destination and
    /// confirm discovery finds it. Locks the two sides against drifting apart.
    @Test("models written to the default or saved cache are discoverable", arguments: [false, true])
    func downloadDestinationIsDiscoverable(useSavedCache: Bool) throws {
        let saved = useSavedCache ? try makeDir("saved-roundtrip").path : nil
        let home = try fakeHome()

        let modelDir = ModelScanner.cacheModelDirectory(
            for: "acme/Round-Trip", homeDirectory: home, configuredDirectory: saved
        )
        let snapshot = modelDir.appendingPathComponent("snapshots/local", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try "{}".write(to: snapshot.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

        let found = ModelScanner.resolveLocalPath(
            modelID: "acme/Round-Trip",
            environment: [:],
            homeDirectory: home,
            configuredDirectory: saved
        )

        #expect(found?.path == snapshot.path)
    }

    // MARK: - Cache directory health

    /// A path that is a regular FILE must not read as a usable cache -- doctor
    /// reported PASS for it before, while the scanner found nothing.
    @Test("cache usability rejects files and missing paths")
    func cacheDirectoryRejectsFile() throws {
        let parent = try makeDir("filecache")
        let file = parent.appendingPathComponent("hub")
        try "not a directory".write(to: file, atomically: true, encoding: .utf8)

        #expect(ModelScanner.isUsableCacheDirectory(file) == false)
        #expect(ModelScanner.isUsableCacheDirectory(parent) == true)
        #expect(ModelScanner.isUsableCacheDirectory(
            parent.appendingPathComponent("missing", isDirectory: true)) == false)
    }

    // MARK: - Snapshot layout

    /// A model ID's slash becomes `--`, not another directory level.
    @Test("model lookup rejects a nested org/name cache directory")
    func nestedModelDirectoryIsNotDiscovered() throws {
        let hfHome = try makeDir("hfhome-orgless")
        // A directory laid out with an unflattened slash is not a model cache.
        let nested = hfHome.appendingPathComponent(
            "hub/models--acme/Slashed/snapshots/x", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let found = ModelScanner.resolveLocalPath(
            modelID: "acme/Slashed",
            environment: [:],
            homeDirectory: try fakeHome(),
            configuredDirectory: hfHome.appendingPathComponent("hub").path
        )

        #expect(found == nil)
    }

}
