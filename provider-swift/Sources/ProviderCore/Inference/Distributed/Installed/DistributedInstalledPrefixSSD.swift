import Darwin
import Foundation

/// The SSD tier of the native rank's prompt-prefix cache, as this owner
/// configures it in the rank's environment. On by default, with the prefix
/// cache, under the product's cache settings (`ClusterPrefixCacheSettings`:
/// the saved cache directory or this user's caches, the product's prefix
/// cache gate, disk budget rule, daily write cap and TTL): records go under
/// `<cache base>/darkbloom/cluster-prefix-v1` (beside the product's own
/// `kv3` tier, which it never touches) and are encrypted and named with this
/// Mac's owner key, which outlives every owner process: an owner serves one
/// session (`cluster worker-owner --stdio`), and the records exist to warm the
/// next one. The key, in order:
///
/// 1. Derived from the product's Secure Enclave-rooted key (the single-Mac SSD
///    tier's key hierarchy, no new keychain item or permission) when the
///    `cluster worker-owner` command installed that source and it loads; it
///    is never written.
/// 2. Otherwise (a build without the keychain entitlement) a random key made
///    once in `~/.darkbloom/cluster-device/prefix-ssd-v1.key` (owner-only,
///    published once and never replaced), which this owner reads.
/// 3. If neither is possible, a random key of this owner process (records
///    then last one session; the next rank deletes what it cannot read).
///
/// Whichever it is, the rank receives the key bytes only as a line of its
/// input, bound to its epoch and rank (`ClusterWorkerPrefixSSDKey`, sent with
/// the data-plane credential), never in its environment or on its command
/// line: an environment is readable by every process of the same user for the
/// process's whole life. A worker built before this delivery is refused
/// (`DistributedInstalledWorkerFeatures.acceptsPrefixSSDKeyInput`), and a
/// current worker refuses a key in its environment.
///
/// The rank expires records after 30 minutes without use, the product SSD
/// tier's ceiling, and deletes every record a different key wrote.
///
/// `DARKBLOOM_CLUSTER_PREFIX_SSD=off` in this owner's environment turns the
/// tier off for diagnosis (the rank deletes what it kept);
/// `DARKBLOOM_CLUSTER_PREFIX_SSD_DIR` (absolute) moves the root; the rank's
/// budget switches (`..._MAX_GB`, `..._MAX_RECORDS`, `..._TTL_SECONDS`,
/// `..._STRIDE`, `..._MIN_TOKENS`, `..._MAX_WRITE_GB_PER_DAY`,
/// `..._MIN_FREE_GB`) pass through unchanged; the rank bounds each. The plan's
/// stop margin reaches the rank (`..._STOP_MARGIN_MS`) so the tier's close
/// before the model's release fits in the time this owner gives the release.
enum DistributedInstalledPrefixSSD {
    static let switchName = "DARKBLOOM_CLUSTER_PREFIX_SSD"
    static let directoryName = "DARKBLOOM_CLUSTER_PREFIX_SSD_DIR"
    static let keyFileBaseName = "prefix-ssd-v1.key"
    static let stopMarginName = "DARKBLOOM_CLUSTER_PREFIX_SSD_STOP_MARGIN_MS"
    static let passedThrough = ["MAX_GB", "MAX_RECORDS", "TTL_SECONDS", "STRIDE", "MIN_TOKENS",
                                "MAX_WRITE_GB_PER_DAY", "MIN_FREE_GB"].map { "DARKBLOOM_CLUSTER_PREFIX_SSD_" + $0 }

    /// Where this owner's key came from, with its 32 bytes. Descriptions
    /// redact the key.
    enum OwnerKey: Equatable, Sendable, CustomStringConvertible {
        /// Derived from the product's Secure Enclave-rooted key; never written.
        case derived(Data)
        /// Read from this Mac's owner-only key file.
        case file(URL, Data)
        /// This owner process's own random key, never written.
        case process(Data)

        var key: Data {
            switch self { case .derived(let key), .file(_, let key), .process(let key): key }
        }
        var description: String {
            switch self {
            case .derived: "derived(<redacted>)"
            case .file(let url, _): "file(\(url.lastPathComponent), <redacted>)"
            case .process: "process(<redacted>)"
            }
        }
    }

    /// Last resort: this owner process's key, random, never written.
    static let processKey: Data = decodeKeyText(Data(randomHex().utf8))!

    /// The built-in root (no pinned cache volume); `ClusterPrefixCacheSettings.root`.
    static func root(home: URL) -> URL { ClusterPrefixCacheSettings.defaultRoot(home: home) }

    /// The variables to add to the native rank's environment: the tier's
    /// directory, switch and budgets, never its key (`key`). Empty when the
    /// prefix cache itself is off (the rank then keeps nothing anywhere).
    /// The root, budget, write cap and TTL come from the product's settings
    /// (`settings`, installed once per owner by the `cluster worker-owner`
    /// command from the saved provider configuration and the product's
    /// switches; the built-in root otherwise); the cluster-only switches
    /// below are diagnosis overrides.
    static func environment(home: URL, deviceDirectory: URL, ownerEnvironment: [String: String], prefixCacheOff: Bool,
                            settings: ClusterPrefixCacheSettings? = nil,
                            stopMarginNanoseconds: UInt64? = nil) -> [String: String] {
        let product = settings ?? productSettings(home: home)
        guard !prefixCacheOff, product.prefixCacheEnabled else { return [:] }
        var directory = product.root.path
        if let value = ownerEnvironment[directoryName], value.hasPrefix("/"), value.utf8.count <= 1024,
           !value.split(separator: "/").contains("..") {
            directory = value
        }
        if let value = ownerEnvironment[switchName]?.lowercased(), ["off", "0", "false", "no"].contains(value) {
            return [switchName: "off", directoryName: directory]
        }
        var result = [directoryName: directory]
        result.merge(product.rankSwitches) { current, _ in current }
        if let margin = stopMarginNanoseconds {
            result[stopMarginName] = String(min(600_000, max(1_000, margin / 1_000_000)))
        }
        for name in passedThrough {
            if let value = ownerEnvironment[name], value.utf8.count <= 12, value.allSatisfy(\.isNumber) { result[name] = value }
        }
        return result
    }

