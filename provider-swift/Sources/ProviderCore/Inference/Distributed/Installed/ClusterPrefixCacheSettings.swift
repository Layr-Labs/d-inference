import Darwin
import Foundation

/// The product's caching surface as it reaches the pair: the SAME saved
/// settings and switches the single-Mac SSD tier reads (`darkbloom cache set`,
/// `DARKBLOOM_PREFIX_CACHE`, `DARKBLOOM_PREFIX_CACHE_DISK_GB`, the TTL and
/// daily-write switches), resolved once per owner process into plain values
/// and mapped onto the rank's environment by `DistributedInstalledPrefixSSD`.
/// No cluster-only setting exists in the user path; the
/// `DARKBLOOM_CLUSTER_PREFIX_*` variables are the rank's wire and diagnosis
/// switches only.
///
/// This file needs nothing but Foundation (the installed-session check runner
/// compiles it alone); the resolver from the product's policy types is
/// `ClusterPrefixCacheSettings.product(...)` beside the SSD tier.
public struct ClusterPrefixCacheSettings: Equatable, Sendable {
    /// Where every rank on this Mac keeps its records: the product's cache
    /// base (the chosen cache volume or this user's caches) plus
    /// `darkbloom/cluster-prefix-v1`, beside the single-Mac `kv3` tier.
    public var root: URL
    /// The product's prefix-cache gate: off turns the pair's prefix cache and
    /// its SSD tier off (the rank keeps nothing anywhere).
    public var prefixCacheEnabled: Bool
    /// Per-rank byte budget on disk (the product's box-wide rule: the env
    /// override, else half the free space); nil keeps the rank's default.
    public var byteBudget: Int?
    /// The rolling-day write cap in bytes (0 = unlimited); nil keeps the
    /// rank's default (the product's 750 GB).
    public var dailyWriteBytes: Int?
    /// The sliding TTL in seconds (the product's 1,800 ceiling); nil keeps
    /// the rank's default (1,800).
    public var ttlSeconds: Int?

    public init(root: URL, prefixCacheEnabled: Bool = true, byteBudget: Int? = nil, dailyWriteBytes: Int? = nil,
                ttlSeconds: Int? = nil) {
        self.root = root; self.prefixCacheEnabled = prefixCacheEnabled; self.byteBudget = byteBudget
        self.dailyWriteBytes = dailyWriteBytes; self.ttlSeconds = ttlSeconds
    }

    public static let rootDirectoryName = "darkbloom/cluster-prefix-v1"

    /// The root under a cache base directory (`~/Library/Caches` by default,
    /// or the directory `darkbloom cache set --directory` pinned).
    public static func root(cacheBase: URL) -> URL {
        cacheBase.appendingPathComponent(rootDirectoryName, isDirectory: true)
    }

    /// The built-in root for `home` (no pinned cache volume).
    /// The rank writes a record under `<root>/staging/<membership epoch>/` and
    /// renames it into place (the runtime's `QwenStagePrefixDiskTier`
    /// `stagingDirectoryName`); the orphan reaper sweeps dead epochs there.
    public static let stagingDirectoryName = "staging"
    public static func stagingRoot(root: URL) -> URL { root.appendingPathComponent(stagingDirectoryName, isDirectory: true) }

    public static func defaultRoot(home: URL) -> URL {
        root(cacheBase: home.appendingPathComponent("Library/Caches", isDirectory: true))
    }

    /// Settings with nothing resolved beyond the built-in root (an owner
    /// that installed no product settings behaves as the ssd branch did).
    public static func builtIn(home: URL) -> Self { .init(root: defaultRoot(home: home)) }

    /// The rank's switches for these settings: the values the owner adds to
    /// the native environment besides the directory and the key.
    var rankSwitches: [String: String] {
        var result: [String: String] = [:]
        if let byteBudget {
            // The rank takes whole GiB, at least one: a budget below that is one.
            result["DARKBLOOM_CLUSTER_PREFIX_SSD_MAX_GB"] = String(min(16_384, max(1, byteBudget / 1_073_741_824)))
        }
        if let dailyWriteBytes {
            // Decimal GB as the product counts them; 0 stays 0 (unlimited), a
            // positive cap below one GB rounds up to one.
            let gb = dailyWriteBytes <= 0 ? 0 : max(1, (dailyWriteBytes + 999_999_999) / 1_000_000_000)
            result["DARKBLOOM_CLUSTER_PREFIX_SSD_MAX_WRITE_GB_PER_DAY"] = String(min(1_000_000, gb))
        }
        if let ttlSeconds, ttlSeconds > 0 {
            result["DARKBLOOM_CLUSTER_PREFIX_SSD_TTL_SECONDS"] = String(min(1_800, ttlSeconds))
        }
        return result
    }
}

