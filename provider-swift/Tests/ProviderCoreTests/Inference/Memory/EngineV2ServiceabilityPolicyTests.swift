import Testing
@testable import MLXLMCommon
@testable import ProviderCore

@Suite("Serviceable grants preserve SDK admission policy", .serialized)
struct EngineV2ServiceabilityPolicyTests {
    private let gib = 1 << 30
    private let workspace = 619_000_000

    @Test("the actual SDK ledger confirms each watermark and fixed external reserve at the byte boundary")
    func watermarkAndExternalReserveMatchSDK() {
        let kinds = [CBv2LayerKind(attention: .full, headDim: 1, kvHeads: 1, queryHeads: 1)]
        for (watermark, external) in [(0.0, 0), (0.05, 0), (0.25, gib), (0.95, 0)] {
            let admission = AdmissionV2(layerKinds: kinds, bytesCapacity: 8 * gib,
                config: .init(watermarkFraction: watermark,
                    elementBytes: 4, fixedBytesPerRequest: workspace),
                externalReserveBytes: external)
            let floor = EngineV2Bridge.minimumOrdinaryGrantBytes(
                fixedRequestBytes: workspace, capacityBytes: admission.bytesCapacity,
                admissibleCapacityBytes: admission.admissibleBytesCapacity,
                watermarkFraction: watermark)
            #expect(floor < Int.max)
            #expect(floor >= workspace + gib + external)
            admission.updateBytesCapacity(floor)
            #expect(admission.bytesExternallyReserved == external)
            #expect(admission.admissibleBytesCapacity >= workspace + gib)
            #expect(admission.canEverFit(promptTokens: gib / 8, maxTokens: 0))
            admission.updateBytesCapacity(floor - 1)
            #expect(!admission.canEverFit(promptTokens: gib / 8, maxTokens: 0))
        }
    }

    @Test("a nondefault ordinary engine watermark survives shrink and leaves usable KV")
    func ordinaryBridgeUsesDeclaredSDKWatermark() async {
        let (engine, bridge) = fixture(grant: 4 * gib, watermark: 0.25)
        let floor = await bridge.minimumServiceableGrantBytes()
        #expect(floor > EngineV2Bridge.minimumNativeGrantBytes(fixedRequestBytes: workspace))
        #expect(floor < 4 * gib)
        await bridge.updateKVBytesCapacity(floor)
        #expect(engine.admissibleKVBytesCapacity >= workspace + gib)
        #expect(await bridge.effectiveServingConcurrency(allowExpansion: true) == 1)
        #expect(await bridge.minimumServiceableGrantBytes() == floor)
        await bridge.updateKVBytesCapacity(floor - 1)
        #expect(await bridge.effectiveServingConcurrency(allowExpansion: true) == 0)
        await bridge.updateKVBytesCapacity(floor)
        #expect(await bridge.effectiveServingConcurrency(allowExpansion: true) == 1)
        await bridge.shutdown()
    }

