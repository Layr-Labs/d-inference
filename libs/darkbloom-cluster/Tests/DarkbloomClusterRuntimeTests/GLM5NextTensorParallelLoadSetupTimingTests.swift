import Foundation
import MLX
@testable import MLXLLM
import Testing
@testable import DarkbloomClusterRuntime

/// What a tensor-parallel rank does before its link comes up, step by step,
/// on the real checkpoint's metadata (config, manifest, index, headers; no
/// payload byte, no GPU work). Prints each step's time in the order the load
/// takes them (`GLM5NextTensorParallelResidentRuntime.load`), so the `setup`
/// and `open` phases can be split without a pair. Runs when
/// `GLM53_REAL_MODEL_DIR` names the NVFP4 model directory.
@Suite("GLM tensor-parallel load setup timing", .serialized)
struct GLM5NextTensorParallelLoadSetupTimingTests {
    static let directory = ProcessInfo.processInfo.environment["GLM53_REAL_MODEL_DIR"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }

    @Test(.enabled(if: directory != nil))
    func setupStepsOnTheRealMetadata() throws {
        let directory = try #require(Self.directory)
        var steps: [(String, Double)] = []
        var last = ContinuousClock.now
        func mark(_ name: String) {
            let now = ContinuousClock.now
            let d = last.duration(to: now).components
            steps.append((name, Double(d.seconds) + Double(d.attoseconds) / 1e18))
            last = now
        }
        let spec = try GLM5NextRegisteredSpecification.specification(
            runtimeModelID: GLM5NextRegisteredModel.glm53Flash.rawValue)
        let config = try BoundedProbeInput.data(directory.appendingPathComponent("config.json"),
            maximumBytes: GLM5NextRegisteredSpecification.maximumConfigurationBytes)
        let manifest = try BoundedProbeInput.data(directory.appendingPathComponent("manifest.json"),
            maximumBytes: GLM5NextRegisteredSpecification.maximumManifestBytes)
        mark("read_config_manifest")
        let cut = try #require(spec.supportedCuts.first)
        let descriptor = try spec.descriptor(configuration: config, manifest: manifest, cut: cut)
        mark("descriptor")
        _ = try GLM5NextServingResources.contract(specification: spec,
            configuration: descriptor.configuration, artifactIdentity: descriptor.artifactIdentity,
            cut: descriptor.cut).source.planFingerprint
        mark("contract")
        let inventory = try descriptor.inspectInventory(directory: directory)
        mark("inspect_inventory")
        #expect(GLM5NextArtifactMetadata.fingerprint(inventory) == spec.inventorySHA256)
        mark("fingerprint")
        let maximumBufferBytes = GPU.deviceInfo().maxBufferSize
        var envelopes: [GLM5NextResidentResourceEnvelope] = []
        for rank in 0 ..< 2 {
            let resources = try GLM5NextServingResources.envelope(descriptor: descriptor, inventory: inventory,
                rank: rank, buildSHA256: String(repeating: "a", count: 64))
            mark("envelope_\(rank)")
            _ = try resources.quote(descriptor: descriptor, maximumBufferBytes: maximumBufferBytes,
                allocationBound: QwenResidentResourceEnvironment.allocationBound)
            mark("quote_\(rank)")
            envelopes.append(resources)
        }
        let profile = descriptor.profile
        let largestChunk = max(profile.maximumChunkTokens, GLM5NextTensorParallelResidentRuntime.bulkPrefillChunkTokens)
        let fixed = try QwenLongPrefillCheckedBytes.sum([
            try QwenLongPrefillCheckedBytes.product([6, largestChunk, descriptor.configuration.textConfig.hiddenSize, 4]),
            try QwenLongPrefillCheckedBytes.product([largestChunk / max(1, profile.maximumChunkTokens) - 1,
                GLM5NextServingResources.workspaceNativeBytes])])
        let charge = try GLM5NextTensorParallelRequestCharge(descriptor: descriptor, envelopes: envelopes,
            fixedBytes: fixed, speculativeDepth: GLM5NextTensorParallelResidentRuntime.mtpDepth,
            maximumBufferBytes: maximumBufferBytes, allocationBound: QwenResidentResourceEnvironment.allocationBound)
        _ = try charge.bytes(contextTokens: descriptor.memoryProfile.maximumContextTokens)
        mark("request_charge")
        _ = try GLM5NextTensorParallelResidentRuntime.shardBytes(inventory)
        _ = inventory.bytes(in: .mtp) + inventory.bytes(in: .vision)
        mark("shard_bytes")
        // The `open` phase: the prepared owner's metadata parse, and its fingerprint check.
        let loader = try GLM5NextArtifactLoader(directory: directory, expectedIdentity: descriptor.artifactIdentity,
            storage: descriptor.storage, executionPolicy: descriptor.executionPolicy,
            verification: .withPreparedPayload)
        mark("open_owner_init")
        #expect(GLM5NextArtifactMetadata.fingerprint(loader.inventory) == spec.inventorySHA256)
        mark("open_fingerprint")
        // Pieces the setup, the pass's planning and the build repeat per tensor.
        let names = Array(loader.inventory.entries.keys)
        mark("names")
        var axes = 0, referenceAxes = 0
        for name in names where GLM5NextTensorShard.referenceSplitAxis(name) != nil { referenceAxes += 1 }
        mark("split_axis_reference_all")
        for name in names where GLM5NextTensorShard.splitAxis(name) != nil { axes += 1 }
        mark("split_axis_all")
        #expect(axes == referenceAxes)
        _ = loader.inventory.entries(in: .text).count
        mark("entries_text_sorted")
        _ = GLM5NextPreparedBanks.group(Set(names), experts: loader.configuration.textConfig.nRoutedExperts)
        mark("bank_group_all")
        #expect(axes > 0)
        // The load's metadata thread as it now runs (prepared path, rank 0),
        // and as it ran (inventory inspection, per-tensor path without its owner).
        // The reference values, computed as the load did before (sorted entries,
        // Foundation's split matcher, one envelope after the other).
        let referenceShard = try inventory.entries(in: .text).reduce(0) { total, entry in
            try QwenLongPrefillCheckedBytes.sum([total,
                GLM5NextTensorShard.referenceSplitAxis(entry.tensor.name) == nil ? entry.bytes : entry.bytes / 2])
        }
        let referenceReserve = try charge.bytes(contextTokens: descriptor.memoryProfile.maximumContextTokens)
        for path in [GLM5NextTensorParallelLoadPath.prepared, .perTensor] {
            let metadata = try GLM5NextTensorParallelLoadMetadata(spec: spec, descriptor: descriptor,
                directory: directory, rank: 0, buildSHA256: [String(repeating: "a", count: 64), String(repeating: "b", count: 64)],
                path: path, roots: GLM5NextArtifactLoadRoots(), pagedKV: true, maximumBufferBytes: maximumBufferBytes)
            mark("metadata_thread_\(path.rawValue)")
            print(String(format: "GLM53_SETUP_METADATA path=%@ inventory=%.3f resources=%.3f shard_bytes=%ld",
                path.rawValue, Double(metadata.inventoryNanoseconds) / 1e9, Double(metadata.resourcesNanoseconds) / 1e9,
                metadata.shardBytes))
            #expect(metadata.shardBytes == 88_697_159_452 && metadata.mtpBytes == 4_183_320_576)
            #expect(metadata.shardBytes == referenceShard)
            #expect(metadata.mtpBytes == inventory.entries(in: .mtp).reduce(0) { $0 + $1.bytes })
            #expect(metadata.visionBytes == inventory.entries(in: .vision).reduce(0) { $0 + $1.bytes })
            #expect(GLM5NextArtifactMetadata.fingerprint(metadata.inventory) == GLM5NextArtifactMetadata.fingerprint(inventory))
            // Paged: the reference charge above was unpaged; compare like with like.
            var unpaged = metadata.requestCharge
            unpaged.pagedHistory = nil
            #expect(try unpaged.bytes(contextTokens: descriptor.memoryProfile.maximumContextTokens) == referenceReserve)
            #expect((metadata.loader != nil) == (path == .prepared))
        }
        let total = steps.reduce(0) { $0 + $1.1 }
        print("GLM53_SETUP_TIMING " + steps.map { String(format: "%@=%.3f", $0.0, $0.1) }.joined(separator: " ")
            + String(format: " total=%.3f", total))
    }
}
