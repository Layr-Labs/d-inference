// Copyright © 2026 Eigen Labs.
//
// The recurrent checkpoint bank on paged KV: which artifacts a paged backend
// may host it for, its budget, and the SSD checkpoints the slot serves
// otherwise. The slot tests build real tiny Qwen engines on empty segmented
// storage and run no forward pass.

import Foundation
import MLX
import MLXLLM
import Testing

@testable import MLXLMCommon
@testable import ProviderCore

private let qualifiedID = "Qwen3.5-9B"
private let qualifiedType = "qwen3_5"
private let gib = 1 << 30
private let bankBytesKey = "DARKBLOOM_CBV2_HYBRID_PREFIX_BYTES"

@Suite("PagedRecurrentBankPolicy")
struct PagedRecurrentBankPolicyTests {
    private func config(
        modelId: String = qualifiedID, modelType: String? = qualifiedType,
        contract: String? = "contract", capacity: Int = 16 * gib,
        mtp: Bool = false, exact: Bool = false, environment: [String: String] = [:]
    ) -> CBv2HybridPrefixCacheConfig? {
        PagedRecurrentBankPolicy.config(
            modelId: modelId, modelType: modelType, promptContractID: contract,
            kvBytesCapacity: capacity, hasMTPDrafter: mtp, supportsMTPPrefixCheckpoint: exact,
            environment: [PrefixCachePolicy.memoryEnvironmentFlag: "1"]
                .merging(environment) { _, new in new })
    }

    @Test("only the exact measured artifact qualifies")
    func qualifiedArtifact() {
        #expect(PagedRecurrentBankPolicy.artifact(modelId: qualifiedID, modelType: qualifiedType) != nil)
        #expect(PagedRecurrentBankPolicy.artifact(modelId: qualifiedID, modelType: " Qwen3_5\n") != nil)
        let others: [(String, String?)] = [
            (qualifiedID, "qwen3_5_moe"), (qualifiedID, nil), ("qwen3.5-9b", qualifiedType),
            ("qwen3.5-35b-a3b", "qwen3_5_moe"), ("EigenLabs/Qwen3.8-27B-4bit-mtp", qualifiedType),
        ]
        for (id, type) in others {
            #expect(config(modelId: id, modelType: type) == nil, "\(id) as \(type ?? "nil")")
        }
    }

    @Test("default budget: a quarter of the grant in 256 MiB steps, from 1 GiB to the measured size")
    func defaultBudget() throws {
        let artifact = try #require(
            PagedRecurrentBankPolicy.artifact(modelId: qualifiedID, modelType: qualifiedType))
        let rows = [
            (-1, 0), (0, 0), (4 * gib - 1, 0), (4 * gib, gib), (6 * gib - 1, gib + (256 << 20)),
            (16 * gib, 4 * gib), (64 * gib, 4 * gib),
        ]
        for (capacity, expected) in rows {
            #expect(
                PagedRecurrentBankPolicy.defaultBytes(for: artifact, kvBytesCapacity: capacity) == expected,
                "grant \(capacity)")
        }
    }

    @Test("the bank stays behind the memory opt-in, the kill switches and the assistant gate")
    func gates() {
        let bank = config()
        #expect(bank?.permitsPagedStorage == true)
        #expect(bank?.maximumBytes == 4 * gib)
        #expect(bank?.modelID == qualifiedID)
        #expect(bank?.promptContractID == "contract")
        #expect(config(capacity: 4 * gib)?.maximumBytes == gib)
        // Under 1 GiB the slot keeps its SSD checkpoints instead.
        #expect(config(capacity: 4 * gib - 1) == nil)
        #expect(config(contract: nil) == nil)
        #expect(config(mtp: true) == nil)
        #expect(config(mtp: true, exact: true)?.permitsPagedStorage == true)
        let off = [
            [PrefixCachePolicy.memoryEnvironmentFlag: "0"], [PrefixCachePolicy.environmentFlag: "0"],
            ["DARKBLOOM_CBV2_HYBRID_PREFIX_CACHE": "0"], [bankBytesKey: "0"],
        ]
        for environment in off {
            #expect(config(environment: environment) == nil, "\(environment)")
        }
    }

    @Test("an operator byte budget replaces the default")
    func operatorBudget() {
        #expect(config(environment: [bankBytesKey: "268435456"])?.maximumBytes == 256 << 20)
        #expect(config(capacity: 2 * gib, environment: [bankBytesKey: "1073741824"])?.maximumBytes == gib)
        // A budget that leaves the slot nothing to serve from builds no bank.
        #expect(config(capacity: 2 * gib, environment: [bankBytesKey: "2147483648"]) == nil)
    }

    @Test("contiguous storage keeps its own config")
    func contiguousConfig() {
        let contiguous = PrefixCachePolicy.hybridConfig(
            modelId: qualifiedID, promptContractID: "contract", kvBytesCapacity: 16 * gib,
            hasMTPDrafter: false, environment: [PrefixCachePolicy.memoryEnvironmentFlag: "1"])
        #expect(contiguous?.permitsPagedStorage == false)
        #expect(contiguous?.maximumBytes == gib)
    }
}

