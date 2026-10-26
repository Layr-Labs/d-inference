import Foundation

/// The pair's live KV precision from the product's own settings: the SAME
/// switch (`DARKBLOOM_CBV2_KV_QUANTIZATION`), saved per-model setting and
/// saved global setting (`engine_v2_kv_quantization`) the single-Mac engine
/// resolves, for the pair's public model ID, with main's default (native).
/// `cluster worker-owner` installs the resolver once per owner process from
/// the saved provider configuration (`installProduct`); the provider forwards
/// its own switch to the owner it starts (`ClusterLocalOwnerConfiguration`).
///
/// Each Mac's owner resolves its own and the ranks bind the value into their
/// load agreement, so a pair whose Macs resolved different precisions refuses
/// to load before either stage is read. A rank receives the resolved name only
/// when it is not native (the rank's default); a setting main would refuse
/// reaches the rank as a bounded name (`boundedName`) the rank refuses by name.
///
/// The pair's SSD prompt-prefix records follow the product's checkpoint
/// precision the same way: the switch (`DARKBLOOM_CBV2_CHECKPOINT_QUANTIZATION`,
/// forwarded to the owner like the live one), then
/// `engine_v2_kv_checkpoint_quantization_by_model`, then
/// `engine_v2_kv_checkpoint_quantization` (main's default, `balanced`). With an
/// installed resolver the rank always receives the resolved name
/// (`DARKBLOOM_CLUSTER_PREFIX_SSD_QUANTIZATION`, `recordsEnvironment`), which
/// both ranks bind into their load agreement; that variable in this owner's
/// own environment is a diagnosis override that wins, as the SSD tier's other
/// switches do. Without a resolver and an override the rank keeps its default
/// (`balanced`).
///
/// This file needs nothing but Foundation (the installed-session check runner
/// compiles it alone); the resolver from the product's policy types is
/// `DistributedInstalledKVQuantization.installProduct(...)` beside it.
public enum DistributedInstalledKVQuantization {
    static let switchName = "DARKBLOOM_CBV2_KV_QUANTIZATION"
    static let checkpointSwitchName = "DARKBLOOM_CBV2_CHECKPOINT_QUANTIZATION"
    /// The rank's wire switch for its SSD records (the runtime's
    /// `QwenStagePrefixDiskEncoding.environmentName`).
    static let recordsName = "DARKBLOOM_CLUSTER_PREFIX_SSD_QUANTIZATION"

    /// The live precision for one public model ID under one owner
    /// environment, nil for native. The records' resolver has the same shape
    /// and always names a precision.
    typealias Resolver = @Sendable (_ publicModelID: String, _ ownerEnvironment: [String: String]) -> String?

    static func install(_ resolver: Resolver?) {
        state.withLock { $0 = resolver }
    }

    static func installRecords(_ resolver: Resolver?) {
        recordsState.withLock { $0 = resolver }
    }

    /// The variable to add to the native rank's environment; empty for native
    /// or when no resolver was installed (the product's default).
    static func environment(publicModelID: String, ownerEnvironment: [String: String]) -> [String: String] {
        guard let value = state.withLock({ $0 })?(publicModelID, ownerEnvironment) else { return [:] }
        return [switchName: value]
    }

    /// The SSD records' precision for the native rank: this owner's override,
    /// else the installed resolver's name; empty when neither exists.
    static func recordsEnvironment(publicModelID: String, ownerEnvironment: [String: String]) -> [String: String] {
        if let raw = ownerEnvironment[recordsName] {
            return [recordsName: raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "balanced" : boundedName(raw)]
        }
        guard let value = recordsState.withLock({ $0 })?(publicModelID, ownerEnvironment) else { return [:] }
        return [recordsName: value]
    }

    /// The provider's own switch as it reaches the owner it starts, which
    /// resolves it like main: absent when unset, `native` when set empty (main's
    /// default for an empty switch), otherwise its bounded name.
    static func forwardedSwitch(_ environment: [String: String]) -> String? {
        guard let raw = environment[switchName] else { return nil }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "native" : boundedName(raw)
    }

    /// The provider's checkpoint switch as it reaches the owner it starts:
    /// absent when unset, `balanced` (main's checkpoint default) when set
    /// empty, otherwise its bounded name.
    static func forwardedCheckpointSwitch(_ environment: [String: String]) -> String? {
        guard let raw = environment[checkpointSwitchName] else { return nil }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "balanced" : boundedName(raw)
    }

    /// A value as main parses it (trimmed, lowercased) when that is a short
    /// lowercase ASCII name; anything else becomes `invalid`. Only such names
    /// cross the fixed owner and rank launches, and an invalid one is refused
    /// by the rank by name, never silently replaced by a saved setting.
    static func boundedName(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard (1...16).contains(value.utf8.count),
              value.utf8.allSatisfy({ (0x61...0x7a).contains($0) || (0x30...0x39).contains($0) }) else { return "invalid" }
        return value
    }

    private static let state = DistributedInstalledKVQuantizationState()
    private static let recordsState = DistributedInstalledKVQuantizationState()

    private final class DistributedInstalledKVQuantizationState: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Resolver?
        func withLock<T>(_ body: (inout Resolver?) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(&value) }
    }
}
