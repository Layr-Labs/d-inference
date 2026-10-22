import DarkbloomClusterPlacement
import Foundation
import Metal
import MLX
import MLXLLM

/// Metadata-only adapter for the installed plan helper. Input allowances are
/// explicitly experimental, never authenticated/measured workspace evidence.
/// The signed quotation/owner path still validates the chosen cut from scratch.
public enum GLM5NextAutomaticPlacement {
    private typealias P = ClusterGLMCalibrationPlacement
    private struct File: Decodable { let bytes: Int; let sha256: String }
    private struct Environment: Decodable {
        let binarySHA256: String, os: String, deviceName: String, architecture: String
        let deviceRegistryID: UInt64
        let memoryBytes: Int, maximumBufferBytes: Int
        let recommendedWorkingSetBytes: UInt64
        let backend: String, allocator: String
    }
    private struct Selection: Decodable {
        let rank: Int, expiresUnixSeconds: Int64
        let repository: String, revision: String, artifactSHA256: String
        let files: [String: File]
        let profileID: String
        let maximumPromptTokens: Int, maximumChunkTokens: Int, maximumOutputTokens: Int, maximumContextTokens: Int
        let policy: String, storage: String, mode: String
        let hostAllocationQuantum: Int, hostAllocationOverhead: Int
        let environment: Environment
    }
    private struct Input: Decodable {
        struct Request: Decodable {
            let selection: Selection
            let authorization: GLM5NextCalibration.Authorization
        }
        let schema: String, modelDirectory: String
        let request: Request
    }
    public struct Bounds {
        public let native: Int, host: Int, combined: Int
        public func requireFits(nativeBytes: Int, hostBytes: Int) throws {
            let total = nativeBytes.addingReportingOverflow(hostBytes)
            guard nativeBytes > 0, hostBytes > 0, !total.overflow,
                  nativeBytes <= native, hostBytes <= host, total.partialValue <= combined else {
                throw ProbeError("Selected GLM cut no longer fits the current native/host/load bounds; resample both ranks")
            }
        }
    }
    /// Placement capacity comes from the Mac's hardware, never from transient
    /// free or file-cache memory: the GPU's resident capacity (wired limit or
    /// recommended working set), the allocator limit and physical memory less
    /// headroom. The live load gate still refuses an actual load that the Mac
    /// cannot admit at that moment. Headroom is never counted as available.
    public static func currentDeviceBounds(profile: ClusterDeviceProfile,
                                           authorization: GLM5NextCalibration.Authorization) throws -> Bounds {
        try profile.validate(); try authorization.validate()
        guard profile.memory.admits(0), profile.power.onExternalPower,
              !profile.power.lowPowerMode, !["serious", "critical"].contains(profile.power.thermalState) else {
            throw ProbeError("GLM placement requires a judged load-gate sample and admissible power/thermal state")
        }
        let sum = GLM5NextStageLoadResources.sum
        let used = try sum([Memory.activeMemory, Memory.cacheMemory, profile.memory.allocatorHeadroomBytes])
        let native = max(0, min(profile.allocatorLimitBytes, profile.residentCapacityBytes,
                                authorization.nativeHardCapBytes) - used)
        let headroom = max(profile.memory.loadingHeadroomBytes, authorization.osHeadroomBytes)
        let combined = min(try sum([authorization.nativeHardCapBytes, authorization.hostBudgetBytes]),
                           max(0, profile.physicalMemoryBytes - headroom))
        guard native > 0, combined > 0 else { throw ProbeError("GLM placement has no capacity after headroom") }
        return Bounds(native: native, host: authorization.hostBudgetBytes, combined: combined)
    }

