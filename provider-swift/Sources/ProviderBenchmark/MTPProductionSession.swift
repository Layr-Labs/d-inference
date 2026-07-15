import Foundation
import MLXLLM
import MLXLMCommon
import MLXVLM
import ProviderCore

/// Cache-only model bundle for MTP validation. It loads the target through the
/// same model factories as serving, resolves the exact VLM text model through
/// ProviderCore's production extraction seam, and loads/binds the real Gemma 4
/// assistant. It never downloads and never contains a decoder implementation.
public final class MTPProductionModelBundle: @unchecked Sendable {
    public let targetID: String
    public let assistantID: String
    public let targetDirectory: URL
    public let assistantDirectory: URL
    public let targetFacts: MTPBenchmarkArtifactFacts
    public let assistantFacts: MTPBenchmarkArtifactFacts

    private let container: ModelContainer
    private let servingModel: any LanguageModel
    private let tokenizer: any MLXLMCommon.Tokenizer
    private let eosTokenIDs: Set<Int>
    private let drafter: Gemma4CBv2MTPDrafter
    private let kvBytesCapacity: Int

    public var targetContainer: ModelContainer { container }
    /// Exact target EOS set captured from the same loaded configuration used
    /// to construct production sessions. Performance/correctness validation
    /// must pass this set to every request; raw parity deliberately passes none.
    public var productionStopTokenIDs: Set<Int> { eosTokenIDs }

    private init(
        targetID: String,
        assistantID: String,
        targetDirectory: URL,
        assistantDirectory: URL,
        targetFacts: MTPBenchmarkArtifactFacts,
        assistantFacts: MTPBenchmarkArtifactFacts,
        container: ModelContainer,
        servingModel: any LanguageModel,
        tokenizer: any MLXLMCommon.Tokenizer,
        eosTokenIDs: Set<Int>,
        drafter: Gemma4CBv2MTPDrafter,
        kvBytesCapacity: Int
    ) {
        self.targetID = targetID
        self.assistantID = assistantID
        self.targetDirectory = targetDirectory
        self.assistantDirectory = assistantDirectory
        self.targetFacts = targetFacts
        self.assistantFacts = assistantFacts
        self.container = container
        self.servingModel = servingModel
        self.tokenizer = tokenizer
        self.eosTokenIDs = eosTokenIDs
        self.drafter = drafter
        self.kvBytesCapacity = kvBytesCapacity
    }

    public static func load(
        targetID: String,
        targetDirectory: URL,
        assistantID: String,
        assistantDirectory: URL
    ) async throws -> MTPProductionModelBundle {
        let targetFacts = try MTPBenchmarkModelFacts.inspect(
            modelID: targetID, directory: targetDirectory)
        let assistantFacts = try MTPBenchmarkModelFacts.inspect(
            modelID: assistantID, directory: assistantDirectory)
        let isVLM = hasVisionConfig(directory: targetDirectory)
        let container: ModelContainer
        if isVLM {
            container = try await VLMModelFactory.shared.loadContainer(
                from: targetDirectory, using: LocalTokenizerLoader())
        } else {
            container = try await LLMModelFactory.shared.loadContainer(
                from: targetDirectory, using: LocalTokenizerLoader())
        }

        struct Snapshot: @unchecked Sendable {
            let model: any LanguageModel
            let tokenizer: any MLXLMCommon.Tokenizer
            let baseEOSTokenIDs: Set<Int>
            let tokenizerEOSTokenID: Int?
            let extraEOSTokens: [String]
            let weightBytes: Int
        }
        let snapshot = await container.perform { context -> Snapshot in
            let weightBytes = context.model.parameters().flattened().reduce(0) {
                $0 + $1.1.nbytes
            }
            return Snapshot(
                model: context.model,
                tokenizer: context.tokenizer,
                baseEOSTokenIDs: context.configuration.eosTokenIds,
                tokenizerEOSTokenID: context.tokenizer.eosTokenId,
                extraEOSTokens: context.configuration.extraEOSTokens.sorted(),
                weightBytes: weightBytes)
        }
        let eosTokenIDs = MTPBenchmarkProductionPolicy.stopTokenIDs(
            modelID: targetID,
            modelType: targetFacts.modelType,
            baseConfigTokenIDs: snapshot.baseEOSTokenIDs,
            tokenizerEOSTokenID: snapshot.tokenizerEOSTokenID,
            extraEOSTokens: snapshot.extraEOSTokens,
            convertTokenToID: { snapshot.tokenizer.convertTokenToId($0) })
        let servingModel = try EngineV2Factory.benchmarkServingModel(
            model: snapshot.model,
            isVLM: isVLM,
            modelDirectory: targetDirectory)
        guard let target = servingModel as? any Gemma4MTPTarget else {
            throw MTPBenchmarkError.mtpRequestedButInactive(
                "target model \(type(of: servingModel)) is not Gemma4MTPTarget")
        }
        let assistant = try await Gemma4AssistantDraftModel.load(from: assistantDirectory)
        let drafter = try Gemma4CBv2MTPDrafter(drafter: assistant, target: target)
        let residentWeightBytes = MTPBenchmarkSizing.totalResidentWeightBytes(
            targetWeightBytes: snapshot.weightBytes,
            assistant: assistantFacts)
        let kvBytesCapacity = Int(min(
            UnifiedMemoryCap.kvBudgetBytes(
                physicalBytes: ProcessInfo.processInfo.physicalMemory,
                residentWeightBytes: residentWeightBytes),
            UInt64(Int.max)))

        return MTPProductionModelBundle(
            targetID: targetID,
            assistantID: assistantID,
            targetDirectory: targetDirectory,
            assistantDirectory: assistantDirectory,
            targetFacts: targetFacts,
            assistantFacts: assistantFacts,
            container: container,
            servingModel: servingModel,
            tokenizer: snapshot.tokenizer,
            eosTokenIDs: eosTokenIDs,
            drafter: drafter,
            kvBytesCapacity: kvBytesCapacity)
    }

