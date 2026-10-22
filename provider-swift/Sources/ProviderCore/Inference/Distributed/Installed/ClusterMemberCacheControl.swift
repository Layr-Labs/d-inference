import CryptoKit
import Darwin
import Foundation

/// The leader's control of its members' pair cache, over the link control
/// channel (the cluster service's command channel, keyed by the pairing's
/// edge secret: only the paired Mac is answered, and a member takes these
/// commands only from the leader it pinned when it joined).
///
/// - **Cache settings sync** (ONBOARDING UX: the leader chooses the options
///   and syncs them to its members). The leader sends its own choices
///   (`ClusterCacheSettingsSync`: prefix cache on/off, daily write cap, an
///   explicit disk budget, TTL) whenever a member's status reports another
///   digest. The member validates them against its own settings (the root,
///   its cache volume, never travels), keeps them owner-only beside its setup
///   record, and its owner applies them to every rank it starts
///   (`effective`). Anything invalid leaves the member on its own settings.
/// - **Reclaim on unpair** (oMLX `8910605b`, a deleted deployment's records
///   reclaimed on every rank). When the leader leaves the pair it tells the
///   member first; the member removes the pair's plan directories under its
///   cluster prefix root (`<cache base>/darkbloom/cluster-prefix-v1`; only the
///   current pair's plans are there: every rank deletes other plans'
///   directories at load) and forgets the leader's settings. The single-Mac
///   `kv3` tier is a different directory and is never touched. A plan a
///   running rank still holds is kept and reclaimed once that rank ended.
public enum ClusterMemberCacheControl {
    public static let syncFileName = "cache-sync.json"
    public static let reclaimPendingFileName = "cluster-prefix-reclaim.pending"
    static let maximumBytes = 8_192

    /// What a member keeps: the settings and the leader that sent them.
    public struct Stored: Codable, Equatable, Sendable {
        public var leaderPin: String
        public var sync: ClusterCacheSettingsSync
        public init(leaderPin: String, sync: ClusterCacheSettingsSync) { self.leaderPin = leaderPin; self.sync = sync }
        enum CodingKeys: String, CodingKey { case leaderPin = "leader_pin", sync }
    }

    /// The member's answer to `unpair`.
    public struct UnpairReply: Codable, Equatable, Sendable {
        public var removedPlans: Int
        public var keptLive: Int
        public var rootRemoved: Bool
        public var settingsForgotten: Bool
        public var problems: [String]
    }

    public struct Refusal: Error, CustomStringConvertible, Equatable {
        public let description: String
        init(_ description: String) { self.description = description }
    }

