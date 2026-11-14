// Copyright © 2026 Eigen Labs.

import Foundation
import Testing

@testable import ProviderCore

private func hardware(_ family: ChipFamily, _ tier: ChipTier) -> HardwareInfo {
    HardwareInfo(
        machineModel: "test", chipName: "Apple \(family.rawValue) \(tier.rawValue)",
        chipFamily: family, chipTier: tier, memoryGb: 512, memoryAvailableGb: 500,
        cpuCores: CpuCores(total: 32, performance: 24, efficiency: 8),
        gpuCores: 80, memoryBandwidthGbs: 800)
}

private final class Reads: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func read(_ name: String?) -> String? {
        lock.withLock { count += 1 }
        return name
    }
    var total: Int { lock.withLock { count } }
}

/// Muse Glimmer 30B serves only on an Apple M5 Ultra: the provider reports
/// `muse_glimmer_v1` there alone, and without it the model is neither
/// advertised nor loaded.
@Suite("Muse Glimmer hardware requirement")
struct MuseGlimmerHardwareRequirementTests {
    private static let catalogID = MuseGlimmerModelPolicy.catalogModelID

    private static func detect(_ hardware: HardwareInfo, metal: String?) -> Set<ProviderRuntimeCapability> {
        ProviderRuntimeCapabilityDetector.detectPrepared(
            hardware: hardware, boundMetallibHash: "abc", naxAvailable: { true }, metalDeviceName: { metal })
    }

