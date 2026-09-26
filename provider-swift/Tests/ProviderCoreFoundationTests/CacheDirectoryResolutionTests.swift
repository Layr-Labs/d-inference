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

    // MARK: - Precedence

    @Test("environment overrides saved configuration, which overrides the home default")
    func precedenceLadder() throws {
        let home = try fakeHome()
        let saved = try makeDir("configured")
        let sources = [
            ("HF_HUB_CACHE", ""),
            ("HUGGINGFACE_HUB_CACHE", ""),
            ("HF_HOME", "/hub"),
            ("XDG_CACHE_HOME", "/huggingface/hub"),
        ]
        let bases = try sources.map { try makeDir($0.0) }
        var environment = Dictionary(uniqueKeysWithValues: zip(sources, bases).map { ($0.0.0, $0.1.path) })

        for (source, base) in zip(sources, bases) {
            let result = ModelScanner.resolveCache(
                environment: environment, homeDirectory: home, configuredDirectory: saved.path)
            #expect(result.url.path == base.path + source.1)
            #expect(result.environmentKey == source.0)
            #expect(!result.isConfigured)
            environment.removeValue(forKey: source.0)
        }

        let configured = ModelScanner.resolveCache(
            environment: [:], homeDirectory: home, configuredDirectory: saved.path)
        #expect(configured.url.path == saved.path)
        #expect(configured.environmentKey == nil)
        #expect(configured.isConfigured)

        let fallback = ModelScanner.resolveCache(environment: [:], homeDirectory: home)
        #expect(fallback.url.path == home.appendingPathComponent(".cache/huggingface/hub").path)
        #expect(fallback.environmentKey == nil)
        #expect(!fallback.isConfigured)
    }

    // MARK: - Degenerate env values

    @Test("invalid path values fall through without redirecting to a truncated path",
        arguments: ["", " \t\n", "\0", "hub\0else"])
    func invalidValuesIgnored(raw: String) throws {
        let home = try fakeHome()
        let saved = try makeDir("configured-invalid")
        let next = ModelScanner.resolveCache(
            environment: ["HF_HUB_CACHE": raw, "HF_HOME": saved.path], homeDirectory: home)
        #expect(next.url.path == saved.path + "/hub")
        #expect(next.environmentKey == "HF_HOME")

        let environment = Dictionary(uniqueKeysWithValues: ModelScanner.cacheEnvKeys.map { ($0, raw) })
        let configured = ModelScanner.resolveCache(
            environment: environment, homeDirectory: home, configuredDirectory: saved.path)
        #expect(configured.url.path == saved.path)
        #expect(configured.isConfigured)

        let fallback = ModelScanner.resolveCache(
            environment: environment, homeDirectory: home, configuredDirectory: raw)
        #expect(fallback.url.path == home.path + "/.cache/huggingface/hub")
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

        let resolved = ModelScanner.defaultCacheDirectory(
            environment: ["HF_HUB_CACHE": spaced.path],
            homeDirectory: try fakeHome()
        )

        #expect(resolved?.path == spaced.path)
        #expect(resolved?.lastPathComponent == "hub ")
    }

    @Test("a non-breaking space in a path is not stripped")
    func nonBreakingSpacePreserved() throws {
        let parent = try makeDir("nbsp")
        let odd = parent.appendingPathComponent("\u{00A0}hf\u{00A0}", isDirectory: true)
        try FileManager.default.createDirectory(at: odd, withIntermediateDirectories: true)

        let resolved = ModelScanner.defaultCacheDirectory(
            environment: ["HF_HUB_CACHE": odd.path],
            homeDirectory: try fakeHome()
        )

        #expect(resolved?.path == odd.path)
    }

    @Test("a leading tilde expands against the home directory")
    func tildeExpanded() throws {
        let home = try fakeHome()

        let resolved = ModelScanner.defaultCacheDirectory(
            environment: ["HF_HOME": "~/models/hf"],
            homeDirectory: home
        )

        #expect(resolved?.path == home.appendingPathComponent("models/hf/hub").path)
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
        let result = ModelScanner.resolveCache(environment: ["HF_HUB_CACHE": raw], homeDirectory: root)
        #expect(result.url.path == expected.path)
        #expect(FileManager.default.fileExists(atPath: expected.path) == leafExists)

        let saved = ModelScanner.resolveCache(environment: [:], homeDirectory: root, configuredDirectory: raw)
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
            environment: ["HF_HUB_CACHE": link.path + "/cache/new"], homeDirectory: root)
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
        let result = ModelScanner.resolveCache(environment: ["HF_HUB_CACHE": raw], homeDirectory: root)
        #expect(result.url.path == raw)
        #expect(result.environmentKey == "HF_HUB_CACHE")
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
        let result = ModelScanner.resolveCache(environment: ["HF_HUB_CACHE": raw], homeDirectory: root)
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

        let resolved = ModelScanner.defaultCacheDirectory(
            environment: ["HF_HOME": link.path],
            homeDirectory: try fakeHome()
        )

        #expect(resolved?.path == hub.path)
    }

    @Test("a symlinked HF_HUB_CACHE resolves to its real path")
    func hfHubCacheSymlinkResolved() throws {
        let real = try makeDir("realhub")
        let linkParent = try makeDir("linkparent2")
        let link = linkParent.appendingPathComponent("hub-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let resolved = ModelScanner.defaultCacheDirectory(
            environment: ["HF_HUB_CACHE": link.path],
            homeDirectory: try fakeHome()
        )

        #expect(resolved?.path == real.path)
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

        let resolved = ModelScanner.defaultCacheDirectory(
            environment: [:],
            homeDirectory: homeLink
        )

        #expect(resolved?.path == cache.path)
    }

    @Test("a nonexistent override stays selected and resolution creates no directories")
    func nonexistentPathResolves() throws {
        let home = try fakeHome()
        let missing = home.appendingPathComponent("not-created-yet")
        let resolved = ModelScanner.resolveCache(
            environment: ["HF_HOME": missing.path, "XDG_CACHE_HOME": home.path],
            homeDirectory: home, configuredDirectory: home.path)

        #expect(resolved.url.path == missing.path + "/hub")
        #expect(resolved.environmentKey == "HF_HOME")
        #expect(!resolved.isConfigured)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    // MARK: - Hostile / malformed values

    /// `~user` must not silently become a CWD-relative literal directory named
    /// "~user" -- that path differs between the operator's shell and the
    /// launchd daemon (cwd `/`).
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

        let resolved = ModelScanner.defaultCacheDirectory(
            environment: ["HF_HOME": raw],
            homeDirectory: home
        )

        #expect(resolved?.path == home.appendingPathComponent(".cache/huggingface/hub").path)
        #expect(ModelScanner.normalizedCacheDirectory(raw, homeDirectory: home) == nil)
        #expect(ModelScanner.resolveCache(
            environment: [:], homeDirectory: home, configuredDirectory: raw).isConfigured == false)
    }

    @Test("paths at component and total byte limits are never silently truncated",
        arguments: [255, 256, 1023, 1024, 1025, 5000])
    func overLongPathNotTruncated(length: Int) throws {
        let raw = "/" + String(repeating: "a", count: length - 1)
        let resolved = ModelScanner.resolveCache(
            environment: ["HF_HUB_CACHE": raw], homeDirectory: try fakeHome())
        #expect(resolved.url.path == raw)
        #expect(resolved.environmentKey == "HF_HUB_CACHE")
    }

    @Test("path limits count UTF-8 bytes, without splitting non-ASCII characters")
    func multibytePathNotTruncated() throws {
        let raw = "/" + String(repeating: "é", count: 600)
        let resolved = ModelScanner.resolveCache(
            environment: ["HF_HUB_CACHE": raw], homeDirectory: try fakeHome())
        #expect(resolved.url.path == raw)
    }

    // MARK: - Absolutising for the launchd daemon

    /// launchd starts jobs with cwd `/` while the installing shell has its own
    /// cwd, so a relative value must be made absolute before it is persisted
    /// into the plist -- otherwise CLI and daemon resolve different caches.
    @Test("a relative cache path is made absolute against the shell's cwd")
    func relativePathAbsolutisedForDaemon() throws {
        let base = try makeDir("cwd")

        let out = ModelScanner.absoluteCachePathValue("models/hf", relativeTo: base)

        #expect(out == base.appendingPathComponent("models/hf").path)
        #expect(out?.hasPrefix("/") == true)
    }

    /// A round trip: place a snapshot at the downloader's destination and
    /// confirm discovery finds it. Locks the two sides against drifting apart.
    @Test("a model written to cacheModelDirectory is found by resolveLocalPath")
    func downloadDestinationIsDiscoverable() throws {
        let hfHome = try makeDir("hfhome-roundtrip")
        let env = ["HF_HOME": hfHome.path]
        let home = try fakeHome()

        let modelDir = ModelScanner.cacheModelDirectory(
            for: "acme/Round-Trip", environment: env, homeDirectory: home
        )
        let snapshot = modelDir.appendingPathComponent("snapshots/local", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try "{}".write(to: snapshot.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

        let found = ModelScanner.resolveLocalPath(
            modelID: "acme/Round-Trip",
            environment: env,
            homeDirectory: home
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

    // MARK: - Snapshot resolution reads through the override

    /// The org-less fallback branch built `models--{id}` inline; for an id
    /// containing a slash that yields a NESTED path (`models--org/name`)
    /// rather than the flattened cache directory name.
    @Test("the org-less fallback branch never builds a nested path")
    func orgLessBranchFlattensSlash() throws {
        let hfHome = try makeDir("hfhome-orgless")
        // A directory laid out with an unflattened slash is not a model cache.
        let nested = hfHome.appendingPathComponent(
            "hub/models--acme/Slashed/snapshots/x", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let found = ModelScanner.resolveLocalPath(
            modelID: "acme/Slashed",
            environment: ["HF_HOME": hfHome.path],
            homeDirectory: try fakeHome()
        )

        #expect(found == nil)
    }

}
