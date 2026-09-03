/// ModelScanner cache-directory resolution.
///
/// Where the HuggingFace hub cache lives, and the `models--{org}--{name}`
/// directory layout inside it. Split out of `ModelScanner.swift` so the
/// scanner file stays about scanning: this is the one place that decides which
/// directory the provider reads models from and writes downloads to, and both
/// the discovery side (`ModelScanner`, `resolveLocalPath`) and the download
/// side (`ModelDownloader.cacheModelDirectory`) route through it so they
/// cannot disagree.

import Foundation

extension ModelScanner {

    /// Environment variable naming the hub cache directly. Highest priority,
    /// and already IS the `hub` directory, so nothing is appended.
    public static let hfHubCacheEnvKey = "HF_HUB_CACHE"

    /// Legacy alias of `HF_HUB_CACHE`, still honored by `huggingface_hub` and
    /// still read by this repo's own cache tooling
    /// (`scripts/mtp-cache-inventory.py`).
    public static let legacyHubCacheEnvKey = "HUGGINGFACE_HUB_CACHE"

    /// Environment variable naming the HuggingFace root; the hub cache lives
    /// at `$HF_HOME/hub`.
    public static let hfHomeEnvKey = "HF_HOME"

    /// XDG base directory; `HF_HOME` defaults to `$XDG_CACHE_HOME/huggingface`
    /// upstream, so the hub cache is `$XDG_CACHE_HOME/huggingface/hub`.
    public static let xdgCacheHomeEnvKey = "XDG_CACHE_HOME"

    /// The precedence ladder, highest priority first, as DATA rather than a
    /// chain of branches -- `doctor` reports the winning variable from this
    /// same list, so the diagnosis cannot drift from the behavior.
    ///
    /// Mirrors `huggingface_hub` (verified against 0.36.2):
    /// `HF_HUB_CACHE` > `HUGGINGFACE_HUB_CACHE` > `$HF_HOME/hub` >
    /// `$XDG_CACHE_HOME/huggingface/hub` > `~/.cache/huggingface/hub`.
    /// Matching upstream matters because `hf download` writes where upstream
    /// resolves; disagreeing would have the provider scan an empty directory
    /// and re-download models that are already on disk.
    static let cacheEnvSources: [(key: String, subpath: String?)] = [
        (hfHubCacheEnvKey, nil),
        (legacyHubCacheEnvKey, nil),
        (hfHomeEnvKey, "hub"),
        (xdgCacheHomeEnvKey, "huggingface/hub"),
    ]

    /// Every environment variable that can move the cache, highest priority
    /// first. Used by the launchd passthrough allow-list.
    public static var cacheEnvKeys: [String] { cacheEnvSources.map(\.key) }

    /// A resolved cache directory plus the environment variable that selected
    /// it (nil for the `~/.cache/huggingface/hub` default).
    public struct ResolvedCache: Sendable {
        public let url: URL
        public let environmentKey: String?

        public init(url: URL, environmentKey: String?) {
            self.url = url
            self.environmentKey = environmentKey
        }
    }

    /// Returns the HuggingFace hub cache directory for this process.
    public static func defaultCacheDirectory() -> URL? {
        cacheDirectory()
    }

    /// Optional-returning for source compatibility with existing call sites;
    /// resolution itself always succeeds.
    public static func defaultCacheDirectory(
        environment: [String: String],
        homeDirectory: URL
    ) -> URL? {
        resolveCache(environment: environment, homeDirectory: homeDirectory).url
    }