// MARK: - Slot wiring

private let hermeticEnvironment = [
    KVBackendGuardStore.pathEnvKey: "/dev/null",
    EngineV2KVQuantizationPolicy.environmentKey: "native",
]

/// The qualified artifact's family in miniature: dense, one full-attention
/// layer in four, on the paged kernel's validated attention shape.
private func tinyDenseQwen() throws -> Qwen35Model {
    let json = """
        {"model_type":"qwen3_5","hidden_size":64,"num_hidden_layers":4,
         "intermediate_size":128,"num_attention_heads":2,"num_key_value_heads":1,
         "head_dim":64,"linear_num_value_heads":1,"linear_num_key_heads":1,
         "linear_key_head_dim":64,"linear_value_head_dim":64,"linear_conv_kernel_dim":4,
         "vocab_size":64,"full_attention_interval":4,"num_experts":0,"num_experts_per_tok":0,
         "mtp_num_hidden_layers":0}
        """
    return Qwen35Model(try EngineV2VLMTextExtraction.decodeQwenConfiguration(configData: Data(json.utf8)))
}

private struct BankSlotProcessor: UserInputProcessor {
    struct NotUsed: Error {}
    func prepare(input: UserInput) async throws -> LMInput { throw NotUsed() }
}

@Suite("Paged recurrent bank slot (real tiny models)", .serialized)
struct PagedRecurrentBankSlotTests {
    private static let contract = "bank-slot-contract"
    private static let weightHash = String(repeating: "b", count: 64)
    /// The smallest grant whose default bank reaches 1 GiB; the pool stays lazy.
    private static let grant = 4 * gib

    private struct Slot {
        let kind: EngineV2KVBackendKind
        let bank: CBv2HybridPrefixCacheConfig?
        let hostsBank: Bool
        let hasStore: Bool
        let status: PrefixCacheModelStatus
        let servingBytes: Int
    }

    /// Through `makeProductionBundle`, so the policy, the backend, the engine
    /// and the SSD store are the ones a served slot gets.
    private func slot(
        modelID: String = qualifiedID, modelType: String = qualifiedType,
        kvBackend: String = "auto", memoryOptIn: Bool = true
    ) async throws -> Slot {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("paged-bank-slot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            SSDWholeRootMaintainer.shared.stopPeriodicMaintenance(root: root)
            try? FileManager.default.removeItem(at: root)
        }
        _ = LiveInferenceFixtures.ensureMetallibColocated()
        let model = try tinyDenseQwen()
        let tokenizer = StubBridgeTokenizer()
        var environment = hermeticEnvironment.merging([
            "DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL": "1",
            SSDPrefixCacheFactory.testRootEnvironmentKey: root.path,
        ]) { _, isolated in isolated }
        if memoryOptIn { environment[PrefixCachePolicy.memoryEnvironmentFlag] = "1" }
        let bundle = try await EngineV2SlotFactory.makeProductionBundle(
            modelId: modelID, modelType: modelType, isVLM: false, modelDirectory: nil,
            container: ModelContainer(context: ModelContext(
                configuration: ModelConfiguration(id: modelID), model: model,
                processor: BankSlotProcessor(), tokenizer: tokenizer)),
            tokenizer: TokenizerHandle(tokenizer),
            sizing: SlotSizingSnapshot(
                weightsBytes: 1, fp16KVBytesPerToken: 1_024, maxContextLength: 2_048,
                defaultMaxTokens: 32),
            kvBytesCapacity: Self.grant, maxConcurrentRequests: 2, kvBudget: nil,
            kvBackendConfig: kvBackend, weightHash: Self.weightHash,
            specDecPreparation: SpecDecPreparation(
                artifact: nil, status: .disabled(.configDisabled, configured: false)),
            preparedModel: EngineV2PreparedModel(
                snapshot: EngineV2ModelSnapshot(model: model, eosTokenIds: [1], extraEOSTokens: []),
                servingModel: model, assistant: nil,
                mtpStatus: .disabled(.configDisabled, configured: false), mtpArtifact: nil),
            assemblyOverrides: .init(
                promptContractID: Self.contract,
                completeCheckpointIdentity: .init(
                    modelAggregateHash: Self.weightHash, promptContractID: Self.contract,
                    buildID: "bank-slot-build", numericsFingerprint: "bank-slot-numerics")),
            environment: environment)
        let engine = try #require(await bundle.bridge.ownedEngine as? EngineV2)
        let slot = Slot(
            kind: await bundle.bridge.kvBackendKind,
            bank: engine.hybridPrefixCache?.config,
            hostsBank: await bundle.bridge.hostsRecurrentBank,
            hasStore: bundle.bridge.ssdHybridCheckpointStore != nil,
            status: bundle.bridge.prefixCacheModelStatus(),
            servingBytes: await bundle.bridge.capacitySnapshot().kvBytesCapacity)
        await bundle.bridge.shutdown()
        return slot
    }

