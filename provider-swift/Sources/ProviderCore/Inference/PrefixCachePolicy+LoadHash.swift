import Foundation
import MLXLLM

extension PrefixCachePolicy {
    /// Only a load that may construct reusable SSD state needs the two fresh
    /// content hashes around weight loading. Ask the Qwen configuration's own
    /// attention or complete-checkpoint capability before allocating weights;
    /// the loaded model delegates to these same properties. Dense Qwen requires
    /// the bracket for complete SSD checkpoints even when resident RAM is off.
    /// Other families and unreadable configurations retain
    /// the conservative full bracket.
    ///
    /// Used only by the standalone server's SSD-specific hashes. Connected
    /// ProviderLoop loading retains its existing fresh content-hash bracket and
    /// publication lifecycle for attestation, independently of this exclusion.
    ///
    /// This is an exclusion, never a grant of cache eligibility. Construction
    /// still checks the loaded model and resolved backend and requires a verified
    /// hash. If config changes after this probe, a missing bracket cannot enable
    /// SSD reuse. No observation is cached between loads.
    static func requiresLoadHashBracket(
        modelDirectory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard isEnabled(environment: environment) else { return false }
        guard let data = try? Data(contentsOf: modelDirectory.appendingPathComponent("config.json")),
            let declaration = try? JSONDecoder().decode(LoadModelDeclaration.self, from: data),
            ["qwen3_5", "qwen3_5_moe"].contains(declaration.modelType),
            let configuration = try? JSONDecoder().decode(MLXLLM.Qwen35Configuration.self, from: data)
        else { return true }
        let capabilities = configuration.cbv2Capabilities
        return capabilities.supportsPrefixReuse || capabilities.supportsRecurrentCheckpointReuse
    }
}

private struct LoadModelDeclaration: Decodable {
    let modelType: String
    enum CodingKeys: String, CodingKey { case modelType = "model_type" }
}
