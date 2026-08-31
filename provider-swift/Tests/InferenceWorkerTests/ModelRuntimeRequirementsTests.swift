import Foundation
import Testing

@testable import ProviderCore
@testable import InferenceWorkerCore

private let qwen38ID = ModelRuntimeRequirements.qwen38ConcreteModelID
private let qwen38Caps: Set<ProviderRuntimeCapability> = [.appleM5, .mlxNAX]

private func runtimeHardware(_ family: ChipFamily) -> HardwareInfo {
    HardwareInfo(
        machineModel: "test", chipName: family.rawValue,
        chipFamily: family, chipTier: .base,
        memoryGb: 128, memoryAvailableGb: 124,
        cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
        gpuCores: 40, memoryBandwidthGbs: 500)
}

private func runtimeModel(_ id: String = qwen38ID) -> ModelInfo {
    ModelInfo(
        id: id, modelType: "gpt_oss",
        sizeBytes: 1_000_000, estimatedMemoryGb: 1)
}

private func runtimeCatalogModel(
    id: String = qwen38ID,
    required: [ProviderRuntimeCapability]? = nil
) -> CatalogModel {
    CatalogModel(
        id: id, s3Name: "qwen38", displayName: "Qwen 3.8",
        sizeGb: 1, requiredProviderCapabilities: required)
}
private final class RuntimeLoadWorkRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func record() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class RuntimeDetectionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}