    public static func scan(_ data: Data, measurements: [ClusterSpeedMeasurement],
                            profile: ClusterDeviceProfile) throws -> String {
        let identity = try P.bindings(data)
        let input = try JSONDecoder().decode(Input.self, from: data)
        let p = input.request.selection, a = input.request.authorization, e = p.environment
        let now = Int64(Date().timeIntervalSince1970)
        try a.validate()
        guard input.schema == "darkbloom_glm_calibration_quote_input_v1", input.modelDirectory.hasPrefix("/"),
              (0...1).contains(p.rank), p.expiresUnixSeconds > now, p.expiresUnixSeconds - now <= 3600,
              p.mode == "coldTextBatch1", p.policy == "serving_v1", p.storage == "nvfp4Hybrid",
              e.backend == "jaccl", e.allocator == "disableFreedBufferCache",
              (1...2048).contains(p.maximumPromptTokens), (1...16).contains(p.maximumOutputTokens),
              (1...p.maximumPromptTokens).contains(p.maximumChunkTokens), p.maximumContextTokens <= 2064,
              p.maximumContextTokens >= p.maximumPromptTokens + p.maximumOutputTokens,
              a.promptTokenIDs.count <= p.maximumPromptTokens, a.chunkSize <= p.maximumChunkTokens,
              a.outputCount <= p.maximumOutputTokens,
              (1...(1 << 30)).contains(p.hostAllocationQuantum), (0...(1 << 30)).contains(p.hostAllocationOverhead),
              let metal = MTLCopyAllDevices().first ?? MTLCreateSystemDefaultDevice() else {
            throw ProbeError("Invalid bounded GLM candidate input")
        }
        let gpu = GPU.deviceInfo()
        guard e.os == ProcessInfo.processInfo.operatingSystemVersionString,
              e.deviceRegistryID == metal.registryID, e.deviceName == metal.name,
              e.architecture == gpu.architecture, e.maximumBufferBytes == gpu.maxBufferSize,
              e.memoryBytes == gpu.memorySize, e.memoryBytes == profile.physicalMemoryBytes,
              e.recommendedWorkingSetBytes == gpu.maxRecommendedWorkingSetSize else {
            throw ProbeError("GLM template does not describe this device")
        }
        let directory = URL(fileURLWithPath: input.modelDirectory, isDirectory: true)
        let config = try BoundedProbeInput.data(directory.appendingPathComponent("config.json"), maximumBytes: 32 << 20)
        let configuration = try JSONDecoder().decode(GLM5NextConfiguration.self, from: config)
        guard let seed = (1..<max(1, configuration.textConfig.hiddenLayers)).first else {
            throw ProbeError("GLM configuration has no structural cut")
        }
        // The descriptor is solely for bounded inventory inspection. Selection
        // later covers EVERY structural boundary, including a one-layer stage.
        let descriptor = try GLM5NextResidentDescriptor(modelID: "qualification_glm5_next",
            artifactIdentity: .init(repository: p.repository, revision: p.revision,
                files: p.files.mapValues { .init(bytes: $0.bytes, sha256: $0.sha256) }),
            artifactAggregateSHA256: p.artifactSHA256, configurationBytes: config, cut: seed,
            storage: .nvfp4Hybrid, executionPolicy: .serving, profileID: p.profileID,
            maximumPromptTokens: p.maximumPromptTokens, maximumChunkTokens: p.maximumChunkTokens,
            maximumOutputTokens: p.maximumOutputTokens, maximumContextTokens: p.maximumContextTokens)
        let inventory = try descriptor.inspectInventory(directory: directory)
        try GLM5NextCalibration.requirePinnedInventory(inventory)
        guard a.promptTokenIDs.allSatisfy({ $0 < configuration.textConfig.vocabularySize }) else {
            throw ProbeError("GLM request token exceeds pinned vocabulary")
        }
        let layout = try GLM5NextStageLayout(inventory: inventory)
        let scope = GLM5NextRequestStateBudget.Scope(maximumContextTokens: p.maximumContextTokens,
            maximumPromptTokens: p.maximumPromptTokens, maximumOutputTokens: p.maximumOutputTokens,
            maximumChunkTokens: p.maximumChunkTokens)
        let bounds = try currentDeviceBounds(profile: profile, authorization: a)
        let environmentDigest = try environmentSHA256(data)
        let configurationDigest = sha256(try canonicalJSONData(configuration.textConfig))
        let inventoryDigest = GLM5NextArtifactMetadata.fingerprint(inventory)
        let policyDigest = try GLM5NextStageContract.policySHA256(.serving)
        let report = try GLM5NextQualificationPlacement.evaluateLocal(inventory: inventory, scope: scope,
            executionPolicy: .serving,
            device: .init(rank: p.rank, executionEnvironmentSHA256: environmentDigest,
                capacityLimitBytes: bounds.combined, availableMemoryBytes: bounds.combined,
                allocatorAvailableBytes: bounds.native, maximumBufferBytes: gpu.maxBufferSize,
                metadataAllowanceBytes: GLM5NextResidentResourceEnvelope.metadataAllowanceBytes),
            workspace: { _, layers in
                .init(kind: .experimentalAllowance, evidenceSHA256: identity.local,
                    configurationSHA256: configurationDigest, inventorySHA256: inventoryDigest,
                    numericalPolicySHA256: policyDigest, executionEnvironmentSHA256: environmentDigest,
                    layers: layers, scope: scope, nativeBytes: a.workspaceNativeAllowanceBytes,
                    hostBytes: a.workspaceHostAllowanceBytes)
            }, transport: GLM5NextResidentResourceEnvelope.transportTerms,
            allocationBound: { _, bytes in try Memory.allocationFootprintUpperBound(byteCount: bytes) },
            hostAllocationBound: { _, bytes in
                try hostBound(bytes, quantum: p.hostAllocationQuantum, overhead: p.hostAllocationOverhead)
            })
        var quotes: [P.Quote] = [], refusals = report.refusals.map { "cut=\($0.cut) rank=\($0.rank): \($0.reason)" }
        for candidate in report.candidates {
            let quote = candidate.ranks[0]
            if quote.hostPeakBytes > bounds.host {
                refusals.append("cut=\(candidate.cut) rank=\(p.rank): separate host allowance exceeded")
            } else {
                quotes.append(.init(cut: candidate.cut, nativeBytes: quote.nativePeakBytes,
                    hostBytes: quote.hostPeakBytes, combinedBytes: quote.combinedPeakBytes))
            }
        }
        // Source bytes are a compute prior only. The exact native/load/request
        // quotation above, not this generic layout's memory formula, decides fit.
        func part(_ p: GLM5NextStageLayout.Part) -> ClusterModelLayout.Part {
            .init(storedBytes: p.bytes, loadedBytes: p.bytes, largestTensorBytes: p.largestTensorBytes, tensorCount: p.tensorCount)
        }
        let costLayout = ClusterModelLayout(runtimeModelID: descriptor.modelID, artifactSHA256: p.artifactSHA256,
            configurationSHA256: configurationDigest,
            layers: layout.layers.map { .init(index: $0.globalIndex, kind: $0.attention + "/" + $0.feedForward,
                weights: part($0.source), stateFixedBytes: 0, stateBytesPerToken: 0, cost: 1) },
            ingress: part(layout.embedding), egress: part(try layout.finalNorm.adding(layout.head)),
            excluded: part(try layout.mtp.adding(layout.vision)), admittedCuts: [], structuralCuts: layout.structuralCuts,
            generationModes: [.pipeline], prefillSchedules: [.serial], maximumPromptTokens: p.maximumPromptTokens,
            maximumOutputTokens: p.maximumOutputTokens, maximumChunkTokens: p.maximumChunkTokens,
            boundaryBytesPerToken: layout.boundaryBytesPerToken, requestChargeEveryRankBytes: 0)
        let snapshot = P.Snapshot(rank: p.rank, inputSHA256: identity.local, commonSHA256: identity.common,
            runtimeBinarySHA256: e.binarySHA256, sampledUnixSeconds: now, expiresUnixSeconds: p.expiresUnixSeconds,
            profile: profile, layout: costLayout, nativeAvailableBytes: bounds.native, hostAvailableBytes: bounds.host,
            combinedAvailableBytes: bounds.combined, quotes: quotes,
            refusals: refusals.map { String($0.prefix(1000)) }, measurements: measurements)
        try snapshot.validate(now: Int64(Date().timeIntervalSince1970))
        return String(decoding: try P.encode(snapshot), as: UTF8.self)
    }
    private static func environmentSHA256(_ data: Data) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let request = root["request"] as? [String: Any], let p = request["selection"] as? [String: Any],
              let environment = p["environment"] else { throw ProbeError("Missing GLM environment") }
        return sha256(try JSONSerialization.data(withJSONObject: environment, options: [.sortedKeys, .withoutEscapingSlashes]))
    }
    private static func hostBound(_ bytes: Int, quantum: Int, overhead: Int) throws -> Int {
        let padded = bytes.addingReportingOverflow(quantum - 1)
        guard bytes > 0, !padded.overflow else { throw ProbeError("GLM host rounding overflow") }
        let rounded = (padded.partialValue / quantum).multipliedReportingOverflow(by: quantum)
        let total = rounded.partialValue.addingReportingOverflow(overhead)
        guard !rounded.overflow, !total.overflow, total.partialValue >= bytes else { throw ProbeError("GLM host bound overflow") }
        return total.partialValue
    }
}
