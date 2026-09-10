import Foundation
import Testing

@testable import ProviderCoreFoundation

/// Locks the HuggingFace cache-directory resolution order, which mirrors
/// `huggingface_hub` (verified against 0.36.2) so the provider reads the same
/// directory `hf download` writes:
///   1. `$HF_HUB_CACHE`          -> verbatim (already names the hub dir)
///   2. `$HUGGINGFACE_HUB_CACHE` -> verbatim (legacy alias)
///   3. `$HF_HOME`               -> `$HF_HOME/hub`
///   4. `$XDG_CACHE_HOME`        -> `$XDG_CACHE_HOME/huggingface/hub`
///   5. `~/.cache/huggingface/hub`
///
/// Every branch resolves symlinks so downstream path comparisons (scanner
/// discovery vs. downloader placement) agree on one canonical path.
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
        let url = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("hf-cache-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.urls.append(url)
        return url
    }

    private func fakeHome() throws -> URL { try makeDir("home") }

    // MARK: - Precedence

    /// The full ladder, peeled one variable at a time. Matches huggingface_hub:
    /// `HF_HUB_CACHE` > `HUGGINGFACE_HUB_CACHE` > `$HF_HOME/hub` >
    /// `$XDG_CACHE_HOME/huggingface/hub` > `~/.cache/huggingface/hub`.
    @Test("precedence ladder matches huggingface_hub")
    func precedenceLadder() throws {
        let hubCache = try makeDir("hubcache")
        let legacy = try makeDir("legacy")
        let hfHome = try makeDir("hfhome")
        let xdg = try makeDir("xdg")
        let home = try fakeHome()

        var env = [
            "HF_HUB_CACHE": hubCache.path,
            "HUGGINGFACE_HUB_CACHE": legacy.path,
            "HF_HOME": hfHome.path,
            "XDG_CACHE_HOME": xdg.path,
        ]
        func resolve() -> String? {
            ModelScanner.defaultCacheDirectory(environment: env, homeDirectory: home)?.path
        }

        #expect(resolve() == hubCache.path)

        env.removeValue(forKey: "HF_HUB_CACHE")
        #expect(resolve() == legacy.path)

        env.removeValue(forKey: "HUGGINGFACE_HUB_CACHE")
        #expect(resolve() == hfHome.appendingPathComponent("hub").path)

        env.removeValue(forKey: "HF_HOME")
        #expect(resolve() == xdg.appendingPathComponent("huggingface/hub").path)

        env.removeValue(forKey: "XDG_CACHE_HOME")
        #expect(resolve() == home.appendingPathComponent(".cache/huggingface/hub").path)
    }

    /// The resolution reports which variable selected the directory, so
    /// `doctor` cannot drift from the precedence it describes.
    @Test("the resolved cache names the environment variable that selected it")
    func resolvedCacheNamesItsSource() throws {
        let dir = try makeDir("source")
        let home = try fakeHome()

        let cases: [(String, String)] = [
            ("HF_HUB_CACHE", "HF_HUB_CACHE"),
            ("HUGGINGFACE_HUB_CACHE", "HUGGINGFACE_HUB_CACHE"),
            ("HF_HOME", "HF_HOME"),
            ("XDG_CACHE_HOME", "XDG_CACHE_HOME"),
        ]
        for (key, expected) in cases {
            let resolved = ModelScanner.resolveCache(
                environment: [key: dir.path], homeDirectory: home)
            #expect(resolved.environmentKey == expected)
        }

        // No override -> no source variable.
        #expect(ModelScanner.resolveCache(environment: [:], homeDirectory: home)
            .environmentKey == nil)
        #expect(ModelScanner.resolveCache(environment: [:], homeDirectory: home).url.path
            == home.appendingPathComponent(".cache/huggingface/hub").path)
    }

    @Test("HF_HUB_CACHE is used verbatim, with no /hub appended")
    func hfHubCacheVerbatim() throws {
        let hubCache = try makeDir("hubcache")

        let resolved = ModelScanner.defaultCacheDirectory(
            environment: ["HF_HUB_CACHE": hubCache.path],
            homeDirectory: try fakeHome()
        )

        // HF_HUB_CACHE already IS the hub directory -- no "/hub" suffix.
        #expect(resolved?.path == hubCache.path)
    }

    @Test("falls back to ~/.cache/huggingface/hub when neither var is set")
    func homeFallback() throws {
        let home = try fakeHome()

        let resolved = ModelScanner.defaultCacheDirectory(
            environment: [:],
            homeDirectory: home
        )

        #expect(resolved?.path == home.appendingPathComponent(".cache/huggingface/hub").path)
    }

    // MARK: - Degenerate env values

    @Test("empty and whitespace-only values fall through to the next source")
    func blankValuesIgnored() throws {
        let hfHome = try makeDir("hfhome-blank")
        let home = try fakeHome()

        // Blank at every rung falls through to the next one.
        #expect(
            ModelScanner.defaultCacheDirectory(
                environment: [
                    "HF_HUB_CACHE": "",
                    "HUGGINGFACE_HUB_CACHE": "   ",
                    "HF_HOME": hfHome.path,
                ],
                homeDirectory: home
            )?.path == hfHome.appendingPathComponent("hub").path
        )

        // All blank -> home fallback. (huggingface_hub treats an empty
        // HF_HUB_CACHE as SET and resolves to "", which is never useful; a
        // blank value is treated as unset here deliberately.)
        #expect(
            ModelScanner.defaultCacheDirectory(
                environment: [
                    "HF_HUB_CACHE": "",
                    "HUGGINGFACE_HUB_CACHE": "  ",
                    "HF_HOME": "",
                    "XDG_CACHE_HOME": " ",
                ],
                homeDirectory: home
            )?.path == home.appendingPathComponent(".cache/huggingface/hub").path
        )
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

    @Test("a symlinked home directory resolves in the fallback branch")
    func homeFallbackSymlinkResolved() throws {
        let realHome = try makeDir("realhome")
        let cache = realHome.appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)

        let linkParent = try makeDir("linkparent3")
        let homeLink = linkParent.appendingPathComponent("home-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: homeLink, withDestinationURL: realHome)

        let resolved = ModelScanner.defaultCacheDirectory(
            environment: [:],
            homeDirectory: homeLink
        )

        #expect(resolved?.path == cache.path)
    }

    @Test("a not-yet-created cache path still resolves")
    func nonexistentPathResolves() throws {
        let hfHome = try makeDir("hfhome-missing")
        let missing = hfHome.appendingPathComponent("not-created-yet")

        let resolved = ModelScanner.defaultCacheDirectory(
            environment: ["HF_HOME": missing.path],
            homeDirectory: try fakeHome()
        )

        // The downloader creates it on first use -- resolution must not nil out.
        #expect(resolved?.path == missing.appendingPathComponent("hub").path)
    }

    // MARK: - Hostile / malformed values

    /// `~user` must not silently become a CWD-relative literal directory named
    /// "~user" -- that path differs between the operator's shell and the
    /// launchd daemon (cwd `/`).
    @Test("a ~user path expands rather than becoming a relative literal")
    func tildeUserDoesNotBecomeRelative() throws {
        let resolved = ModelScanner.defaultCacheDirectory(
            environment: ["HF_HOME": "~root/models"],
            homeDirectory: try fakeHome()
        )

        let path = try #require(resolved?.path)
        #expect(path.hasPrefix("/"))
        #expect(!path.contains("~"))
    }

    /// An unknown user cannot be expanded; falling through to the next source
    /// beats building a garbage relative path.
    @Test("an unexpandable ~user falls through to the next source")
    func unexpandableTildeUserFallsThrough() throws {
        let home = try fakeHome()

        let resolved = ModelScanner.defaultCacheDirectory(
            environment: ["HF_HOME": "~nosuchuser-\(UUID().uuidString)/x"],
            homeDirectory: home
        )

        #expect(resolved?.path == home.appendingPathComponent(".cache/huggingface/hub").path)
    }

    /// `resolvingSymlinksInPath()` silently TRUNCATES at PATH_MAX (a 5001-char
    /// path comes back as 1024 chars), which would point the scanner at a
    /// different directory than the operator named. Better to hand back the
    /// path unresolved than a corrupted one.
    @Test("an over-long path is not silently truncated")
    func overLongPathNotTruncated() throws {
        let long = "/" + String(repeating: "a", count: 5000)

        let resolved = ModelScanner.defaultCacheDirectory(
            environment: ["HF_HUB_CACHE": long],
            homeDirectory: try fakeHome()
        )

        #expect(resolved?.path == long)
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

    @Test("an already-absolute cache path is passed through unchanged")
    func absolutePathUnchanged() throws {
        let base = try makeDir("cwd2")

        #expect(ModelScanner.absoluteCachePathValue("/Volumes/models/hf", relativeTo: base)
            == "/Volumes/models/hf")
        // Blank stays blank (nothing to forward).
        #expect(ModelScanner.absoluteCachePathValue("   ", relativeTo: base) == nil)
        #expect(ModelScanner.absoluteCachePathValue("", relativeTo: base) == nil)
    }

    @Test("a ~ path is absolutised for the daemon too")
    func tildePathAbsolutisedForDaemon() throws {
        let base = try makeDir("cwd3")

        let out = try #require(ModelScanner.absoluteCachePathValue("~/models", relativeTo: base))
        #expect(out.hasPrefix("/"))
        #expect(!out.contains("~"))
    }

    // MARK: - Model directory layout

    @Test("cacheModelDirectory sits under the resolved cache dir")
    func cacheModelDirectoryHonoursOverride() throws {
        let hfHome = try makeDir("hfhome-modeldir")
        let env = ["HF_HOME": hfHome.path]
        let home = try fakeHome()

        let dir = ModelScanner.cacheModelDirectory(
            for: "mlx-community/Foo-Bar",
            environment: env,
            homeDirectory: home
        )

        #expect(
            dir.path == hfHome.appendingPathComponent("hub/models--mlx-community--Foo-Bar").path
        )
    }

    @Test("cacheModelDirectory flattens the org separator")
    func cacheModelDirectoryFlattensSlash() throws {
        let home = try fakeHome()

        let dir = ModelScanner.cacheModelDirectory(
            for: "acme/Nested-Model",
            environment: [:],
            homeDirectory: home
        )

        #expect(dir.lastPathComponent == "models--acme--Nested-Model")
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

    @Test("cacheDirectory is the non-optional form of defaultCacheDirectory")
    func cacheDirectoryMatchesOptionalForm() throws {
        let hfHome = try makeDir("hfhome-nonopt")
        let home = try fakeHome()

        for env in [[:], ["HF_HOME": hfHome.path], ["HF_HUB_CACHE": hfHome.path]] as [[String: String]] {
            #expect(
                ModelScanner.cacheDirectory(environment: env, homeDirectory: home).path
                    == ModelScanner.defaultCacheDirectory(environment: env, homeDirectory: home)?.path
            )
        }

        #expect(
            ModelScanner.homeCacheDirectory(homeDirectory: home).path
                == home.appendingPathComponent(".cache/huggingface/hub").path
        )
    }

    // MARK: - Detecting a cache that moved

    @Test("hasCachedModels sees models-- entries and ignores other files")
    func hasCachedModelsDetection() throws {
        let empty = try makeDir("empty-cache")
        #expect(ModelScanner.hasCachedModels(in: empty) == false)

        // A missing directory is not an error, just "no models".
        #expect(ModelScanner.hasCachedModels(
            in: empty.appendingPathComponent("nope", isDirectory: true)) == false)

        // Unrelated entries do not count.
        try "x".write(to: empty.appendingPathComponent("README"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: empty.appendingPathComponent("blobs", isDirectory: true),
            withIntermediateDirectories: true)
        #expect(ModelScanner.hasCachedModels(in: empty) == false)

        try FileManager.default.createDirectory(
            at: empty.appendingPathComponent("models--acme--Tiny", isDirectory: true),
            withIntermediateDirectories: true)
        #expect(ModelScanner.hasCachedModels(in: empty) == true)
    }

    /// A path that is a regular FILE must not read as a usable cache -- doctor
    /// reported PASS for it before, while the scanner found nothing.
    @Test("hasCachedModels is false when the path is a regular file")
    func hasCachedModelsRejectsFile() throws {
        let parent = try makeDir("filecache")
        let file = parent.appendingPathComponent("hub")
        try "not a directory".write(to: file, atomically: true, encoding: .utf8)

        #expect(ModelScanner.hasCachedModels(in: file) == false)
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
        // Lay the model out ONLY under the flattened name, and make the nested
        // shape exist too so a buggy branch would have something to find.
        let nested = hfHome.appendingPathComponent(
            "hub/models--acme/Slashed/snapshots/x", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let found = ModelScanner.resolveLocalPath(
            modelID: "acme/Slashed",
            environment: ["HF_HOME": hfHome.path],
            homeDirectory: try fakeHome()
        )

        // Only the flattened directory exists as a real model dir, so nothing
        // should resolve to the nested one.
        #expect(found?.path.contains("models--acme/Slashed") != true)
    }

    @Test("resolveLocalPath finds a snapshot under the HF_HOME override")
    func resolveLocalPathUsesOverride() throws {
        let hfHome = try makeDir("hfhome-resolve")
        let snapshot = hfHome
            .appendingPathComponent("hub/models--acme--Tiny-4bit/snapshots/abc123", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try "{}".write(to: snapshot.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

        let found = ModelScanner.resolveLocalPath(
            modelID: "acme/Tiny-4bit",
            environment: ["HF_HOME": hfHome.path],
            homeDirectory: try fakeHome()
        )

        #expect(found?.path == snapshot.path)
    }
}