@Suite("Provider runtime capabilities")
struct ProviderRuntimeCapabilityTests {
    @Test("detector uses structured M5, live NAX, and non-empty metallib hash")
    func detectorMatrix() {
        #expect(ProviderRuntimeCapabilityDetector.detect(
            chipFamily: .m5, naxAvailable: { true }, liveMetallibHash: { "abc" }) == qwen38Caps)
        #expect(ProviderRuntimeCapabilityDetector.detect(
            chipFamily: .m5, naxAvailable: { false }, liveMetallibHash: { "abc" }) == [.appleM5])
        #expect(ProviderRuntimeCapabilityDetector.detect(
            chipFamily: .m5, naxAvailable: { true }, liveMetallibHash: { nil }) == [.appleM5])
        #expect(ProviderRuntimeCapabilityDetector.detect(
            chipFamily: .m4, naxAvailable: { true }, liveMetallibHash: { "abc" }) == [.mlxNAX])
        #expect(ProviderRuntimeCapabilityDetector.detect(
            chipFamily: .unknown, naxAvailable: { false }, liveMetallibHash: { nil }).isEmpty)
        for family in [ChipFamily.m1, .m2, .m3, .m4] {
            let capabilities = ProviderRuntimeCapabilityDetector.detect(
                chipFamily: family,
                naxAvailable: { true },
                liveMetallibHash: { "abc" })
            #expect(!ModelRuntimeRequirements.isEligible(
                modelID: qwen38ID, available: capabilities))
        }
    }

    @Test("live detector binds the explicit URL before the injected NAX predicate")
    func liveDetectorExplicitBindingOrder() {
        let explicitURL = URL(
            fileURLWithPath:
                "/tmp/ProviderCorePackageTests.xctest/Contents/MacOS/mlx.metallib")
        let success = RuntimeDetectionRecorder()
        let capabilities = ProviderRuntimeCapabilityDetector.detectLive(
            hardware: runtimeHardware(.m5),
            metallibURL: explicitURL,
            bindMetallib: { received in
                #expect(received == explicitURL)
                success.append("bind")
                return "bound-snapshot-hash"
            },
            naxAvailable: {
                success.append("nax-diagnostic")
                return true
            }
        )
        #expect(success.events == ["bind", "nax-diagnostic"])
        #expect(capabilities == qwen38Caps)

        let failedBinding = RuntimeDetectionRecorder()
        let failedCapabilities = ProviderRuntimeCapabilityDetector.detectLive(
            hardware: runtimeHardware(.m5),
            metallibURL: explicitURL,
            bindMetallib: { _ in
                failedBinding.append("bind")
                return nil
            },
            naxAvailable: {
                failedBinding.append("nax-diagnostic")
                return true
            }
        )
        #expect(failedBinding.events == ["bind"])
        #expect(failedCapabilities == [.appleM5])
    }

    @Test("exact embedded rule survives an old catalog while lookalikes stay compatible")
    func exactEmbeddedRule() {
        #expect(ModelRuntimeRequirements.isEligible(
            modelID: qwen38ID, available: qwen38Caps))
        #expect(!ModelRuntimeRequirements.isEligible(
            modelID: qwen38ID, available: [.appleM5]))
        #expect(!ModelRuntimeRequirements.isEligible(
            modelID: qwen38ID, available: [.mlxNAX]))
        #expect(ModelRuntimeRequirements.isEligible(
            modelID: qwen38ID.lowercased(), available: []))
        #expect(ModelRuntimeRequirements.isEligible(
            modelID: "prefix/\(qwen38ID)", available: []))
        #expect(ModelRuntimeRequirements.isEligible(
            modelID: "EigenLabs/Qwen3.8-27B-8bit", available: []))
        #expect(ModelRuntimeRequirements.isEligible(
            modelID: "unrelated/model", available: []))
    }

    @Test("catalog requirements merge with the embedded rule and unknown values fail closed")
    func catalogRequirementsMerge() {
        let future = ProviderRuntimeCapability(rawValue: "future_runtime")
        let evaluation = ModelRuntimeRequirements.evaluate(
            modelID: qwen38ID,
            catalogRequirements: [future],
            available: qwen38Caps)
        #expect(evaluation.required == qwen38Caps.union([future]))
        #expect(evaluation.missing == Set([future]))
    }

    @Test("catalog decodes typed required_provider_capabilities and defaults missing to no catalog requirement")
    func catalogDecode() throws {
        let data = Data(#"{"id":"EigenLabs/Qwen3.8-27B-4bit","s3_name":"qwen38","display_name":"Qwen 3.8","model_type":"text","size_gb":27,"required_provider_capabilities":["apple_m5","mlx_nax"]}"#.utf8)
        let decoded = try JSONDecoder().decode(CatalogModel.self, from: data)
        #expect(Set(decoded.requiredProviderCapabilities ?? []) == qwen38Caps)

        let legacy = Data(#"{"id":"other/model","s3_name":"other","display_name":"Other","model_type":"text","size_gb":1}"#.utf8)
        #expect(try JSONDecoder().decode(CatalogModel.self, from: legacy).requiredProviderCapabilities == nil)
    }

    @Test("registration wire and raw-attestation encoder are symmetric")
    func registrationEncodingSymmetry() throws {
        let raw = RawJSON(rawBytes: Data(#"{"signature":"raw"}"#.utf8))
        let config = CoordinatorClientConfig(
            url: "wss://example.invalid", hardware: runtimeHardware(.m5),
            models: [runtimeModel()], backendName: "mlx-swift",
            attestation: raw, runtimeCapabilities: qwen38Caps)
        let data = try CoordinatorClientCodec.encodeRegistration(from: config)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["runtime_capabilities"] as? [String] == ["apple_m5", "mlx_nax"])
        guard case .register(let decoded) = try ProviderProtocolCodec.decodeProviderMessage(from: data) else {
            Issue.record("expected register")
            return
        }
        #expect(Set(decoded.runtimeCapabilities) == qwen38Caps)
        #expect(decoded.attestation?.rawBytes == raw.rawBytes)
    }

    @Test("loop and standalone advertisement gates share the exact evaluator")
    func advertisementGates() async throws {
        let providerConfig = ProviderConfig(
            provider: ProviderSettings(name: "runtime-gate", memoryReserveGB: 1),
            backend: BackendSettings(idleTimeoutMins: 0, maxModelSlots: 1),
            coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60))
        let deniedLoop = try ProviderLoop(
            config: ProviderLoopConfig(
                coordinatorURL: "ws://127.0.0.1:0", hardware: runtimeHardware(.m5),
                models: [runtimeModel()], config: providerConfig,
                runtimeCapabilities: [.appleM5]),
            purgeLegacyFiles: false, attestationSigner: nil)
        #expect(await deniedLoop.isModelAdvertised(qwen38ID) == false)

        let allowedLoop = try ProviderLoop(
            config: ProviderLoopConfig(
                coordinatorURL: "ws://127.0.0.1:0", hardware: runtimeHardware(.m5),
                models: [runtimeModel()], config: providerConfig,
                runtimeCapabilities: qwen38Caps),
            purgeLegacyFiles: false, attestationSigner: nil)
        #expect(await allowedLoop.isModelAdvertised(qwen38ID))

        let deniedStandalone = StandaloneServer(
            config: StandaloneServerConfig(runtimeCapabilities: [.appleM5]),
            models: [runtimeModel()])
        #expect(await deniedStandalone.advertisedModelIds().isEmpty)
        let allowedStandalone = StandaloneServer(
            config: StandaloneServerConfig(runtimeCapabilities: qwen38Caps),
            models: [runtimeModel()])
        #expect(await allowedStandalone.advertisedModelIds() == [qwen38ID])
    }

    @Test("load gate rejects before disk, loader, or MTP preparation")
    func loadGateDoesZeroWork() async throws {
        let loadWork = RuntimeLoadWorkRecorder()
        let config = ProviderConfig(
            provider: ProviderSettings(name: "zero-work", memoryReserveGB: 1),
            backend: BackendSettings(idleTimeoutMins: 0, maxModelSlots: 1),
            coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60))
        let loop = try ProviderLoop(
            config: ProviderLoopConfig(
                coordinatorURL: "ws://127.0.0.1:0", hardware: runtimeHardware(.m5),
                models: [runtimeModel()], config: config,
                runtimeCapabilities: [.appleM5]),
            purgeLegacyFiles: false,
            attestationSigner: nil,
            beforeModelLoad: { _ in loadWork.record() })
        do {
            try await loop.ensureModelLoaded(modelId: qwen38ID)
            Issue.record("expected permanent eligibility rejection")
        } catch is ModelRuntimeIneligibleError {
            // Expected before resolveLocalPath/spec-dec/loader work.
        }
        #expect(loadWork.count() == 0)
    }

    @Test("downloader rejects before manifest, staging, or network work")
    func downloaderGateDoesZeroWork() async {
        let downloader = ModelDownloader(runtimeCapabilities: [.appleM5])
        do {
            try await downloader.download(model: runtimeCatalogModel())
            Issue.record("expected permanent eligibility rejection")
        } catch let error as ModelCatalogError {
            guard case .ineligible(let message) = error else {
                Issue.record("unexpected catalog error: \(error)")
                return
            }
            #expect(message.contains(ModelRuntimeIneligibleError.permanentFailureMarker))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
