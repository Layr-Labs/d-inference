import DarkbloomClusterRemote
import DarkbloomClusterSecurity
import Darwin
import Foundation

/// Where this build of Darkbloom keeps things on this Mac, as `darkbloom uninstall` sees them. The roots are fixed
/// names under the home directory; a saved model or cache location the person chose is never one of them.
public struct ProviderUninstallPaths: Sendable, Equatable {
    /// The home directory with its own links resolved (`/var` → `/private/var`), so every root is canonical.
    public let home: URL
    /// The install these paths are for.
    public let environment: BuildEnvironment
    /// `~/.darkbloom`: the app, the `bin/` links, logs, and this install's pairing, cluster setup and service state.
    public let installDirectory: URL
    public let appBundleName: String
    /// `~/.config/darkbloom`: `provider.toml` and this install's saved cluster setups.
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
    /// Another Darkbloom install on this Mac, told by its app or its command in its own folder. Each install keeps its
    /// own pairing and cluster setup in its own folders, but both use this Mac's one cable port setup, which stays
    /// while the other is here (`ProviderUninstall.Plan.cableKeptFor`).
    public var otherEnvironment: BuildEnvironment?

    public init(home: URL, environment: BuildEnvironment = .current, commandLinkDirectory: URL = URL(fileURLWithPath: "/usr/local/bin")) {
        let home = URL(fileURLWithPath: Self.canonical(home.path), isDirectory: true)
        self.home = home
        self.environment = environment
        installDirectory = environment.installDirectory(home: home)
        appBundleName = environment.appBundleName
        configDirectory = environment.configDirectory(home: home)
        cacheDirectory = home.appendingPathComponent("Library/Caches/\(environment.encryptedCacheNamespace)", isDirectory: true)
        modelCache = home.appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
        clusterModelStore = home.appendingPathComponent(".cache/huggingface/darkbloom-cluster-models", isDirectory: true)
        commandLink = commandLinkDirectory.appendingPathComponent(environment.cliName)
        otherEnvironment = BuildEnvironment.allCases.filter { $0 != environment }.first { other in
            let folder = other.installDirectory(home: home)
            return [other.appBundleName, "bin/\(other.cliName)"].contains {
                var info = stat()
                return lstat(folder.appendingPathComponent($0).path, &info) == 0
            }
        }
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

/// One thing `darkbloom uninstall` lists: what it is, its size and whether it is deleted.
public struct ProviderUninstallItem: Codable, Sendable, Equatable {
    public enum Verdict: String, Codable, Sendable {
        /// Darkbloom's, inside its folders: deleted (a model only by `--everything`).
        case remove
        /// Outside Darkbloom's folders (a location the person chose, another install's): never deleted.
        case keep
        /// It looks like Darkbloom's but resolves outside its folders: never deleted, and said why.
        case refused
    }

    public enum Kind: String, Codable, Sendable {
        case data
        /// A model folder Darkbloom downloaded, its download locks or the cluster model store: `--keep-models` keeps it.
        case model
        /// Deleting it takes away the `darkbloom` command: the install folder (the app, and the cable records
        /// `cluster link --remove` reads) and the command link.
        case command
    }

    public let label: String
    public let path: String
    public let bytes: Int64
    public let verdict: Verdict
    public let reason: String?
    public var kind: Kind = .data
    /// Its files' blocks, for counting APFS clones once (`ProviderUninstall.uniqueBytes`).
    var files: [ProviderUninstallFile] = []
    /// Folders inside it that stay (resolved paths): the models folder the person chose, and the store beside it.
    var keeping: [String] = []
    /// What `keeping` is, as the deleted folder's row names it ("the models you chose").
    var keepingWhat = ""
    /// Kept although it lies inside one of Darkbloom's folders, because the person chose it for models.
    var keptInDarkbloomFolder = false

    private enum CodingKeys: String, CodingKey { case label, path, bytes, verdict, reason, kind }
}

/// One regular file's allocated bytes and, on APFS, its clone facts (`getattrlist`'s `ATTR_CMNEXT_*`).
struct ProviderUninstallFile: Sendable, Equatable {
    let allocated: Int64
    /// Bytes no other file shares.
    var privateBytes: Int64?
    /// Pure clones (`clonefile`, `cp -c`) share one id while neither changes; `references` is how many files hold it.
    var cloneID: UInt64?
    var references: UInt32?
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
    /// What `darkbloom uninstall` (or `--dry-run`) runs on this Mac, in order.
    public struct Plan: Sendable, Equatable {
        public struct Service: Sendable, Equatable {
            public let name: String
            /// The launch agent file, or nil when it is not installed.
            public let path: String?
            public init(name: String, path: String?) { self.name = name; self.path = path }
        }
        public let cli: String
        /// The command that installs Darkbloom again, for the way back after `--keep-models`.
        public let installCommand: String
        /// The cluster service's launch agent files (`ClusterServiceAgent.installedLabels`); empty when it is not set up.
        public let clusterService: [String]
        /// A cluster service holds this Mac's service lock without a login agent (`ClusterService.running`), as one
        /// `darkbloom cluster` started in a session does.
        public let clusterServiceRunning: Bool
        /// That service, and whose it is (`Operations.runningClusterService`), when it could be read. Giving it sets
        /// `clusterServiceRunning` too.
        public let runningClusterService: RunningClusterService?
        public let services: [Service]
        public let items: [ProviderUninstallItem]
        public let pairing: ProviderUninstallPairing?
        /// Darkbloom things this command never removes, each with how to remove it (the fan helper, …).
        public let elsewhere: [String]
        /// The other install on this Mac (`ProviderUninstallPaths.otherEnvironment`), which may use the same cable: the
        /// cable port setup stays for it. Nil when this install is the only one.
        public let cableKeptFor: BuildEnvironment?

        public init(cli: String = BuildEnvironment.current.cliName,
                    installCommand: String = "curl -fsSL \(BuildEnvironment.current.coordinatorHTTPURL)/install.sh | bash",
                    clusterService: [String] = [], clusterServiceRunning: Bool = false,
                    runningClusterService: RunningClusterService? = nil, services: [Service],
                    items: [ProviderUninstallItem],
                    pairing: ProviderUninstallPairing?, elsewhere: [String] = [], cableKeptFor: BuildEnvironment? = nil) {
            self.cli = cli; self.installCommand = installCommand; self.clusterService = clusterService
            self.clusterServiceRunning = clusterServiceRunning || runningClusterService != nil
            self.runningClusterService = runningClusterService
            self.services = services; self.items = items; self.pairing = pairing; self.elsewhere = elsewhere
            self.cableKeptFor = cableKeptFor
        }

        /// What `mode` deletes, in order.
        func removed(_ mode: Mode) -> [ProviderUninstallItem] {
            items.filter { $0.verdict == .remove && !mode.keeps($0) }
        }
        var models: [ProviderUninstallItem] { items.filter { $0.verdict == .remove && $0.kind == .model } }
        var kept: [ProviderUninstallItem] { items.filter { $0.verdict == .keep } }
        var refused: [ProviderUninstallItem] { items.filter { $0.verdict == .refused } }
        /// Disk space deleting `mode`'s items frees, with APFS clones counted once.
        func frees(_ mode: Mode) -> Int64 { uniqueBytes(removed(mode)) }
        var modelBytes: Int64 { uniqueBytes(models) }
    }

    static let chosenModelsLabel = "Models in the folder you chose"
    static let foreignLinkReason = "it is not the link Darkbloom's installer made"
    static let chosenStoreLabel = "Cluster model store beside the folder you chose"
    static let clusterStoreLabel = "Cluster model store"
    /// The model cache when it is a link to a folder outside Darkbloom's: kept whole.
    static let linkedModelsLabel = "Models"
    static let chosenInsideReason = "you chose this folder for models, so it stays, with the folders that lead to it"
    static let chosenWhat = "the models you chose"
    static let chosenFolderIsItReason = "it is the models folder you chose, which is never deleted"
    static let chosenFolderHoldsItReason = "it is inside the models folder you chose, which is never deleted"
    static let chosenStoreInsideReason = "it holds the cluster's copies of the models you chose, so it stays too"

    /// Everything `--everything` would delete or keep, in deletion order: the install folder (with the app this
    /// command runs from) comes last.
    public static func inventory(_ paths: ProviderUninstallPaths) -> [ProviderUninstallItem] {
        var items: [ProviderUninstallItem] = []
        func add(_ label: String, _ url: URL, keep reason: String? = nil, kind: ProviderUninstallItem.Kind = .data) {
            guard var item = item(label, url, paths: paths, keep: reason) else { return }
            item.kind = kind
            items.append(item)
        }
        func inRoots(_ resolved: String) -> Bool { paths.roots.contains { resolved == $0 || resolved.hasPrefix($0 + "/") } }
        // A chosen cache folder inside Darkbloom's own goes with it, so only one outside them is listed as kept.
        if let saved = paths.savedCacheDirectory, !inRoots(ProviderUninstallPaths.canonical(saved.path)) {
            add("Encrypted prompt caches in the folder you chose", saved, keep: "outside Darkbloom's folders")
        }
        // A models folder the person chose is never deleted, in either mode and wherever it is; nor is the cluster
        // store the provider keeps beside it (`ClusterModelStoreLocation`). Inside one of Darkbloom's folders, that
        // folder is deleted around them.
        let chosenModels = paths.savedModelCache.map { URL(fileURLWithPath: ProviderUninstallPaths.canonical($0.path)) }
            .flatMap { $0.path == ProviderUninstallPaths.canonical(paths.modelCache.path) ? nil : $0 }
        let chosenStore = chosenModels.map { $0.deletingLastPathComponent().appendingPathComponent("darkbloom-cluster-models") }
        var protected: [(path: String, what: String)] = []
        for (label, folder, insideReason) in [(chosenModelsLabel, chosenModels, chosenInsideReason),
                                              (chosenStoreLabel, chosenStore, chosenStoreInsideReason)] {
            guard let folder else { continue }
            let inside = inRoots(folder.path)
            guard var kept = item(label, folder, paths: paths, keep: inside ? insideReason : "outside Darkbloom's folders") else { continue }
            kept.keptInDarkbloomFolder = inside
            items.append(kept)
            protected.append((folder.path, chosenWhat))
        }
        add("Settings", paths.configDirectory)
        add("Encrypted prompt caches", paths.cacheDirectory)
        items += models(paths)
        add(clusterStoreLabel, paths.clusterModelStore, keep: paths.otherInstall.map(sharedReason), kind: .model)
        add("The `\(paths.commandLink.lastPathComponent)` command link", paths.commandLink, kind: .command)
        add(installFolderLabel, paths.installDirectory, kind: .command)
        // What finishes the uninstall once the models are out: the settings that named the folder are gone by then.
        let again = "\(paths.installDirectory.path)/bin/\(paths.commandLink.lastPathComponent) uninstall"
        let advice = ". To finish, move the models you want to keep out of it, then run `\(again)` again, which deletes the rest of it"
        return items.compactMap { around($0, protected, advice: advice) }
    }

    /// `item` with the protected folders inside it left out (and measured without them); nil when it lies inside one.
    private static func around(_ item: ProviderUninstallItem, _ protected: [(path: String, what: String)],
                               advice: String) -> ProviderUninstallItem? {
        guard item.verdict == .remove, !protected.isEmpty else { return item }
        // A link is deleted itself, never what it points to, so where the link is decides (the command link).
        let resolved = isLink(item.path) ? item.path : ProviderUninstallPaths.canonical(item.path)
        if let holder = protected.first(where: { resolved == $0.path || resolved.hasPrefix($0.path + "/") }) {
            // It stays with the folder the person chose for models. Models there are theirs; anything else of
            // Darkbloom's staying, the app folder above all, means Darkbloom is not fully removed: refused, and named.
            guard holder.what == chosenWhat, item.kind != .model else { return nil }
            return ProviderUninstallItem(label: item.label, path: item.path, bytes: item.bytes, verdict: .refused,
                                         reason: (resolved == holder.path ? chosenFolderIsItReason : chosenFolderHoldsItReason) + advice,
                                         kind: item.kind)
        }
        let inside = protected.filter { $0.path.hasPrefix(resolved + "/") }
        guard !inside.isEmpty else { return item }
        let measured = measure(URL(fileURLWithPath: resolved), excluding: inside.map(\.path))
        var kept = ProviderUninstallItem(label: item.label, path: item.path, bytes: measured.bytes, verdict: item.verdict,
                                         reason: item.reason, kind: item.kind, files: measured.files)
        kept.keeping = inside.map(\.path)
        kept.keepingWhat = inside.map(\.what).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .joined(separator: " and ")
        return kept
    }

    /// The install folder's row: each install keeps its own pairing and cluster setup in it (`ClusterUserPaths`).
    static let installFolderLabel = "Darkbloom folder: the app, logs, pairing and cluster setup"

    /// How the summary and the kept lines name an install: the production one, or by its app's name.
    static func installName(_ environment: BuildEnvironment) -> String {
        environment == .prod ? "the production Darkbloom" : environment.appDisplayName
    }

    private static func sharedReason(_ other: URL) -> String { "\(other.lastPathComponent) on this Mac uses it too" }

    /// The model folders Darkbloom downloaded into the default model cache: those holding its verified receipt or
    /// its unfinished download. Anything else there belongs to another tool and is not listed.
    static func models(_ paths: ProviderUninstallPaths) -> [ProviderUninstallItem] {
        let cache = paths.modelCache
        guard FileManager.default.fileExists(atPath: cache.path) else { return [] }
        guard ProviderUninstallPaths.canonical(cache.path) == cache.path else {
            return [placed(linkedModelsLabel, cache, verdict: .keep,
                           reason: "it links to \(ProviderUninstallPaths.canonical(cache.path)), outside Darkbloom's folders")]
        }
        var items: [ProviderUninstallItem] = []
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []).sorted()
        for name in names where name.hasPrefix("models--") {
            let folder = cache.appendingPathComponent(name, isDirectory: true)
            guard isDarkbloomModel(folder) else { continue }
            let id = name.dropFirst("models--".count).replacingOccurrences(of: "--", with: "/")
            if var item = item("Model \(id)", folder, paths: paths, keep: paths.otherInstall.map(sharedReason)) {
                item.kind = .model
                items.append(item)
            }
        }
        let locks = cache.appendingPathComponent(".artifact-writer-locks", isDirectory: true)
        if paths.otherInstall == nil, var item = item("Model download locks", locks, paths: paths) {
            item.kind = .model
            items.append(item)
        }
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
                return .init(label: label, path: url.path, bytes: 0, verdict: .refused, reason: foreignLinkReason)
            }
            return .init(label: label, path: url.path, bytes: 0, verdict: .remove, reason: nil)
        }
        let resolved = ProviderUninstallPaths.canonical(url.path)
        guard paths.roots.contains(where: { resolved == $0 || resolved.hasPrefix($0 + "/") }) else {
            return placed(label, url, verdict: .refused, reason: "it resolves to \(resolved), outside Darkbloom's folders")
        }
        if isMountPoint(url) {
            return .init(label: label, path: url.path, bytes: measure(url).bytes, verdict: .refused,
                         reason: "another disk is mounted here")
        }
        let measured = measure(url)
        if measured.otherVolume {
            return .init(label: label, path: url.path, bytes: measured.bytes, verdict: .refused,
                         reason: "another disk is mounted inside it")
        }
        return .init(label: label, path: url.path, bytes: measured.bytes, verdict: .remove, reason: nil, files: measured.files)
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