    /// The resolved cache directory. Non-optional: every branch yields a
    /// directory, so callers never need a fallback that re-hardcodes the home
    /// path -- which is exactly the drift this func exists to prevent.
    public static func cacheDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        resolveCache(environment: environment, homeDirectory: homeDirectory).url
    }

    /// Walk the precedence ladder and report both the directory and its source.
    ///
    /// The result is symlink-resolved: a cache reached through a link (a
    /// `~/.cache` symlinked to an external volume, `/tmp` -> `/private/tmp`)
    /// must produce the same canonical path on the discovery side as on the
    /// download side, or scanner and downloader disagree about whether a model
    /// is already present.
    public static func resolveCache(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ResolvedCache {
        for source in cacheEnvSources {
            guard let base = directoryURL(from: environment[source.key], homeDirectory: homeDirectory)
            else { continue }
            let url = source.subpath.map {
                base.appendingPathComponent($0, isDirectory: true)
            } ?? base
            return ResolvedCache(url: resolved(url), environmentKey: source.key)
        }
        return ResolvedCache(
            url: homeCacheDirectory(homeDirectory: homeDirectory),
            environmentKey: nil
        )
    }

    /// The no-environment default: `~/.cache/huggingface/hub`.
    public static func homeCacheDirectory(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        resolved(homeDirectory.appendingPathComponent(".cache/huggingface/hub", isDirectory: true))
    }

    /// Interpret an environment value as a directory URL, or nil when it is
    /// unset or blank.
    ///
    /// The path is used VERBATIM apart from tilde expansion: a directory name
    /// may legitimately end in a space, and huggingface_hub does not trim
    /// either, so trimming would silently resolve to a different directory.
    /// Only the blank test looks at the trimmed form.
    static func directoryURL(from raw: String?, homeDirectory: URL) -> URL? {
        guard let raw,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        guard let expanded = expandingTilde(raw, homeDirectory: homeDirectory) else { return nil }
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    /// Expand a leading tilde, or nil when the value starts with a `~` that
    /// cannot be expanded.
    ///
    /// `~` / `~/` use the injected home directory (so resolution stays
    /// testable). `~user` is delegated to Foundation, which consults the
    /// password database. An unexpandable `~user` returns nil rather than a
    /// path-relative literal directory named `~user`: a relative result would
    /// resolve differently in the operator's shell than in the launchd daemon,
    /// whose working directory is `/`.
    static func expandingTilde(_ path: String, homeDirectory: URL) -> String? {
        guard path.hasPrefix("~") else { return path }

        if path == "~" {
            return homeDirectory.path
        }
        if path.hasPrefix("~/") {
            return homeDirectory.appendingPathComponent(String(path.dropFirst(2))).path
        }

        let expanded = (path as NSString).expandingTildeInPath
        return expanded.hasPrefix("~") ? nil : expanded
    }

    /// Symlink-resolve a path that may not exist yet.
    ///
    /// `resolvingSymlinksInPath()` resolves the links it can and leaves the
    /// rest intact, so a not-yet-created cache dir under a symlinked parent
    /// still canonicalises correctly and never collapses to nil. It resolves
    /// links BEFORE collapsing `..`, matching `realpath(3)`.
    ///
    /// Paths at or beyond `PATH_MAX` are returned unresolved: Foundation
    /// silently TRUNCATES them (a 5001-character path comes back as 1024
    /// characters), which would point the scanner at an entirely different
    /// directory. An unresolved path is wrong-but-honest; a truncated one is
    /// wrong-and-silent.
    static func resolved(_ url: URL) -> URL {
        guard url.path.utf8.count < 1024 else { return url }
        return url.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Make a cache-path environment value absolute, for persisting into an
    /// environment that does not share the current working directory.
    ///
    /// launchd starts jobs with cwd `/`, so forwarding a relative `HF_HOME`
    /// verbatim would have the daemon resolve a different cache than the shell
    /// that installed it -- silently advertising no models. Returns nil for a
    /// blank value (nothing to forward).
    public static func absoluteCachePathValue(
        _ raw: String?,
        relativeTo base: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    ) -> String? {
        guard let raw,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let expanded = expandingTilde(raw, homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        else { return raw }

        if expanded.hasPrefix("/") { return expanded }
        return base.appendingPathComponent(expanded).path
    }

    /// The cache directory name HuggingFace gives a model ID.
    ///
    /// Single source of truth for the `models--{org}--{name}` layout so the
    /// download side and the discovery side cannot drift apart.
    public static func cacheDirectoryName(for modelID: String) -> String {
        "models--\(modelID.replacingOccurrences(of: "/", with: "--"))"
    }

    /// Where a model's files live (or should be written) inside the resolved
    /// hub cache: `{cache}/models--{org}--{name}`.
    public static func cacheModelDirectory(for modelID: String) -> URL {
        cacheModelDirectory(
            for: modelID,
            environment: ProcessInfo.processInfo.environment,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
    }

    /// Environment-injected form of `cacheModelDirectory(for:)`.
    public static func cacheModelDirectory(
        for modelID: String,
        environment: [String: String],
        homeDirectory: URL
    ) -> URL {
        cacheDirectory(environment: environment, homeDirectory: homeDirectory)
            .appendingPathComponent(cacheDirectoryName(for: modelID), isDirectory: true)
    }

    // MARK: - Cache health

    /// Whether `url` is an existing DIRECTORY.
    ///
    /// `fileExists(atPath:)` alone returns true for a regular file, so a
    /// `HF_HUB_CACHE` pointing at a file read as a healthy cache in `doctor`
    /// while the scanner silently found nothing.
    public static func isUsableCacheDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    /// Whether a cache directory holds at least one `models--*` entry.
    ///
    /// Used to warn when a redirected cache is empty but the default one is
    /// not -- the shape of an operator who exported `HF_HOME` for other
    /// tooling and would otherwise silently advertise zero models.
    public static func hasCachedModels(in cacheDirectory: URL) -> Bool {
        guard isUsableCacheDirectory(cacheDirectory) else { return false }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            atPath: cacheDirectory.path
        ) else { return false }
        return entries.contains { $0.hasPrefix("models--") }
    }
}
