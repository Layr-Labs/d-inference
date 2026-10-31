import Foundation
import ProviderCoreFoundation
import DarkbloomClusterProtocol

/// Verified metadata for tokenizer-only registry construction. The server must
/// recheck session.validateModelInputs() before and after loading its tokenizer.
public struct DistributedInstalledModel: Sendable {
    public let publicModelID: String
    public let directory: URL
    public let modelType: String
    public let eosTokenIDs: Set<Int>
    public let vocabularySize: Int

    static func make(configurationData: Data, manifest: ModelManifest,
                     plan: DistributedInstalledPlan) throws -> Self {
        guard ClusterConfigurationCodec.sha256(configurationData) == plan.capability.configurationSHA256 else {
            throw ClusterConfigurationError.invalid("Tokenizer model configuration differs")
        }
        let raw = try JSONDecoder().decode(Configuration.self, from: configurationData)
        let metadata = raw.text_config ?? raw.generation
        guard !raw.model_type.isEmpty, raw.model_type.utf8.count <= 128,
              metadata.vocab_size == plan.capability.profile.vocabularySize,
              let eos = metadata.eos_token_id, !eos.values.isEmpty, eos.values.count <= 16,
              Set(eos.values).count == eos.values.count,
              eos.values.allSatisfy({ 0 <= $0 && $0 < plan.capability.profile.vocabularySize }) else {
            throw ClusterConfigurationError.invalid("Pinned model type, EOS or vocabulary is unsupported")
        }
        let paths = Set(plan.configuration.tokenizerFiles.map(\.path))
        guard paths.contains("tokenizer.json"), paths.contains("tokenizer_config.json"),
              paths.contains("chat_template.jinja") || paths.contains("chat_template.json") else {
            throw ClusterConfigurationError.invalid("Installed text serving requires pinned local tokenizer and chat template")
        }
        return .init(publicModelID: manifest.modelID, directory: URL(fileURLWithPath: plan.localPeer.modelDirectory),
            modelType: raw.model_type, eosTokenIDs: Set(eos.values), vocabularySize: plan.capability.profile.vocabularySize)
    }

    /// LocalTokenizerLoader's verified tokenizer may expose an additional EOS.
    /// The caller supplies only that loaded tokenizer's conversion, not a wire value.
    public func stopTokenIDs(tokenizerEOS: Int?) throws -> Set<Int> {
        var result = eosTokenIDs
        if let tokenizerEOS {
            guard (0..<vocabularySize).contains(tokenizerEOS) else {
                throw ClusterConfigurationError.invalid("Loaded tokenizer EOS exceeds the native vocabulary")
            }
            result.insert(tokenizerEOS)
        }
        return result
    }

    private struct Configuration: Decodable {
        let model_type: String
        let text_config: Generation?
        let generation: Generation
        private enum CodingKeys: String, CodingKey { case model_type, text_config }
        init(from decoder: Decoder) throws {
            let object = try decoder.container(keyedBy: CodingKeys.self)
            model_type = try object.decode(String.self, forKey: .model_type)
            text_config = try object.decodeIfPresent(Generation.self, forKey: .text_config)
            generation = try Generation(from: decoder)
        }
    }
    private struct Generation: Decodable { let eos_token_id: IDs?; let vocab_size: Int? }
    private struct IDs: Decodable {
        let values: [Int]
        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let scalar = try? value.decode(Int.self) { values = [scalar] }
            else { values = try value.decode([Int].self) }
        }
    }
}
