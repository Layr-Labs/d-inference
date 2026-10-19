import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation
import MLXLLM
import Testing
@testable import DarkbloomClusterRuntime

/// The registered GLM serving row against the real pinned artifact: metadata
/// only (configuration, manifest and shard headers), no tensor payload.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_GLM_METADATA_DIRECTORY"] != nil))
struct GLM5NextServingMetadataTests {
    private let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DARKBLOOM_GLM_METADATA_DIRECTORY"] ?? "/")
    private func file(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(name))
    }

    @Test func registeredRowIsTheAdapterProtocolsAndTheCatalogsGLM() throws {
        let spec = try GLM5NextRegisteredSpecification.specification(configuration: file("config.json"))
        #expect(ClusterRuntimeAdapter.registering(runtimeModelID: spec.model.rawValue) == .glm5NextLayerStage)
        let entry = try ClusterResidentModelCatalog.entry(configuration: file("config.json"))
        #expect(entry.family == .glm5Next && entry.runtimeModelID == "registered_glm53_flash")
        #expect(entry.supportedCuts == Array(1..<45) && entry.manifestSHA256 == spec.manifestSHA256)
        let files = try spec.runtimeFiles(manifest: file("manifest.json"))
        #expect(files.count == 37 && files.keys.filter { $0.hasSuffix(".safetensors") && $0 != "model.safetensors.index.json" }.count == 35)
        let profile = try spec.profile()
        #expect(profile.maximumContextTokens == 32_768 && profile.maximumChunkTokens == 2048)
    }

    /// Each advertised partition's Plan hash is the one the loaded contract
    /// computes from the actual header inventory (what READY reports).
    @Test func everyAdvertisedPartitionMatchesTheVerifiedContract() throws {
        let configuration = try file("config.json"), manifest = try file("manifest.json")
        let capability = try ClusterResidentModelCatalog.describe(configuration: configuration, manifest: manifest,
            runtimeBinarySHA256: String(repeating: "a", count: 64))
        #expect(capability.adapterID == ClusterRuntimeAdapter.glm5NextLayerStage.rawValue)
        #expect(capability.partitions.count == 44)
        let spec = try GLM5NextRegisteredSpecification.specification(configuration: configuration)
        let metadata = try GLM5NextArtifactMetadata.read(directory: directory)
        let parsed = try JSONDecoder().decode(GLM5NextConfiguration.self, from: configuration)
        for cut in [1, 22, 40, 44] {
            let descriptor = try spec.descriptor(configuration: configuration, manifest: manifest, cut: cut)
            let contract = try GLM5NextStageContractMetadata(configuration: parsed,
                artifactIdentity: descriptor.artifactIdentity, storage: .nvfp4Hybrid, executionPolicy: .serving,
                artifactAggregateSHA256: spec.artifactSHA256,
                storageCommitmentSHA256: try GLM5NextStageContractMetadata.storageCommitment(
                    inventory: metadata.inventory, cut: cut, includeMTP: false), cut: cut)
            let partition = try #require(capability.partitions.first { $0.stages[0].sourceLayerEnd == cut })
            #expect(partition.planSHA256 == contract.source.planFingerprint)
            #expect(partition.stages.map(\.stagePlanSHA256) == contract.stageFingerprints)
        }
    }

    /// The planner's layout of the real artifact: GLM's family, every cut, and
    /// stage bytes equal to the verified stage layout's own split.
    @Test func plannerLayoutIsTheStageLayoutsSplit() throws {
        let layout = try ClusterPlacementArtifact.layout(directory: directory)
        #expect(layout.runtimeModelID == "registered_glm53_flash")
        #expect(layout.maximumChunkTokens == 2048)
        #expect(layout.structuralCuts == Array(1..<45) && layout.admittedCuts == Array(1..<45))
        #expect(layout.generationModes == [.pipeline] && layout.boundaryBytesPerToken == 32_768)
        let stage = try GLM5NextArtifactMetadata.read(directory: directory).layout
        #expect(layout.layers.count == 45)
        for (index, layer) in layout.layers.enumerated() {
            #expect(layer.weights.storedBytes == stage.layers[index].source.bytes)
        }
        #expect(layout.ingress.storedBytes == stage.embedding.bytes)
        let imageLayout = try ClusterPlacementArtifact.layout(directory: directory,
            runtimeProfile: ClusterGLMImageCandidate.profileID)
        #expect(imageLayout.ingress.storedBytes == stage.embedding.bytes + stage.vision.bytes)
        #expect(imageLayout.maximumChunkTokens == 2048)
        #expect(imageLayout.structuralCuts == layout.structuralCuts)
        #expect(imageLayout.admittedCuts == layout.admittedCuts)
        #expect(imageLayout.layers.map(\.weights.storedBytes) == layout.layers.map(\.weights.storedBytes))
        #expect(layout.egress.storedBytes == stage.finalNorm.bytes + stage.head.bytes)
        // DSA layers carry per-token state; linear attention layers fixed state.
        #expect(layout.layers[3].stateBytesPerToken > 0 && layout.layers[3].stateFixedBytes == 0)
        #expect(layout.layers[0].stateBytesPerToken == 0 && layout.layers[0].stateFixedBytes > 0)
    }

    @Test func largerChunksChargeWholeResidualsAndRejectStaleWorkspaceScope() throws {
        typealias Budget = GLM5NextRequestStateBudget
        let metadata = try GLM5NextArtifactMetadata.read(directory: directory)
        let inventory = metadata.inventory
        func scope(_ chunk: Int) -> Budget.Scope {
            .init(maximumContextTokens: 32_768, maximumPromptTokens: 32_767,
                maximumOutputTokens: 4096, maximumChunkTokens: chunk)
        }
        func quote(_ chunk: Int, rank: Int, workspaceChunk: Int, maximumBuffer: Int = Int.max) throws -> Budget {
            try Budget.estimate(inventory: inventory, layers: rank == 0 ? 0..<13 : 13..<45,
                rank: rank, scope: scope(chunk), executionPolicy: .serving,
                executionEnvironmentSHA256: GLM5NextRequestStateBudgetTests.environment,
                workspace: GLM5NextRequestStateBudgetTests.workspace(inventory, scope: scope(workspaceChunk), policy: .serving),
                transport: .init(maximumRecordPlaintextBytes: 8 << 20,
                    maximumTransportFrameBytes: (8 << 20) + 40, maximumControlBytes: 16_384),
                maximumBufferBytes: maximumBuffer, allocationBound: { $0 }, hostAllocationBound: { $0 })
        }
        for rank in 0...1 {
            let small = try quote(512, rank: rank, workspaceChunk: 512)
            let large = try quote(2048, rank: rank, workspaceChunk: 2048)
            #expect(large.boundaryBytes == 2 * 64 * 1024 * 1024)
            #expect(large.boundaryBytes == small.boundaryBytes * 4)
            #expect(large.kdaTransactionBytes > small.kdaTransactionBytes)
            #expect(large.transportHostBytes > small.transportHostBytes)
            #expect(large.reservedBytes > small.reservedBytes)
            #expect(large.workspaceNativeBytes == small.workspaceNativeBytes)
            #expect(throws: ProbeError.self) { _ = try quote(2048, rank: rank, workspaceChunk: 512) }
            #expect(throws: ProbeError.self) { _ = try quote(2049, rank: rank, workspaceChunk: 2049) }
            #expect(throws: ProbeError.self) {
                _ = try quote(2048, rank: rank, workspaceChunk: 2048, maximumBuffer: (64 << 20) - 1)
            }
        }
    }

    /// A full-size metadata regression: increasing the prefill chunk must not
    /// retain each old convolution history in every transaction owner. The
    /// planner still chooses the rank order and cut from all admitted shapes.
    @Test func compactStateKeepsFullScopeAutomaticallyPlaceable() throws {
        let layout = try ClusterPlacementArtifact.layout(directory: directory)
        func device(_ name: String, physicalGiB: Int, availableGiB: Int) throws -> ClusterPlacementDevice {
            let physical = physicalGiB << 30, available = availableGiB << 30
            let wired = physical / 16
            let memory = ClusterDeviceMemory(gatePolicy: "placement-test", sampledUTC: "2026-10-19T00:00:00Z",
                judged: true, unjudgedReason: nil, physicalMemoryBytes: physical,
                actualFreeBytes: available, countedFileCacheBytes: 0, admissibleNowBytes: available,
                fileBackedBytes: 0, fileCacheReserveBytes: 0, fileCacheAboveReserveBytes: 0,
                anonymousBytes: physical - wired - available, wiredBytes: wired, compressorBytes: 0,
                pageableBytes: physical - wired, pressureLevel: 1, swapUsedBytes: 0,
                minimumAdmissibleBytes: 6 << 30, minimumTrulyFreeBytes: 16 << 20,
                loadingHeadroomBytes: 4 << 30, allocatorHeadroomBytes: 2 << 30,
                loadScratchBytes: 8 << 20, pageSizeBytes: 16_384)
            let profile = try ClusterDeviceProfile(chip: name, performanceCores: 8, efficiencyCores: 4,
                gpuCores: 32, osVersion: "27.0", osBuild: "test", physicalMemoryBytes: physical,
                gpuRecommendedWorkingSetBytes: physical * 8 / 10, gpuMaximumBufferBytes: physical / 2,
                allocatorLimitBytes: physical * 9 / 10, memory: memory,
                power: .init(onExternalPower: true, lowPowerMode: false, thermalState: "nominal"))
            return .init(label: name, profile: profile,
                speed: .init(source: .assumedEqual, absolute: false,
                    rested: .init(prefillTokensPerSecond: 1, decodeTokensPerSecond: 1),
                    sustained: nil, explanation: "equal-speed test; no measured performance claim"))
        }
        let devices = try [device("larger", physicalGiB: 256, availableGiB: 145),
                           device("smaller", physicalGiB: 128, availableGiB: 64)]
        let result = try ClusterPlacementPlanner.plan(devices: devices, layout: layout)
        let chosen = try #require(result.chosen)
        #expect(layout.maximumPromptTokens + layout.maximumOutputTokens == 32_768)
        #expect(layout.maximumChunkTokens == 2048)
        #expect(chosen.mode == .pipeline && chosen.ranks.count == 2)
        #expect(chosen.possible)
        #expect(chosen.ranks.map { $0.endLayer - $0.firstLayer }.reduce(0, +) == 45)
        #expect(chosen.ranks.allSatisfy { $0.hardwareFits == true || $0.fit.tier == 0 })
    }

    /// The serving envelope quotes the whole row scope on a rank's layers with
    /// the conservative workspace; free and file-cache state play no part.
    @Test func servingEnvelopeQuotesTheWholeScope() throws {
        let configuration = try file("config.json"), manifest = try file("manifest.json")
        let spec = try GLM5NextRegisteredSpecification.specification(configuration: configuration)
        let descriptor = try spec.descriptor(configuration: configuration, manifest: manifest, cut: 40)
        let inventory = try descriptor.inspectInventory(directory: directory)
        for rank in 0...1 {
            let envelope = try GLM5NextServingResources.envelope(descriptor: descriptor, inventory: inventory,
                rank: rank, buildSHA256: String(repeating: "b", count: 64))
            let budget = try envelope.budget(descriptor: descriptor)
            #expect(budget.workspaceNativeBytes == GLM5NextServingResources.workspaceNativeBytes)
            #expect(budget.scope.maximumContextTokens == 32_768)
            #expect(envelope.requestCapacityBytes == budget.reservedBytes)
            #expect(envelope.loadCapacityBytes >= envelope.requestCapacityBytes)
        }
    }
}