    @Test("the capability is reported only on an M5 Ultra whose Metal device names it")
    func capabilityOnlyOnM5Ultra() {
        #expect(ProviderRuntimeCapability.museGlimmer.rawValue == "muse_glimmer_v1")
        #expect(Self.detect(hardware(.m5, .ultra), metal: "Apple M5 Ultra").contains(.museGlimmer))
        for (family, tier) in [(ChipFamily.m5, ChipTier.max), (.m5, .pro), (.m5, .base), (.m3, .ultra),
                               (.m4, .max), (.m6, .ultra), (.m5, .unknown)] {
            // The Metal device is not even read for other chips.
            let reads = Reads()
            let capabilities = ProviderRuntimeCapabilityDetector.detectPrepared(
                hardware: hardware(family, tier), boundMetallibHash: "abc", naxAvailable: { true },
                metalDeviceName: { reads.read("Apple M5 Ultra") })
            #expect(!capabilities.contains(.museGlimmer), "\(family) \(tier)")
            #expect(reads.total == 0)
        }
        // Both sources must agree.
        for metal in ["Apple M3 Ultra", "Apple M5 Max", "apple m5 ultra", nil] as [String?] {
            #expect(!Self.detect(hardware(.m5, .ultra), metal: metal).contains(.museGlimmer), "\(metal ?? "nil")")
        }
        // GLM's own gate is unchanged beside it.
        #expect(Self.detect(hardware(.m5, .ultra), metal: "Apple M5 Ultra")
            == [.appleM5, .mlxNAX, .modelRevisions, .glm5Next, .museGlimmer])
    }

    @Test("the refusal names the requirement and this Mac")
    func refusalReason() {
        #expect(MuseGlimmerHardwareRequirement.refusal(hardware: hardware(.m5, .ultra)) { "Apple M5 Ultra" } == nil)
        #expect(MuseGlimmerHardwareRequirement.refusal(hardware: hardware(.m3, .ultra)) { nil }
            == "Muse Glimmer 30B requires an Apple M5 Ultra; this Mac is M3 Ultra")
        #expect(MuseGlimmerHardwareRequirement.refusal(hardware: hardware(.m5, .base)) { nil }
            == "Muse Glimmer 30B requires an Apple M5 Ultra; this Mac is M5")
        #expect(MuseGlimmerHardwareRequirement.refusal(hardware: hardware(.m5, .ultra)) { "Apple M3 Ultra" }
            == "Muse Glimmer 30B requires an Apple M5 Ultra; this Mac's Metal device is \"Apple M3 Ultra\"")
        #expect(MuseGlimmerHardwareRequirement.refusal(hardware: hardware(.m5, .ultra)) { nil }
            == "Muse Glimmer 30B requires an Apple M5 Ultra; this Mac's Metal device is unavailable")
    }

    @Test("both Muse identities require it, whatever the catalog says; lookalikes do not")
    func embeddedRule() throws {
        for id in [MuseGlimmerModelPolicy.catalogModelID, MuseGlimmerModelPolicy.localModelID] {
            #expect(ModelRuntimeRequirements.requiredCapabilities(for: id) == [.appleM5, .mlxNAX, .museGlimmer])
            // An older provider, or an M5 Max: apple_m5 and NAX, no muse_glimmer_v1.
            #expect(!ModelRuntimeRequirements.isEligible(
                modelID: id, catalogRequirements: [], available: [.appleM5, .mlxNAX, .modelRevisions, .glm5Next]))
            // An M5 Ultra whose NAX diagnostic failed: the coordinator would not route it Muse.
            #expect(!ModelRuntimeRequirements.isEligible(modelID: id, available: [.appleM5, .museGlimmer]))
            #expect(ModelRuntimeRequirements.isEligible(modelID: id, available: [.appleM5, .mlxNAX, .museGlimmer]))
            do {
                try ModelRuntimeRequirements.requireEligible(modelID: id, available: [.appleM5, .mlxNAX])
                Issue.record("expected the typed ineligibility")
            } catch let error as ModelRuntimeIneligibleError {
                #expect(error.eligibility.missing == [.museGlimmer])
                let message = try #require(error.errorDescription)
                #expect(message.contains(ModelRuntimeIneligibleError.permanentFailureMarker))
                #expect(message.hasSuffix("missing runtime capabilities [muse_glimmer_v1] (it serves only on an Apple M5 Ultra)"))
            }
        }
        for id in ["muse-glimmer-30b-r2", "Muse-Glimmer-30B", "nvidia/Muse-Glimmer-30B-NVFP4-r2"] {
            #expect(ModelRuntimeRequirements.requiredCapabilities(for: id).isEmpty, "\(id)")
        }
        // Other models' messages are unchanged.
        let qwen = ModelRuntimeIneligibleError(eligibility: ModelRuntimeRequirements.evaluate(
            modelID: ModelRuntimeRequirements.qwen38ConcreteModelID, available: []))
        #expect(qwen.errorDescription?.hasSuffix("[apple_m5, mlx_nax]") == true)
        #expect(ProviderCapabilityLabels.label(for: .museGlimmer) == "Apple M5 Ultra")
        #expect(ModelRequirementLine.lines(modelID: Self.catalogID, catalogRequirements: nil, available: [.appleM5])
            == ["requires: Apple M5, NAX runtime, Apple M5 Ultra",
                "not eligible on this machine (missing: mlx_nax, muse_glimmer_v1)"])
    }

    private static func model(_ id: String = catalogID) -> ModelInfo {
        ModelInfo(id: id, modelType: MuseGlimmerModelPolicy.modelType, sizeBytes: 1_000_000, estimatedMemoryGb: 1)
    }

    private static let config = ProviderConfig(
        provider: ProviderSettings(name: "muse-gate", memoryReserveGB: 1),
        backend: BackendSettings(idleTimeoutMins: 0, maxModelSlots: 1),
        coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60))

    @Test("without the capability the model is not advertised, by the loop or the standalone server")
    func advertisement() async throws {
        for (capabilities, advertised) in [
            (Set<ProviderRuntimeCapability>([.appleM5, .mlxNAX, .modelRevisions]), false),
            ([.appleM5, .mlxNAX, .modelRevisions, .museGlimmer], true),
        ] {
            let loop = try ProviderLoop(
                config: ProviderLoopConfig(
                    coordinatorURL: "ws://127.0.0.1:0", hardware: hardware(.m5, .ultra),
                    models: [Self.model()], config: Self.config, runtimeCapabilities: capabilities),
                attestationSigner: nil)
            #expect(await loop.isModelAdvertised(Self.catalogID) == advertised)
            let standalone = StandaloneServer(
                config: StandaloneServerConfig(runtimeCapabilities: capabilities), models: [Self.model()])
            #expect(await standalone.advertisedModelIds() == (advertised ? [Self.catalogID] : []))
        }
    }

    @Test("without the capability a load is refused before any disk or loader work")
    func loadRefusal() async throws {
        let config = Self.config
        let work = Reads()
        let loop = try ProviderLoop(
            config: ProviderLoopConfig(
                coordinatorURL: "ws://127.0.0.1:0", hardware: hardware(.m3, .ultra),
                models: [Self.model()], config: config, runtimeCapabilities: [.modelRevisions]),
            attestationSigner: nil,
            beforeModelLoad: { _ in _ = work.read(nil) })
        do {
            try await loop.ensureModelLoaded(modelId: Self.catalogID)
            Issue.record("expected the typed ineligibility")
        } catch let error as ModelRuntimeIneligibleError {
            #expect(error.eligibility.missing == [.appleM5, .mlxNAX, .museGlimmer])
        }
        #expect(work.total == 0)
    }
}