    public func tokenizeChat(name: String, userPrompt: String) throws -> MTPBenchmarkPrompt {
        let messages: [[String: any Sendable]] = [["role": "user", "content": userPrompt]]
        return try tokenize(name: name, messages: messages)
    }

    public func tokenize(
        name: String,
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]? = nil
    ) throws -> MTPBenchmarkPrompt {
        let tokens = try tokenizer.applyChatTemplate(
            messages: messages, tools: tools, additionalContext: nil)
        return MTPBenchmarkPrompt(name: name, tokenIDs: tokens)
    }

    public func makeSessionFactory() -> MTPBenchmarkSessionFactory {
        MTPBenchmarkSessionFactory { [self] mode, batchSize in
            try await self.makeSession(mode: mode, batchSize: batchSize)
        }
    }

    private func makeSession(
        mode: MTPBenchmarkMode,
        batchSize: Int
    ) async throws -> MTPBenchmarkSession {
        let verificationMode: CBv2MTPVerificationMode = {
            switch ProcessInfo.processInfo.environment["DARKBLOOM_MTP_VERIFICATION_MODE"] {
            case "rectangular": return .rectangular
            case "serial", "serial_target": return .serialTarget
            default: return .automatic
            }
        }()
        let automaticRectangularTokens = MTPAutomaticVerificationPolicy.maxRectangularTokens()
        let mtpDrafter: (any CBv2MTPDrafter)?
        let mtpConfig: CBv2MTPConfig
        switch mode.kind {
        case .targetOnly:
            mtpDrafter = nil
            mtpConfig = CBv2MTPConfig(enabled: false)
        case .fixed:
            guard let fixedDraftTokens = mode.fixedDraftTokens else {
                throw MTPBenchmarkError.invalidVerificationWidth(
                    mode.verificationWidth ?? -1)
            }
            mtpDrafter = drafter
            mtpConfig = CBv2MTPConfig(
                enabled: true,
                maxDraftTokens: CBv2MTPConfig.testedMaxDraftTokens,
                maxSpeculativeBatch: 8,
                fixedDraftTokens: fixedDraftTokens,
                verificationMode: verificationMode,
                maxAutomaticRectangularTokens: automaticRectangularTokens)
        case .adaptive:
            mtpDrafter = drafter
            mtpConfig = CBv2MTPConfig(
                enabled: true,
                maxDraftTokens: CBv2MTPConfig.testedMaxDraftTokens,
                maxSpeculativeBatch: 8,
                fixedDraftTokens: nil,
                verificationMode: verificationMode,
                maxAutomaticRectangularTokens: automaticRectangularTokens)
        }
        let engine = try EngineV2Factory.makeProductionEngine(
            model: servingModel,
            tokenizer: tokenizer,
            kvBytesCapacity: kvBytesCapacity,
            maxConcurrentRequests: batchSize,
            mtpDrafter: mtpDrafter,
            mtpConfig: mtpConfig,
            environment: [
                "DARKBLOOM_PREFIX_CACHE": "0",
            ])
        return MTPBenchmarkSession(engine: engine) {
            MTPBenchmarkEngineMetrics.snapshot(engine: engine)
        }
    }

    private static func hasVisionConfig(directory: URL) -> Bool {
        let config = directory.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: config),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return object["vision_config"] != nil
    }
}

public enum MTPBenchmarkProductionPolicy {
    /// Exact serving stop policy: loader config, model-family augmentation,
    /// tokenizer EOS, and every configuration extra converted by that same
    /// loaded tokenizer.
    public static func stopTokenIDs(
        modelID: String,
        modelType: String?,
        baseConfigTokenIDs: Set<Int>,
        tokenizerEOSTokenID: Int?,
        extraEOSTokens: [String],
        convertTokenToID: (String) -> Int?
    ) -> Set<Int> {
        var result = ModelEOSPolicy.effectiveEOSTokenIds(
            modelId: modelID,
            modelType: modelType,
            base: baseConfigTokenIDs,
            tokenToId: convertTokenToID)
        if let tokenizerEOSTokenID {
            result.insert(tokenizerEOSTokenID)
        }
        for token in extraEOSTokens {
            if let tokenID = convertTokenToID(token) {
                result.insert(tokenID)
            }
        }
        return result
    }
}