    /// The 32-byte key the native rank receives on its input, exactly when
    /// `environment` configures the tier on (a directory and no off switch);
    /// nil otherwise, and the rank is then started without `--prefix-ssd-key`.
    static func key(home: URL, deviceDirectory: URL, ownerEnvironment: [String: String], prefixCacheOff: Bool,
                    settings: ClusterPrefixCacheSettings? = nil) -> Data? {
        let configured = environment(home: home, deviceDirectory: deviceDirectory, ownerEnvironment: ownerEnvironment,
            prefixCacheOff: prefixCacheOff, settings: settings)
        guard configured[directoryName] != nil, configured[switchName] == nil else { return nil }
        return ownerKey(deviceDirectory: deviceDirectory).key
    }

    // MARK: the product's settings

    /// Installed once by the `cluster worker-owner` command (and by the setup
    /// commands that need the root): the product's caching surface resolved
    /// for this Mac. Without it the built-in root with the rank's defaults.
    static func installProductSettings(_ value: ClusterPrefixCacheSettings?) {
        state.withLock { $0.product = value }
    }

    static func productSettings(home: URL) -> ClusterPrefixCacheSettings {
        state.withLock { $0.product } ?? .builtIn(home: home)
    }

    // MARK: the owner key

    /// Set once by the `cluster worker-owner` command: 32 bytes derived from
    /// the product's Secure Enclave-rooted key, or nil when it is unavailable.
    static func installDurableKeySource(_ source: @escaping @Sendable () -> Data?) {
        state.withLock { $0.source = source; $0.resolved = [:] }
    }

    /// This Mac's owner key for ranks whose device directory is
    /// `deviceDirectory`, resolved once per owner process (see the type).
    static func ownerKey(deviceDirectory: URL) -> OwnerKey {
        let path = deviceDirectory.path
        let (cached, source) = state.withLock { ($0.resolved[path], $0.source) }
        if let cached { return cached }
        let value: OwnerKey
        if let derived = source?(), derived.count == 32 {
            value = .derived(derived)
        } else if let (file, key) = readKeyFile(deviceDirectory: deviceDirectory) {
            value = .file(file, key)
        } else {
            value = .process(processKey)
        }
        return state.withLock { current in
            if let raced = current.resolved[path] { return raced }
            current.resolved[path] = value
            return value
        }
    }

    /// The owner-only key file under `deviceDirectory`, made once with a
    /// random key and never replaced (a different key would delete every
    /// record). Nil when it cannot be read or published safely.
    static func keyFile(deviceDirectory: URL) -> URL? { readKeyFile(deviceDirectory: deviceDirectory)?.url }

    /// `keyFile` with the key it holds (read through the same owner-only,
    /// no-follow checks).
    static func readKeyFile(deviceDirectory: URL) -> (url: URL, key: Data)? {
        guard let directory = try? ClusterConfigurationFiles.directory(deviceDirectory, create: true, privateMode: true) else {
            return nil
        }
        defer { Darwin.close(directory.descriptor) }
        let url = deviceDirectory.appendingPathComponent(keyFileBaseName)
        /// nil: no file; .some(nil): a file that is not a key.
        func existing() -> Data?? {
            guard let data = try? ClusterConfigurationFiles.readAt(directory, name: keyFileBaseName, maximum: 128,
                                                                    privateMode: true) else { return nil }
            return .some(decodeKeyText(data))
        }
        if let found = existing() { return found.map { (url, $0) } }
        let fresh = Data((randomHex() + "\n").utf8)
        if (try? ClusterConfigurationFiles.publish(fresh, parent: directory, name: keyFileBaseName, maximum: 128)) != nil {
            return decodeKeyText(fresh).map { (url, $0) }
        }
        // Another owner published first: use its key.
        if let found = existing(), let key = found { return (url, key) }
        return nil
    }

    /// 64 lowercase hex characters and an optional newline.
    static func isKeyText(_ data: Data) -> Bool {
        let bytes = data.last == 10 ? data.dropLast() : data[...]
        return bytes.count == 64 && bytes.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// The 32 bytes of a key text (`isKeyText`), or nil.
    static func decodeKeyText(_ data: Data) -> Data? {
        guard isKeyText(data) else { return nil }
        let digits = Array(data.prefix(64)).map { $0 <= 57 ? $0 - 48 : $0 - 87 }
        return Data(stride(from: 0, to: 64, by: 2).map { digits[$0] << 4 | digits[$0 + 1] })
    }

    static func randomHex() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
    }

    private struct State {
        var source: (@Sendable () -> Data?)?
        var resolved: [String: OwnerKey] = [:]
        var product: ClusterPrefixCacheSettings?
    }
    private static let state = DistributedInstalledPrefixSSDState(State())

    private final class DistributedInstalledPrefixSSDState: @unchecked Sendable {
        private let lock = NSLock()
        private var value: State
        init(_ value: State) { self.value = value }
        func withLock<T>(_ body: (inout State) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(&value) }
    }
}