    @Test("the qualified artifact's paged slot serves the bank in place of its SSD checkpoints")
    func qualifiedSlotHostsBank() async throws {
        let slot = try await slot()
        #expect(slot.kind == .paged)
        #expect(slot.hostsBank)
        #expect(slot.bank?.permitsPagedStorage == true)
        #expect(slot.bank?.maximumBytes == gib)
        #expect(slot.servingBytes == Self.grant - gib)
        #expect(!slot.hasStore)
        #expect(slot.status.state == .disabled)
        #expect(slot.status.reason == .configDisabled)
    }

    @Test("without the memory opt-in the slot keeps its SSD checkpoints")
    func optOutKeepsStore() async throws {
        let slot = try await slot(memoryOptIn: false)
        #expect(slot.kind == .paged)
        #expect(!slot.hostsBank)
        #expect(slot.hasStore)
        #expect(slot.servingBytes == Self.grant)
    }

    @Test("an artifact that is not qualified keeps its SSD checkpoints on pages",
          arguments: ["qwen3.5-35b-a3b", qualifiedID])
    func unqualifiedSlotKeepsStore(modelID: String) async throws {
        let slot = try await slot(modelID: modelID, modelType: "qwen3_5_moe")
        #expect(slot.kind == .paged)
        #expect(!slot.hostsBank)
        #expect(slot.hasStore)
        #expect(slot.servingBytes == Self.grant)
    }

    @Test("contiguous storage keeps its own bank and budget")
    func contiguousSlotUnchanged() async throws {
        let slot = try await slot(kvBackend: "contiguous")
        #expect(slot.kind == .contiguous)
        #expect(slot.bank?.permitsPagedStorage == false)
        #expect(slot.bank?.maximumBytes == 512 << 20)
        #expect(slot.servingBytes == Self.grant - (512 << 20))
        #expect(slot.hasStore)
    }

    @Test("a paged backend hosts the paged config and contiguous storage the other",
          arguments: [EngineV2KVBackendSelection.auto, .paged, .contiguous])
    func backendHostsItsOwnConfig(selection: EngineV2KVBackendSelection) throws {
        let contiguous = CBv2HybridPrefixCacheConfig(
            maximumBytes: 1 << 20, modelID: qualifiedID, promptContractID: Self.contract,
            buildID: "bank-slot-build")
        var paged = contiguous
        paged.maximumBytes = 2 << 20
        paged.permitsPagedStorage = true
        let prepared = try EngineV2Factory.prepareProductionBackend(
            model: tinyDenseQwen(), modelID: qualifiedID, kvBytesCapacity: 8 << 20,
            maxConcurrentRequests: 2, kvBackend: selection, maxContextLength: 2_048,
            environment: hermeticEnvironment, hybridPrefixCache: contiguous,
            pagedHybridPrefixCache: paged)
        #expect(prepared.kind == (selection == .contiguous ? .contiguous : .paged))
        #expect(prepared.hybridPrefixCache == (selection == .contiguous ? contiguous : paged))
    }

    /// The serving pool starts empty, so its construction never depends on how
    /// much of the grant the bank took.
    @Test("carving the bank never moves an automatic slot off pages")
    func carveKeepsPages() throws {
        let capacity = 8 << 20
        let paged = CBv2HybridPrefixCacheConfig(
            maximumBytes: capacity - 1, modelID: qualifiedID, promptContractID: Self.contract,
            buildID: "bank-slot-build", permitsPagedStorage: true)
        let prepared = try EngineV2Factory.prepareProductionBackend(
            model: tinyDenseQwen(), modelID: qualifiedID, kvBytesCapacity: capacity,
            maxConcurrentRequests: 2, kvBackend: .auto, maxContextLength: 2_048,
            environment: hermeticEnvironment, pagedHybridPrefixCache: paged)
        #expect(prepared.kind == .paged)
        #expect(prepared.hybridPrefixCache == paged)
    }

    @Test("a bank as large as the grant refuses the load instead of leaving pages")
    func oversizedBankRefuses() throws {
        let capacity = 8 << 20
        let paged = CBv2HybridPrefixCacheConfig(
            maximumBytes: capacity, modelID: qualifiedID, promptContractID: Self.contract,
            buildID: "bank-slot-build", permitsPagedStorage: true)
        #expect(throws: EngineV2ProductionError.self) {
            _ = try EngineV2Factory.prepareProductionBackend(
                model: tinyDenseQwen(), modelID: qualifiedID, kvBytesCapacity: capacity,
                maxConcurrentRequests: 2, kvBackend: .auto, maxContextLength: 2_048,
                environment: hermeticEnvironment, pagedHybridPrefixCache: paged)
        }
    }
}