/// The cache settings the LEADER sends every member when it syncs the
/// configuration (ONBOARDING UX: the leader chooses the options, syncs them,
/// starts the members). Only values that must agree across the pair travel:
/// the member's root stays its own (its cache volume is its own choice).
/// Versioned; a member refuses a version it does not know.
public struct ClusterCacheSettingsSync: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version: Int
    public var prefixCacheEnabled: Bool
    /// Decimal GB per rolling day; nil = the member's own saved/default.
    public var dailyWriteGB: Double?
    /// GiB per rank on disk; nil = the member's own rule (half its free space).
    public var diskBudgetGB: Double?
    public var ttlSeconds: Int?

    public init(prefixCacheEnabled: Bool, dailyWriteGB: Double? = nil, diskBudgetGB: Double? = nil, ttlSeconds: Int? = nil) {
        version = Self.currentVersion
        self.prefixCacheEnabled = prefixCacheEnabled; self.dailyWriteGB = dailyWriteGB
        self.diskBudgetGB = diskBudgetGB; self.ttlSeconds = ttlSeconds
    }

    enum CodingKeys: String, CodingKey {
        case version, prefixCacheEnabled = "prefix_cache_enabled", dailyWriteGB = "daily_write_gb",
             diskBudgetGB = "disk_budget_gb", ttlSeconds = "ttl_seconds"
    }

    /// What the leader derives from its own resolved settings.
    public init(leader: ClusterPrefixCacheSettings) {
        self.init(prefixCacheEnabled: leader.prefixCacheEnabled,
                  dailyWriteGB: leader.dailyWriteBytes.map { Double($0) / 1_000_000_000 },
                  diskBudgetGB: leader.byteBudget.map { Double($0) / 1_073_741_824 },
                  ttlSeconds: leader.ttlSeconds)
    }

    /// The member's settings with the leader's choices applied. The root is
    /// never taken from the wire. Throws on an unknown version or a value
    /// outside the product's bounds (fail closed: the member keeps its own).
    public func applied(to member: ClusterPrefixCacheSettings) throws -> ClusterPrefixCacheSettings {
        guard version == Self.currentVersion else {
            throw ClusterCacheSettingsSyncError("Cache settings sync version \(version) is not this build's \(Self.currentVersion)")
        }
        var result = member
        result.prefixCacheEnabled = prefixCacheEnabled
        if let dailyWriteGB {
            guard dailyWriteGB.isFinite, dailyWriteGB >= 0, dailyWriteGB < 1_000_000 else {
                throw ClusterCacheSettingsSyncError("Synced daily write limit is out of bounds")
            }
            result.dailyWriteBytes = Int(dailyWriteGB * 1_000_000_000)
        }
        if let diskBudgetGB {
            guard diskBudgetGB.isFinite, diskBudgetGB > 0, diskBudgetGB <= 16_384 else {
                throw ClusterCacheSettingsSyncError("Synced disk budget is out of bounds")
            }
            result.byteBudget = Int(diskBudgetGB * 1_073_741_824)
        }
        if let ttlSeconds {
            guard (1...1_800).contains(ttlSeconds) else { throw ClusterCacheSettingsSyncError("Synced TTL is out of bounds") }
            result.ttlSeconds = ttlSeconds
        }
        return result
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 4_096 else { throw ClusterCacheSettingsSyncError("Cache settings sync is too long") }
        return try JSONDecoder().decode(Self.self, from: data)
    }
}

public struct ClusterCacheSettingsSyncError: Error, CustomStringConvertible, Equatable {
    public let description: String
    init(_ description: String) { self.description = description }
}