    /// Allocated bytes under `url`, never following a link and each hard-linked file once; whether a folder inside
    /// it is on another volume; and each file's blocks, which `uniqueBytes` counts with APFS clones once.
    static func measure(_ url: URL, excluding: [String] = []) -> (bytes: Int64, otherVolume: Bool, files: [ProviderUninstallFile]) {
        var root = stat()
        guard stat(url.path, &root) == 0 else { return (0, false, []) }
        guard root.st_mode & S_IFMT == S_IFDIR, lstat(url.path, &root) == 0, root.st_mode & S_IFMT == S_IFDIR,
              let walker = FileManager.default.enumerator(atPath: url.path) else {
            return (Int64(root.st_blocks) * 512, false, [])
        }
        var files: [ProviderUninstallFile] = [], seen = Set<[UInt64]>(), otherVolume = false
        while let relative = walker.nextObject() as? String {
            let path = url.appendingPathComponent(relative).path
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            if info.st_mode & S_IFMT == S_IFDIR {
                if excluding.contains(path) { walker.skipDescendants() }
                else if info.st_dev != root.st_dev { otherVolume = true; walker.skipDescendants() }
                continue
            }
            if info.st_nlink > 1, !seen.insert([UInt64(UInt32(bitPattern: info.st_dev)), info.st_ino]).inserted { continue }
            var file = ProviderUninstallFile(allocated: Int64(info.st_blocks) * 512)
            if info.st_mode & S_IFMT == S_IFREG { cloneFacts(path, into: &file) }
            files.append(file)
        }
        return (files.reduce(0) { $0 + $1.allocated }, otherVolume, files)
    }

