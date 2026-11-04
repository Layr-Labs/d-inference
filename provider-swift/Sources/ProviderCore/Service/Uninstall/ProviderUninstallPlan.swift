import DarkbloomClusterSecurity
import Darwin
import Foundation

/// Where this build of Darkbloom keeps things on this Mac, as `darkbloom uninstall` sees them. The roots are fixed
/// names under the home directory; a saved model or cache location the person chose is never one of them.
public struct ProviderUninstallPaths: Sendable, Equatable {
    /// The home directory with its own links resolved (`/var` → `/private/var`), so every root is canonical.
    public let home: URL
    /// `~/.darkbloom`: the app, the `bin/` links, logs, pairing, cluster setup and service state.
    public let installDirectory: URL
    public let appBundleName: String
    /// `~/.config/darkbloom`: `provider.toml` and saved cluster setups.
    public let configDirectory: URL
    /// `~/Library/Caches/darkbloom`: the encrypted prompt caches.
    public let cacheDirectory: URL
    /// `~/.cache/huggingface/hub`, where Darkbloom downloads models unless another location is saved.
    public let modelCache: URL
    /// `~/.cache/huggingface/darkbloom-cluster-models`, the cluster's model store beside it.
    public let clusterModelStore: URL
    /// The link the installer adds when it can (`/usr/local/bin/darkbloom` → `~/.darkbloom/bin/darkbloom`).
    public let commandLink: URL
    /// A model or cache location saved in `provider.toml`, which is kept.
    public var savedModelCache: URL?
    public var savedCacheDirectory: URL?
    /// Another Darkbloom install on this Mac (`~/.darkbloom-dev`, …) reads the same model cache, so its models stay.
    public var otherInstall: URL?