/// What the pair's SSD tier holds on this Mac, for `darkbloom cache status`
/// and the doctor: read-only, counts only the names the tier makes
/// (`v1-<24 hex>/rank<n>/<32 hex>.dbpx`), never opens a record.
public struct ClusterPrefixSSDInspection: Equatable, Sendable, Encodable {
    public struct Rank: Equatable, Sendable, Encodable {
        public let plan: String
        public let rank: Int
        public let records: Int
        public let bytes: Int
    }
    public let root: String
    public let present: Bool
    public let plans: Int
    public let ranks: [Rank]
    public var records: Int { ranks.reduce(0) { $0 + $1.records } }
    public var bytes: Int { ranks.reduce(0) { $0 + $1.bytes } }

    public static func inspect(root: URL) -> Self {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .init(root: root.path, present: false, plans: 0, ranks: [])
        }
        var plans = 0, ranks: [Rank] = []
        for plan in ((try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []).sorted() where isPlanDirectoryName(plan) {
            plans += 1
            let planURL = root.appendingPathComponent(plan, isDirectory: true)
            for name in ((try? fileManager.contentsOfDirectory(atPath: planURL.path)) ?? []).sorted() {
                guard name.hasPrefix("rank"), let rank = Int(name.dropFirst(4)), rank >= 0 else { continue }
                let directory = planURL.appendingPathComponent(name, isDirectory: true)
                var records = 0, bytes = 0
                for file in (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [] where isRecordName(file) {
                    var info = stat()
                    guard lstat(directory.appendingPathComponent(file).path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
                    records += 1; bytes += Int(info.st_size)
                }
                ranks.append(.init(plan: String(plan.dropFirst(3).prefix(12)), rank: rank, records: records, bytes: bytes))
            }
        }
        return .init(root: root.path, present: true, plans: plans, ranks: ranks)
    }

    static func isPlanDirectoryName(_ name: String) -> Bool {
        name.hasPrefix("v1-") && name.utf8.count == 27 && name.dropFirst(3).allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    static func isRecordName(_ name: String) -> Bool {
        name.hasSuffix(".dbpx") && name.utf8.count == 37 && name.dropLast(5).allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// One line for the status output.
    public var line: String {
        guard present else { return "Cluster prefix tier: none yet (\(root))" }
        let gb = String(format: "%.2f", Double(bytes) / 1_000_000_000)
        return "Cluster prefix tier: \(plans) plan\(plans == 1 ? "" : "s"), \(records) record\(records == 1 ? "" : "s"), \(gb) GB (\(root))"
    }
}

/// Reclaim: when this Mac leaves the pair (unpair, link removal, member
/// uninstall) no rank will ever open its records again, so they are dead
/// weight (oMLX `8910605b`: a deleted deployment's snapshots are reclaimed
/// on every rank). Removes only the plan directories the tier makes, and
/// never one a live rank holds (its `in-use` lock), then the root itself
/// when nothing is left. Best effort: failures are reported, never thrown.
public enum ClusterPrefixSSDReclaim {
    public struct Report: Equatable, Sendable {
        public var removedPlans = 0
        public var keptLive = 0
        public var rootRemoved = false
        public var problems: [String] = []
    }

    public static func reclaim(root: URL) -> Report {
        var report = Report()
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else { return report }
        let names = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        for name in names where ClusterPrefixSSDInspection.isPlanDirectoryName(name) {
            let plan = root.appendingPathComponent(name, isDirectory: true)
            let lock = Darwin.open(plan.appendingPathComponent("in-use").path, O_RDONLY | O_NOFOLLOW)
            if lock >= 0 {
                defer { Darwin.close(lock) }
                guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { report.keptLive += 1; continue }
            }
            do { try fileManager.removeItem(at: plan); report.removedPlans += 1 }
            catch { report.problems.append("\(name): \(error.localizedDescription)") }
        }
        // No rank is live here: nothing is being staged, so the staging root goes too.
        let staging = ClusterPrefixCacheSettings.stagingRoot(root: root)
        if report.keptLive == 0, fileManager.fileExists(atPath: staging.path) {
            do { try fileManager.removeItem(at: staging) }
            catch { report.problems.append("staging: \(error.localizedDescription)") }
        }
        if report.keptLive == 0, ((try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []).isEmpty,
           (try? fileManager.removeItem(at: root)) != nil {
            report.rootRemoved = true
        }
        return report
    }
}