    @Test("a fixed reference pool cannot satisfy an otherwise finite minimum grant")
    func fixedPoolCannotInventGrowth() async {
        let (_, fixed) = fixture(grant: gib, watermark: 0.05,
            backend: ServiceabilityFixedBackend(bytesCapacity: gib), kind: .paged)
        #expect(await fixed.minimumServiceableGrantBytes() == Int.max)
        #expect(!EngineV2KVSizing.resliceMeetsServiceabilityFloor(
            ["fixed": 8 * gib], minimumGrantBytes: ["fixed": await fixed.minimumServiceableGrantBytes()]))
        #expect(await fixed.effectiveServingConcurrency(allowExpansion: true) == 0)
        await fixed.shutdown()

        let (_, growable) = fixture(grant: gib, watermark: 0.05)
        let floor = await growable.minimumServiceableGrantBytes()
        #expect(floor > gib && floor < 2 * gib)
        await growable.updateKVBytesCapacity(floor)
        #expect(await growable.effectiveServingConcurrency(allowExpansion: true) == 1)
        await growable.shutdown()
    }

    @Test("missing constructor policy and a saturated live ceiling cannot prove a serviceable floor")
    func unknownPolicyAndSaturatedCeilingFailClosed() async {
        let (_, unknown) = fixture(grant: 4 * gib, watermark: nil)
        #expect(await unknown.effectiveServingConcurrency(allowExpansion: true) > 0)
        #expect(await unknown.minimumServiceableGrantBytes() == Int.max)
        await unknown.shutdown()
        let (_, known) = fixture(grant: 4 * gib, watermark: 0.25)
        await known.updateKVBytesCapacity(0)
        #expect(await known.minimumServiceableGrantBytes() == Int.max)
        await known.updateKVBytesCapacity(4 * gib)
        #expect(await known.minimumServiceableGrantBytes() < Int.max)
        await known.shutdown()
    }

    @Test("invalid or overflowing policy inputs fail closed before arithmetic can trap")
    func invalidAndOverflowingBounds() {
        for fraction in [Double.nan, .infinity, -.infinity, -0.1, 1.0] {
            #expect(EngineV2Bridge.minimumOrdinaryGrantBytes(
                fixedRequestBytes: workspace, capacityBytes: 4 * gib,
                admissibleCapacityBytes: 3 * gib, watermarkFraction: fraction) == Int.max)
        }
        for (capacity, admissible, fixed) in [
            (0, 0, workspace), (-1, 0, workspace), (4 * gib, 0, workspace),
            (4 * gib, -1, workspace), (4 * gib, 4 * gib, workspace),
            (4 * gib, 3 * gib, -1), (4 * gib, 3 * gib, Int.max),
            (Int.max, 1, Int.max / 2),
        ] {
            #expect(EngineV2Bridge.minimumOrdinaryGrantBytes(
                fixedRequestBytes: fixed, capacityBytes: capacity,
                admissibleCapacityBytes: admissible, watermarkFraction: 0.25) == Int.max)
        }
    }

    private func fixture(grant: Int, watermark: Double?, backend: (any CBv2KVBackend)? = nil,
        kind: EngineV2KVBackendKind = .contiguous) -> (EngineV2, EngineV2Bridge) {
        let model = DeadlineAdmissionFixtureModel()
        let configuration = AdmissionV2.Config(watermarkFraction: watermark ?? 0.25,
            elementBytes: 4, fixedBytesPerRequest: workspace)
        let engine = EngineV2(model: model, layerKinds: model.kinds,
            backend: backend ?? CBv2ContiguousKVBackend(config: .init(bytesCapacity: grant)),
            cacheProvider: CBv2LayerCacheBank(layerKinds: model.kinds),
            schedulerConfig: .init(maxConcurrentRequests: 4, enablePrefixCache: false),
            admissionConfig: configuration)
        let bridge = EngineV2Bridge(engine: engine, modelId: "serviceability-policy",
            tokenizer: TokenizerHandle(StubBridgeTokenizer()), eosTokenIds: [],
            kvBytesPerToken: 8, fixedRequestBytes: engine.resolvedFixedBytesPerRequest,
            admissionWatermarkFraction: watermark == nil ? nil : configuration.watermarkFraction,
            kvBackendKind: kind)
        return (engine, bridge)
    }
}

private final class ServiceabilityFixedBackend: CBv2KVBackend {
    let bytesCapacity: Int
    var bytesInUse: Int { 0 }
    init(bytesCapacity: Int) { self.bytesCapacity = bytesCapacity }

    func makeSequenceState(layerKinds: [CBv2LayerKind], promptLength: Int, maxLength: Int)
        throws -> [CBv2SequenceKV?] {
        preconditionFailure("capacity-only fixture must not submit requests")
    }

    func release(_ state: [CBv2SequenceKV?]) {}
}