    /// Lowercase hex SHA-256 of the settings' canonical encoding.
    public static func digest(_ sync: ClusterCacheSettingsSync) -> String {
        let bytes = (try? sync.encoded()) ?? Data()
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// Leader: the settings to send, nil when the member already applied them.
    public static func settingsToSend(leader: ClusterCacheSettingsSync, memberDigest: String?) -> ClusterCacheSettingsSync? {
        memberDigest == digest(leader) ? nil : leader
    }

    // MARK: - The member's store

    public struct Store: Sendable {
        public let directory: URL
        public init(directory: URL) { self.directory = directory }
        var file: URL { directory.appendingPathComponent(ClusterMemberCacheControl.syncFileName) }
        var pendingFile: URL { directory.appendingPathComponent(ClusterMemberCacheControl.reclaimPendingFileName) }

        /// The leader's settings when `leaderPin` sent them, else nil (another
        /// leader's, an unknown version, an unreadable or unsafe file).
        public func load(leaderPin: String) -> ClusterCacheSettingsSync? {
            guard let data = try? ClusterConfigurationFiles.read(file, maximum: ClusterMemberCacheControl.maximumBytes, privateMode: true),
                  let stored = try? JSONDecoder().decode(Stored.self, from: data),
                  stored.leaderPin == leaderPin, stored.sync.version == ClusterCacheSettingsSync.currentVersion else { return nil }
            return stored.sync
        }

        public func digest(leaderPin: String) -> String? { load(leaderPin: leaderPin).map(ClusterMemberCacheControl.digest) }

        func save(_ stored: Stored) throws {
            try ClusterConfigurationFiles.ensureDirectory(directory, create: true, privateMode: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(stored)
            try ClusterConfigurationFiles.update(file, maximum: ClusterMemberCacheControl.maximumBytes) { _ in data }
        }

        /// Forgets the leader's settings; true when there were any.
        @discardableResult
        public func remove() -> Bool { unlink(file.path) == 0 }

        public var reclaimPending: Bool { FileManager.default.fileExists(atPath: pendingFile.path) }

        func setReclaimPending(_ pending: Bool) {
            if pending {
                try? ClusterConfigurationFiles.ensureDirectory(directory, create: true, privateMode: true)
                _ = try? ClusterConfigurationFiles.update(pendingFile, maximum: 64) { _ in Data("1\n".utf8) }
            } else {
                unlink(pendingFile.path)
            }
        }
    }

    // MARK: - The member

    /// Applies the leader's settings: validated against this Mac's own (the
    /// root never travels), then kept for the owner. Returns their digest.
    public static func applyOnMember(_ sync: ClusterCacheSettingsSync, leaderPin: String,
                                     memberSettings: ClusterPrefixCacheSettings, store: Store) throws -> String {
        _ = try sync.applied(to: memberSettings)
        try store.save(.init(leaderPin: leaderPin, sync: sync))
        return digest(sync)
    }

    /// The leader left the pair: reclaim its records here and forget its settings.
    public static func reclaimOnUnpair(root: URL, store: Store) -> UnpairReply {
        let forgotten = store.remove()
        let report = ClusterPrefixSSDReclaim.reclaim(root: root)
        store.setReclaimPending(report.keptLive > 0)
        return UnpairReply(removedPlans: report.removedPlans, keptLive: report.keptLive, rootRemoved: report.rootRemoved,
                           settingsForgotten: forgotten, problems: report.problems)
    }

    /// Finishes a reclaim that found a live rank, once no rank holds a plan.
    /// Nil when nothing was pending.
    public static func finishPendingReclaim(root: URL, store: Store) -> ClusterPrefixSSDReclaim.Report? {
        guard store.reclaimPending else { return nil }
        let report = ClusterPrefixSSDReclaim.reclaim(root: root)
        if report.keptLive == 0 { store.setReclaimPending(false) }
        return report
    }

    /// The settings a member's owner gives its rank: its own, with the
    /// leader's choices applied when this Mac follows that leader. Its own on
    /// any problem (fail closed).
    public static func effective(own: ClusterPrefixCacheSettings, store: Store, followedLeaderPin: String?) -> ClusterPrefixCacheSettings {
        guard let followedLeaderPin, let sync = store.load(leaderPin: followedLeaderPin),
              let applied = try? sync.applied(to: own) else { return own }
        return applied
    }

    /// A member's handling of the two cache commands; nil for any other
    /// operation. `follows`: this Mac follows the Mac that asked (the link
    /// channel already proved it is the paired Mac). The reply is what the
    /// command channel returns.
    public static func handle(_ command: ClusterServiceCommand, follows: Bool, leaderPin: String, pairClusterID: String,
                              memberSettings: () throws -> ClusterPrefixCacheSettings, store: Store,
                              status: () -> ClusterServiceStatus) throws -> Data? {
        switch command.op {
        case .cacheSettings:
            guard follows else { throw Refusal("this Mac does not follow the Mac that asked") }
            guard let sync = command.cache else { throw Refusal("the cache settings command carries no settings") }
            _ = try applyOnMember(sync, leaderPin: leaderPin, memberSettings: try memberSettings(), store: store)
            return try JSONEncoder().encode(status())
        case .unpair:
            guard follows else { throw Refusal("this Mac does not follow the Mac that asked") }
            guard command.clusterID == pairClusterID else { throw Refusal("the unpair names another cluster") }
            return try JSONEncoder().encode(reclaimOnUnpair(root: try memberSettings().root, store: store))
        default:
            return nil
        }
    }
}
