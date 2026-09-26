/// ModelScanner cache-directory resolution.
///
/// Where the HuggingFace hub cache lives, and the `models--{org}--{name}`
/// directory layout inside it. Split out of `ModelScanner.swift` so the
/// scanner file stays about scanning: this is the one place that decides which
/// directory the provider reads models from and writes downloads to, and both
/// the discovery side (`ModelScanner`, `resolveLocalPath`) and the download
/// side (`ModelDownloader.cacheModelDirectory`) route through it so they
/// cannot disagree.

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
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

    /// Environment precedence mirrors `huggingface_hub`; a saved Darkbloom
    /// directory is considered only after these overrides, before the default.
    static let cacheEnvSources: [(key: String, subpath: String?)] = [
        (hfHubCacheEnvKey, nil),
        (legacyHubCacheEnvKey, nil),
        (hfHomeEnvKey, "hub"),
        (xdgCacheHomeEnvKey, "huggingface/hub"),
    ]

    /// Every environment variable that can move the cache, highest priority
    /// first. Used by the launchd passthrough allow-list.
    public static var cacheEnvKeys: [String] { cacheEnvSources.map(\.key) }

    /// A resolved cache directory and the environment or saved configuration
    /// that selected it. Neither source is set for the home-directory default.
    public struct ResolvedCache: Sendable {
        public let url: URL
        public let environmentKey: String?
        public let isConfigured: Bool

        public init(url: URL, environmentKey: String?, isConfigured: Bool = false) {
            self.url = url
            self.environmentKey = environmentKey
            self.isConfigured = isConfigured
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
        homeDirectory: URL,
        configuredDirectory: String? = nil
    ) -> URL? {
        resolveCache(
            environment: environment, homeDirectory: homeDirectory,
            configuredDirectory: configuredDirectory
        ).url
    }

    /// The cache directory for this process, including its saved configuration.
    public static func cacheDirectory() -> URL {
        resolveCache(configuredDirectory: configuredCacheDirectory).url
    }

    /// Resolve explicitly supplied inputs without reading process configuration.
    public static func cacheDirectory(
        environment: [String: String],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        configuredDirectory: String? = nil
    ) -> URL {
        resolveCache(
            environment: environment, homeDirectory: homeDirectory,
            configuredDirectory: configuredDirectory
        ).url
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
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        configuredDirectory: String? = nil
    ) -> ResolvedCache {
        for source in cacheEnvSources {
            guard let base = directoryURL(from: environment[source.key], homeDirectory: homeDirectory)
            else { continue }
            let url = source.subpath.map {
                base.appendingPathComponent($0, isDirectory: true)
            } ?? base
            return ResolvedCache(url: resolved(url), environmentKey: source.key)
        }
        if let url = normalizedCacheDirectory(configuredDirectory, homeDirectory: homeDirectory) {
            return ResolvedCache(url: url, environmentKey: nil, isConfigured: true)
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

    /// Normalize a user-entered cache directory without creating it. Relative
    /// paths use `base`; existing symlinks are resolved before interpreting `..`.
    /// Missing suffixes and paths beyond filesystem limits are never truncated.
    /// Blank, NUL-containing, and unexpandable tilde values are rejected.
    public static func normalizedCacheDirectory(
        _ raw: String?,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        relativeTo base: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    ) -> URL? {
        guard let path = absoluteCachePathValue(raw, relativeTo: base, homeDirectory: homeDirectory)
        else { return nil }
        return resolved(URL(fileURLWithPath: path, isDirectory: true))
    }

    static func directoryURL(from raw: String?, homeDirectory: URL) -> URL? {
        guard let path = absoluteCachePathValue(raw, homeDirectory: homeDirectory) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
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
            return homeDirectory.path + "/" + path.dropFirst(2)
        }

        // Expand only the username, not the remainder: Foundation path
        // standardization must not collapse `link/..` before following the link.
        let end = path.firstIndex(of: "/") ?? path.endIndex
        let expanded = (String(path[..<end]) as NSString).expandingTildeInPath
        return expanded.hasPrefix("~") ? nil : expanded + path[end...]
    }

    /// Resolve existing ancestors with `realpath` so links and `..` follow
    /// POSIX traversal order, without depending on Foundation standardization.
    /// Paths beyond the filesystem limit remain intact rather than truncated.
    /// If a leaf is missing, keep its suffix verbatim: `missing/../cache` cannot
    /// be simplified until `missing` exists. Other lookup errors stay unresolved.
    static func resolved(_ url: URL) -> URL {
        let path = url.path
        guard path.utf8.count < Int(PATH_MAX), !path.utf8.contains(0) else { return url }

        var prefix = path[...]
        var metadata = stat()
        while !prefix.isEmpty {
            let candidate = String(prefix)
            // Darwin realpath may simplify file/.. even though the kernel
            // rejects that traversal. Only canonicalize a traversable prefix.
            if stat(candidate, &metadata) == 0 {
                guard let buffer = realpath(candidate, nil) else { return url }
                defer { free(buffer) }
                guard let canonical = String(validatingCString: buffer) else { return url }
                let suffix = path[prefix.endIndex...]
                let separator = canonical.hasSuffix("/") || suffix.isEmpty || suffix.hasPrefix("/") ? "" : "/"
                return URL(fileURLWithPath: canonical + separator + suffix, isDirectory: true)
            }
            guard errno == ENOENT,
                  let slash = prefix.lastIndex(of: "/"), prefix != "/" else { return url }
            prefix = path[..<(slash == path.startIndex ? path.index(after: slash) : slash)]
        }
        return url
    }

    /// Make a path absolute before persisting it for launchd, whose cwd is `/`.
    /// Preserve nonblank whitespace and `..` components, which may cross links.
    public static func absoluteCachePathValue(
        _ raw: String?,
        relativeTo base: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String? {
        guard let raw, !raw.utf8.contains(0),
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let expanded = expandingTilde(raw, homeDirectory: homeDirectory) else { return nil }

        if expanded.hasPrefix("/") { return expanded }
        return base.path + "/" + expanded
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
        cacheDirectory().appendingPathComponent(cacheDirectoryName(for: modelID), isDirectory: true)
    }

    /// Environment-injected form of `cacheModelDirectory(for:)`.
    public static func cacheModelDirectory(
        for modelID: String,
        environment: [String: String],
        homeDirectory: URL,
        configuredDirectory: String? = nil
    ) -> URL {
        cacheDirectory(
            environment: environment, homeDirectory: homeDirectory,
            configuredDirectory: configuredDirectory
        )
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
}