    public init(home: URL, environment: BuildEnvironment = .current, commandLinkDirectory: URL = URL(fileURLWithPath: "/usr/local/bin")) {
        let home = URL(fileURLWithPath: Self.canonical(home.path), isDirectory: true)
        self.home = home
        installDirectory = environment.installDirectory(home: home)
        appBundleName = environment.appBundleName
        configDirectory = environment.configDirectory(home: home)
        cacheDirectory = home.appendingPathComponent("Library/Caches/\(environment.encryptedCacheNamespace)", isDirectory: true)
        modelCache = home.appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
        clusterModelStore = home.appendingPathComponent(".cache/huggingface/darkbloom-cluster-models", isDirectory: true)
        commandLink = commandLinkDirectory.appendingPathComponent(environment.cliName)
        otherInstall = BuildEnvironment.allCases.filter { $0 != environment }
            .map { $0.installDirectory(home: home) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The live paths, with the locations saved in the `provider.toml` at `configPath`, resolved as the provider
    /// resolves them (`ConfigManager.modelCacheDirectory`, `CacheStorage.root`).
    public static func live(config: ProviderConfig?, configPath: URL,
                            home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Self {
        var paths = Self(home: home)
        if let config {
            paths.savedModelCache = (try? ConfigManager.modelCacheDirectory(in: config, relativeTo: configPath))
                .flatMap { $0 }.map { URL(fileURLWithPath: $0, isDirectory: true) }
            paths.savedCacheDirectory = config.cache.directory.map {
                URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(BuildEnvironment.current.encryptedCacheNamespace)
            }
        }
        return paths
    }

    /// The folders a deletion may resolve into. A target counts only when its resolved path is one of these or
    /// inside one, so a link to anywhere else, or one of these that is itself a link, is refused.
    var roots: [String] {
        [installDirectory, configDirectory, cacheDirectory, modelCache, clusterModelStore].map(\.path)
    }

    static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return URL(fileURLWithPath: path).standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// One thing `darkbloom uninstall` lists: what it is, its size and whether `--everything` deletes it.
public struct ProviderUninstallItem: Codable, Sendable, Equatable {
    public enum Verdict: String, Codable, Sendable {
        /// Darkbloom's, inside its folders: deleted by `--everything`.
        case remove
        /// Outside Darkbloom's folders (a location the person chose, another install's): never deleted.
        case keep
        /// It looks like Darkbloom's but resolves outside its folders: never deleted, and said why.
        case refused
    }

    public let label: String
    public let path: String
    public let bytes: Int64
    public let verdict: Verdict
    public let reason: String?
}

/// The other Mac this one is paired with, from the saved records only (no cable, no key).
public struct ProviderUninstallPairing: Sendable, Equatable {
    public struct Peer: Sendable, Equatable {
        public let pin: String
        public let name: String
        public init(pin: String, name: String) { self.pin = pin; self.name = name }
    }
    public var peers: [Peer]
    /// The other Mac of the current pair, as `darkbloom cluster` names it.
    public var otherMacName: String?
    /// This Mac's role in that pair.
    public var role: ClusterOnboardingRole?

    public init(peers: [Peer], otherMacName: String?, role: ClusterOnboardingRole?) {
        self.peers = peers; self.otherMacName = otherMacName; self.role = role
    }

    /// Nil when this Mac holds no pairing.
    public static func read(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Self? {
        guard let records = try? ClusterPairingStore.default(home: home).load(), !records.pairings.isEmpty else { return nil }
        let latest = records.pairings.max { $0.pairedAt < $1.pairedAt }
        return describing(peers: records.pairings.map { Peer(pin: $0.peerPin, name: $0.peerName) },
                          latest: latest.map { Peer(pin: $0.peerPin, name: $0.peerName) }, home: home,
                          local: try? ClusterSetupLinkExchange.pairing(store: .default(home: home)))
    }

    /// The other Mac's name and this Mac's role in the latest pairing, from the setup `darkbloom cluster` saved for it.
    static func describing(peers: [Peer], latest: Peer?, home: URL, local: ClusterSetupLinkExchange.Pairing?) -> Self {
        var pairing = Self(peers: peers, otherMacName: latest?.name, role: nil)
        guard let latest, let paths = try? ClusterUserPaths(homeDirectory: home),
              let record = try? ClusterSetupStore(paths: .init(paths: paths)).readRecord(),
              let leadership = record.leadership, leadership.peerPin == latest.pin else { return pairing }
        if !leadership.peerName.isEmpty { pairing.otherMacName = leadership.peerName }
        pairing.role = ClusterOnboardingRole(rawValue: leadership.role)
        // After onboarding the derived control leadership decides who leads, as `darkbloom cluster` shows it.
        if let local, let claim = record.control?.claim(localID: local.localMemberID, peerID: local.peerMemberID) {
            pairing.role = claim.leaderID == local.localMemberID ? .leader : .member
        }
        return pairing
    }
}

extension ProviderUninstall {
    /// Everything `--everything` would delete or keep, in deletion order: the install folder (with the app this
    /// command runs from) comes last.
    public static func inventory(_ paths: ProviderUninstallPaths) -> [ProviderUninstallItem] {
        var items: [ProviderUninstallItem] = []
        func add(_ label: String, _ url: URL, keep reason: String? = nil) {
            guard let item = item(label, url, paths: paths, keep: reason) else { return }
            items.append(item)
        }
        // A chosen folder inside Darkbloom's own goes with it, so only one outside them is listed as kept.
        func chosen(_ url: URL?) -> URL? {
            guard let url else { return nil }
            let resolved = ProviderUninstallPaths.canonical(url.path)
            return paths.roots.contains { resolved == $0 || resolved.hasPrefix($0 + "/") } ? nil : url
        }
        add("Settings", paths.configDirectory)
        add("Encrypted prompt caches", paths.cacheDirectory)
        if let saved = chosen(paths.savedCacheDirectory) {
            add("Encrypted prompt caches in the folder you chose", saved, keep: "outside Darkbloom's folders")
        }
        items += models(paths)
        if let saved = chosen(paths.savedModelCache) {
            add("Models in the folder you chose", saved, keep: "outside Darkbloom's folders")
        }
        add("Cluster model store", paths.clusterModelStore, keep: paths.otherInstall.map(sharedReason))
        add("The `\(paths.commandLink.lastPathComponent)` command link", paths.commandLink)
        add("Darkbloom folder: the app, logs, pairing and cluster setup", paths.installDirectory)
        return items
    }

    private static func sharedReason(_ other: URL) -> String { "\(other.lastPathComponent) on this Mac uses it too" }

    /// The model folders Darkbloom downloaded into the default model cache: those holding its verified receipt or
    /// its unfinished download. Anything else there belongs to another tool and is not listed.
    static func models(_ paths: ProviderUninstallPaths) -> [ProviderUninstallItem] {
        let cache = paths.modelCache
        guard FileManager.default.fileExists(atPath: cache.path) else { return [] }
        guard ProviderUninstallPaths.canonical(cache.path) == cache.path else {
            return [placed("Models", cache, verdict: .keep,
                           reason: "it links to \(ProviderUninstallPaths.canonical(cache.path)), outside Darkbloom's folders")]
        }
        var items: [ProviderUninstallItem] = []
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []).sorted()
        for name in names where name.hasPrefix("models--") {
            let folder = cache.appendingPathComponent(name, isDirectory: true)
            guard isDarkbloomModel(folder) else { continue }
            let id = name.dropFirst("models--".count).replacingOccurrences(of: "--", with: "/")
            if let item = item("Model \(id)", folder, paths: paths, keep: paths.otherInstall.map(sharedReason)) { items.append(item) }
        }
        let locks = cache.appendingPathComponent(".artifact-writer-locks", isDirectory: true)
        if paths.otherInstall == nil, let item = item("Model download locks", locks, paths: paths) { items.append(item) }
        return items
    }

    static func isDarkbloomModel(_ folder: URL) -> Bool {
        let snapshots = folder.appendingPathComponent("snapshots", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: snapshots.path)) ?? []
        return entries.contains { entry in
            entry.hasPrefix(".local-staging-") || FileManager.default.fileExists(
                atPath: snapshots.appendingPathComponent(entry).appendingPathComponent(".darkbloom-manifest.json").path)
        }
    }

    /// Nil when nothing is there. The command link is Darkbloom's only while it points at this install's `bin/`.
    static func item(_ label: String, _ url: URL, paths: ProviderUninstallPaths, keep reason: String? = nil) -> ProviderUninstallItem? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        if let reason { return placed(label, url, verdict: .keep, reason: reason) }
        if url == paths.commandLink {
            // Only the link itself is removed, never what it points to.
            let destination = linkDestination(url).map(URL.init(fileURLWithPath:))
            guard info.st_mode & S_IFMT == S_IFLNK, let destination, destination.lastPathComponent == url.lastPathComponent,
                  ProviderUninstallPaths.canonical(destination.deletingLastPathComponent().path)
                    == paths.installDirectory.appendingPathComponent("bin").path else {
                return .init(label: label, path: url.path, bytes: 0, verdict: .refused,
                             reason: "it is not the link Darkbloom's installer made")
            }
            return .init(label: label, path: url.path, bytes: 0, verdict: .remove, reason: nil)
        }
        let resolved = ProviderUninstallPaths.canonical(url.path)
        guard paths.roots.contains(where: { resolved == $0 || resolved.hasPrefix($0 + "/") }) else {
            return placed(label, url, verdict: .refused, reason: "it resolves to \(resolved), outside Darkbloom's folders")
        }
        let measured = measure(url)
        if measured.otherVolume {
            return .init(label: label, path: url.path, bytes: measured.bytes, verdict: .refused,
                         reason: "another disk is mounted inside it")
        }
        return .init(label: label, path: url.path, bytes: measured.bytes, verdict: .remove, reason: nil)
    }

    /// Sized where it resolves, so a kept or refused link shows what it holds.
    private static func placed(_ label: String, _ url: URL, verdict: ProviderUninstallItem.Verdict, reason: String) -> ProviderUninstallItem {
        let bytes = measure(URL(fileURLWithPath: ProviderUninstallPaths.canonical(url.path))).bytes
        return .init(label: label, path: url.path, bytes: bytes, verdict: verdict, reason: reason)
    }

    static func linkDestination(_ link: URL) -> String? {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else { return nil }
        return URL(fileURLWithPath: destination, relativeTo: link.deletingLastPathComponent()).standardizedFileURL.path
    }

    /// Allocated bytes under `url`, never following a link, each hard-linked file once; and whether a folder
    /// inside it is on another volume.
    static func measure(_ url: URL) -> (bytes: Int64, otherVolume: Bool) {
        var root = stat()
        guard stat(url.path, &root) == 0 else { return (0, false) }
        guard root.st_mode & S_IFMT == S_IFDIR, lstat(url.path, &root) == 0, root.st_mode & S_IFMT == S_IFDIR,
              let walker = FileManager.default.enumerator(atPath: url.path) else {
            return (Int64(root.st_blocks) * 512, false)
        }
        var bytes: Int64 = 0, seen = Set<[UInt64]>(), otherVolume = false
        while let relative = walker.nextObject() as? String {
            var info = stat()
            guard lstat(url.appendingPathComponent(relative).path, &info) == 0 else { continue }
            if info.st_mode & S_IFMT == S_IFDIR {
                if info.st_dev != root.st_dev { otherVolume = true; walker.skipDescendants() }
                continue
            }
            if info.st_nlink > 1, !seen.insert([UInt64(UInt32(bitPattern: info.st_dev)), info.st_ino]).inserted { continue }
            bytes += Int64(info.st_blocks) * 512
        }
        return (bytes, otherVolume)
    }
}