    /// Whether another volume is mounted at `url`: its device differs from its parent folder's.
    public static func isMountPoint(_ url: URL) -> Bool {
        var own = stat(), parent = stat()
        guard lstat(url.path, &own) == 0, stat(url.deletingLastPathComponent().path, &parent) == 0 else { return false }
        return own.st_dev != parent.st_dev
    }

    /// Bytes deleting all of `files` frees: a pure-clone family's shared blocks count once, and only when every
    /// file holding them is among `files`. Clones that have since diverged are each counted in full.
    static func uniqueBytes(_ files: [ProviderUninstallFile]) -> Int64 {
        var total: Int64 = 0
        var families: [UInt64: (members: Int, references: UInt32, shared: Int64)] = [:]
        for file in files {
            guard let id = file.cloneID, let references = file.references, references > 1, let own = file.privateBytes else {
                total += file.allocated
                continue
            }
            total += own
            var family = families[id] ?? (0, references, 0)
            family.members += 1
            family.shared = max(family.shared, file.allocated - own)
            families[id] = family
        }
        return families.values.reduce(total) { $0 + ($1.members >= Int($1.references) ? $1.shared : 0) }
    }

    /// The deduplicated size of `items` together.
    public static func uniqueBytes(_ items: [ProviderUninstallItem]) -> Int64 {
        uniqueBytes(items.flatMap { $0.files.isEmpty ? [ProviderUninstallFile(allocated: $0.bytes)] : $0.files })
    }

    /// `ATTR_CMNEXT_PRIVATESIZE`, `_CLONEID` and `_CLONE_REFCNT`, when the volume returns all three (APFS).
    private static func cloneFacts(_ path: String, into file: inout ProviderUninstallFile) {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        let wanted = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE | ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_CLONE_REFCNT)
        request.forkattr = wanted
        var buffer = [UInt8](repeating: 0, count: 64)
        guard getattrlist(path, &request, &buffer, buffer.count, UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW)) == 0 else { return }
        buffer.withUnsafeBytes { raw in
            // u_int32_t length, attribute_set_t (five groups; forkattr last), then the values in bit order.
            guard raw.loadUnaligned(fromByteOffset: 20, as: attrgroup_t.self) & wanted == wanted else { return }
            file.privateBytes = raw.loadUnaligned(fromByteOffset: 24, as: Int64.self)
            file.cloneID = raw.loadUnaligned(fromByteOffset: 32, as: UInt64.self)
            file.references = raw.loadUnaligned(fromByteOffset: 40, as: UInt32.self)
        }
    }
}
