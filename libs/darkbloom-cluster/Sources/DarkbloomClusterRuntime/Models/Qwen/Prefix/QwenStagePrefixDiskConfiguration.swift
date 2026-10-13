import Foundation

/// How the SSD tier of a rank's prompt-prefix cache is configured: the
/// directory and budgets from the worker's environment, the key from the
/// worker's input. The installed owner sets the directory and sends the key;
/// without both the tier is off (fail closed: no prompt state is ever written
/// to disk unencrypted).
///
/// - `DARKBLOOM_CLUSTER_PREFIX_SSD_DIR`: the root directory (absolute path).
/// - The key: 32 bytes the owner sends as a bound line of the worker's control
///   pipe (`--prefix-ssd-key`, `ClusterWorkerPrefixSSDKey`), handed to the load
///   in-process. It is never read from the environment or from a file: an
///   environment is readable by every process of the same user for the
///   process's whole life. The key encrypts and names every record; a
///   different key makes every record unreadable, and the rank deletes them.
/// - `DARKBLOOM_CLUSTER_PREFIX_SSD=off`: diagnosis; the rank keeps nothing on
///   disk and deletes what it kept before under the root.
/// - Budgets: `..._MAX_RECORDS` (records per rank, 64), `..._MAX_GB` (bytes per
///   rank, 16), `..._TTL_SECONDS` (sliding, 1,800 maximum and default, as the
///   product's SSD tier), `..._STRIDE` (grid of persisted frontiers, 2,048
///   tokens), `..._MIN_TOKENS` (shortest prompt worth a record, 1,024),
///   `..._MAX_WRITE_GB_PER_DAY` (750, the product's endurance cap),
///   `..._MIN_FREE_GB` (writes stop below this much free space, 20).
/// - `..._STOP_MARGIN_MS`: the plan's stop margin, which the installed owner
///   passes so the close before the model's release fits in it
///   (`QwenStagePrefixDiskPolicy.closeBounds`).
///
/// The write-behind byte bound is derived from this Mac's memory
/// (`QwenStagePrefixDiskPolicy.queuedBytesBound`). This file needs nothing
/// but Foundation, the runtime's error type and the disk policy.
public struct QwenStagePrefixDiskConfiguration: Equatable, Sendable {
    public static let directoryEnvironmentName = "DARKBLOOM_CLUSTER_PREFIX_SSD_DIR"
    public static let switchEnvironmentName = "DARKBLOOM_CLUSTER_PREFIX_SSD"
    public static let maximumTTLSeconds = 1_800

    public enum Mode: Equatable, Sendable {
        /// Records are kept under `root` with this key.
        case on(root: URL, key: Data)
        /// No disk tier. With a root, everything this tier kept there before
        /// is deleted at load (the switch is off, or no usable key was given).
        case off(sweepRoot: URL?, reason: String)
    }

    public let mode: Mode
    public var recordLimit = 64
    public var byteBudget = 16 * 1_073_741_824
    public var ttlSeconds = QwenStagePrefixDiskConfiguration.maximumTTLSeconds
    public var strideTokens = 2048
    public var minimumTokens = 1024
    public var maximumWriteBytesPerDay = 750 * 1_000_000_000
    public var minimumFreeBytes = 20 * 1_073_741_824
    /// Write-behind bounds: jobs and host-visible bytes queued behind the
    /// writer. A persist beyond either is dropped; serving never waits.
    public var maximumQueuedJobs = 2
    public var maximumQueuedBytes = QwenStagePrefixDiskPolicy.queuedBytesBound(physicalBytes: ProcessInfo.processInfo.physicalMemory)
    /// The close before the model's release (`QwenStagePrefixDiskPolicy.closeBounds`).
    public var closeBounds = QwenStagePrefixDiskPolicy.closeBounds(stopMarginMilliseconds: nil)

    public init(mode: Mode) { self.mode = mode }

    public var enabled: Bool { if case .on = mode { return true }; return false }

    /// `key` is the 32-byte key the worker received on its input, or nil.
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment,
                                       key suppliedKey: Data?) -> Self {
        let root = environment[directoryEnvironmentName].flatMap { value -> URL? in
            guard value.hasPrefix("/"), value.utf8.count <= 1024, !value.split(separator: "/").contains("..") else { return nil }
            return URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
        }
        let switchValue = environment[switchEnvironmentName]?.lowercased()
        if let switchValue, ["off", "0", "false", "no"].contains(switchValue) {
            return Self(mode: .off(sweepRoot: root, reason: "switched off"))
        }
        guard let root else { return Self(mode: .off(sweepRoot: nil, reason: "no directory")) }
        guard let key = suppliedKey, key.count == 32 else { return Self(mode: .off(sweepRoot: root, reason: "no usable key")) }
        var value = Self(mode: .on(root: root, key: key))
        func integer(_ suffix: String, _ range: ClosedRange<Int>) -> Int? {
            guard let text = environment["DARKBLOOM_CLUSTER_PREFIX_SSD_" + suffix], let number = Int(text),
                  range.contains(number) else { return nil }
            return number
        }
        if let n = integer("MAX_RECORDS", 1...4096) { value.recordLimit = n }
        if let n = integer("MAX_GB", 1...16_384) { value.byteBudget = n * 1_073_741_824 }
        // The TTL can only be shortened, as the product's.
        if let n = integer("TTL_SECONDS", 1...maximumTTLSeconds) { value.ttlSeconds = n }
        if let n = integer("STRIDE", 1...1_048_576) { value.strideTokens = n }
        if let n = integer("MIN_TOKENS", 1...1_048_576) { value.minimumTokens = n }
        if let n = integer("MAX_WRITE_GB_PER_DAY", 0...1_000_000) {
            value.maximumWriteBytesPerDay = n == 0 ? Int.max : n * 1_000_000_000
        }
        if let n = integer("MIN_FREE_GB", 1...16_384) { value.minimumFreeBytes = n * 1_073_741_824 }
        if let n = integer("STOP_MARGIN_MS", 1_000...600_000) {
            value.closeBounds = QwenStagePrefixDiskPolicy.closeBounds(stopMarginMilliseconds: n)
        }
        return value
    }
}
