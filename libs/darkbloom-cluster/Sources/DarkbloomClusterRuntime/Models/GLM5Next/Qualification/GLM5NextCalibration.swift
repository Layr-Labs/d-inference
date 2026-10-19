import DarkbloomClusterProtocol
import DarkbloomClusterSecurity
import Foundation
import MLX
import MLXLLM

/// Private experiments are not workspace qualification or serving admission.
/// The caller authenticates the authorization and supplies an independently
/// enforced native backing cap plus authorized host/OS headroom. MLX.memoryLimit
/// and a sampling watchdog do not implement that contract. The worker currently refuses without such support.
public enum GLM5NextCalibration {
    /// Metadata routing identity only: not a load permit, payload receipt,
    /// measured workspace envelope, native start or serving capability.
    public struct Binding: Codable, Equatable, Sendable {
        public let profile: ClusterWorkerProfile
        public let executionPlanSHA256: String

        fileprivate init(profile: ClusterWorkerProfile, executionPlanSHA256: String) {
            self.profile = profile
            self.executionPlanSHA256 = executionPlanSHA256
        }


        // ClusterWorkerProfile has no Codable conformance. Keep this private
        // projection local instead of changing the ordinary worker wire.
        private struct Profile: Codable {
            let id: String
            let vocabularySize: Int
            let maximumPromptTokens: Int
            let maximumOutputTokens: Int
            let maximumChunkTokens: Int
            let maximumContextTokens: Int

            init(_ value: ClusterWorkerProfile) {
                id = value.id; vocabularySize = value.vocabularySize
                maximumPromptTokens = value.maximumPromptTokens
                maximumOutputTokens = value.maximumOutputTokens
                maximumChunkTokens = value.maximumChunkTokens
                maximumContextTokens = value.maximumContextTokens
            }

            var value: ClusterWorkerProfile {
                .init(id: id, vocabularySize: vocabularySize,
                    maximumPromptTokens: maximumPromptTokens,
                    maximumOutputTokens: maximumOutputTokens,
                    maximumChunkTokens: maximumChunkTokens,
                    maximumContextTokens: maximumContextTokens)
            }
        }
        private struct Wire: Codable {
            let profile: Profile
            let executionPlanSHA256: String
        }

        /// Decoding carries a peer's claim, never qualification. The experiment
        /// worker must rederive this value and compare it before native work.
        public init(from decoder: any Decoder) throws {
            let wire = try Wire(from: decoder)
            guard qwenStageWireIsSHA256(wire.executionPlanSHA256) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                    debugDescription: "Invalid GLM calibration execution plan digest"))
            }
            self.init(profile: wire.profile.value, executionPlanSHA256: wire.executionPlanSHA256)
        }

        public func encode(to encoder: any Encoder) throws {
            try Wire(profile: Profile(profile), executionPlanSHA256: executionPlanSHA256).encode(to: encoder)
        }
    }

    /// Uses the already validated descriptor and matching header inventory.
    /// No file reads, loader/model construction, device queries or Metal allocation.
    /// Callers still authenticate the selection and verify payloads during LOAD.
    /// The plan is common to both ranks; profile scope is bound separately.
    public static func binding(descriptor: GLM5NextResidentDescriptor,
                               inventory: GLM5NextWeightInventory) throws -> Binding {
        let shards = Set(inventory.entries.values.map { $0.tensor.shard })
        let declaredShards = Set(descriptor.artifactIdentity.files.keys.filter { $0.hasSuffix(".safetensors") })
        let expectedFiles = declaredShards.union(["config.json", "model.safetensors.index.json"])
        guard inventory.configuration == descriptor.configuration,
              inventory.storage == descriptor.storage, shards == declaredShards,
              Set(descriptor.artifactIdentity.files.keys) == expectedFiles else {
            throw ProbeError("GLM calibration binding inventory differs from descriptor")
        }
        let storage = try GLM5NextStageContractMetadata.storageCommitment(
            inventory: inventory, cut: descriptor.cut, includeMTP: false)
        let metadata = try GLM5NextStageContractMetadata(
            configuration: descriptor.configuration, artifactIdentity: descriptor.artifactIdentity,
            storage: descriptor.storage, executionPolicy: descriptor.executionPolicy,
            artifactAggregateSHA256: descriptor.artifactAggregateSHA256,
            storageCommitmentSHA256: storage, cut: descriptor.cut)
        return Binding(profile: descriptor.wireProfile,
            executionPlanSHA256: metadata.source.planFingerprint)
    }

    /// Reuse the metadata owner's immutable pin; the stale smoke label is not
    /// a second source of identity. These checks do not verify payload bytes.
    public static func requirePinnedSelection(repository: String, revision: String, aggregate: String,
                                              configurationSHA256: String?, indexSHA256: String?) throws {
        guard repository == GLM5NextArtifactPin.repository, revision == GLM5NextArtifactPin.revision,
              aggregate == GLM5NextArtifactPin.artifactSHA256,
              configurationSHA256 == GLM5NextArtifactPin.configurationSHA256,
              indexSHA256 == GLM5NextArtifactPin.indexSHA256 else {
            throw ProbeError("Calibration selection differs from authoritative EigenLabs NVFP4@8841 snapshot")
        }
    }

    public static func requirePinnedInventory(_ inventory: GLM5NextWeightInventory) throws {
        guard inventory.storage == .nvfp4Hybrid,
              inventory.entries.count == GLM5NextArtifactPin.tensorCount,
              GLM5NextArtifactMetadata.fingerprint(inventory) == GLM5NextArtifactPin.inventorySHA256 else {
            throw ProbeError("Calibration inventory differs from pinned metadata")
        }
    }

    public struct Authorization: Codable, Equatable {
        public let requestID: UUID
        public let nativeHardCapBytes: Int
        public let hostBudgetBytes: Int
        public let osHeadroomBytes: Int
        public let workspaceNativeAllowanceBytes: Int
        public let workspaceHostAllowanceBytes: Int
        public let promptTokenIDs: [Int]
        public let outputCount: Int
        public let chunkSize: Int

        public init(requestID: UUID, nativeHardCapBytes: Int, hostBudgetBytes: Int, osHeadroomBytes: Int,
                    workspaceNativeAllowanceBytes: Int, workspaceHostAllowanceBytes: Int,
                    promptTokenIDs: [Int], outputCount: Int, chunkSize: Int) throws {
            self.requestID = requestID; self.nativeHardCapBytes = nativeHardCapBytes
            self.hostBudgetBytes = hostBudgetBytes; self.osHeadroomBytes = osHeadroomBytes
            self.workspaceNativeAllowanceBytes = workspaceNativeAllowanceBytes
            self.workspaceHostAllowanceBytes = workspaceHostAllowanceBytes
            self.promptTokenIDs = promptTokenIDs; self.outputCount = outputCount; self.chunkSize = chunkSize
            try validate()
        }
        public func validate() throws {
            guard nativeHardCapBytes > 0, hostBudgetBytes > 0, osHeadroomBytes > 0,
                  !nativeHardCapBytes.addingReportingOverflow(hostBudgetBytes).overflow,
                  workspaceNativeAllowanceBytes > 0,
                  workspaceHostAllowanceBytes > 0,
                  workspaceNativeAllowanceBytes < nativeHardCapBytes,
                  workspaceHostAllowanceBytes < hostBudgetBytes,
                  !promptTokenIDs.isEmpty, promptTokenIDs.count <= 2048,
                  promptTokenIDs.allSatisfy({ $0 >= 0 }), (1...16).contains(outputCount),
                  (1...2048).contains(chunkSize), chunkSize <= promptTokenIDs.count else {
                throw ProbeError("Calibration requires explicit bounded allowances and one small cold text request")
            }
        }
    }

    public struct Quote: Codable, Equatable {
        public let authorizationSHA256: String
        public let descriptorSHA256: String
        public let cut: Int
        public let rank: Int
        public let nativeBytes: Int
        public let hostBytes: Int
        public let loadCapacityBytes: Int
        public let requestCapacityBytes: Int
        public let inventorySHA256: String
        public let configurationSHA256: String
        public let numericalPolicySHA256: String
        public let executionEnvironmentSHA256: String
        public let qualifiesMaximumEnvelope: Bool
    }

    /// Opaque plan: the experimental resource envelope cannot escape into a
    /// public resident constructor, and is not serialized as measured evidence.
    public struct Plan {
        public let quote: Quote
        let descriptor: GLM5NextResidentDescriptor
        let resources: GLM5NextResidentResourceEnvelope
        let authorization: Authorization
    }

    /// No payload reads or device queries. Call for each candidate cut using the
    /// existing inventory and real allocator/host bounds; all math stays in the
    /// resident quotation. No default workspace reserve is manufactured here.
    public static func plan(descriptor: GLM5NextResidentDescriptor,
                            inventory: GLM5NextWeightInventory, rank: Int,
                            authorization: Authorization, authorizationSHA256: String,
                            executionEnvironmentSHA256: String,
                            authenticate: () throws -> Void,
                            requireEnvironment: @escaping (String) throws -> Void,
                            maximumBufferBytes: Int,
                            allocationBound: (Int) throws -> Int,
                            hostAllocationBound: @escaping (Int) throws -> Int) throws -> Plan {
        try authenticate()
        try authorization.validate()
        guard (0...1).contains(rank), qwenStageWireIsSHA256(authorizationSHA256),
              inventory.configuration == descriptor.configuration,
              inventory.storage == descriptor.storage else { throw ProbeError("Calibration identity differs") }
        let p = descriptor.profile
        guard authorization.promptTokenIDs.count <= p.maximumPromptTokens,
              authorization.outputCount <= p.maximumOutputTokens,
              authorization.chunkSize <= p.maximumChunkTokens,
              authorization.promptTokenIDs.allSatisfy({ $0 < p.vocabularySize }) else {
            throw ProbeError("Calibration request exceeds descriptor scope")
        }
        let scope = GLM5NextRequestStateBudget.Scope(maximumContextTokens: p.maximumContextTokens,
            maximumPromptTokens: p.maximumPromptTokens, maximumOutputTokens: p.maximumOutputTokens,
            maximumChunkTokens: p.maximumChunkTokens)
        let workspace = GLM5NextRequestStateBudget.WorkspaceEvidence(kind: .experimentalAllowance,
            evidenceSHA256: authorizationSHA256,
            configurationSHA256: sha256(try canonicalJSONData(inventory.configuration.textConfig)),
            inventorySHA256: GLM5NextArtifactMetadata.fingerprint(inventory),
            numericalPolicySHA256: try GLM5NextStageContract.policySHA256(descriptor.executionPolicy),
            executionEnvironmentSHA256: executionEnvironmentSHA256,
            layers: rank == 0 ? 0..<descriptor.cut : descriptor.cut..<descriptor.configuration.textConfig.hiddenLayers,
            scope: scope, nativeBytes: authorization.workspaceNativeAllowanceBytes,
            hostBytes: authorization.workspaceHostAllowanceBytes)
        let bytes = try canonicalJSONData(workspace)
        let resources = try GLM5NextResidentResourceEnvelope(descriptor: descriptor, inventory: inventory, rank: rank,
            loadCapacityBytes: authorization.nativeHardCapBytes + authorization.hostBudgetBytes,
            requestCapacityBytes: authorization.nativeHardCapBytes + authorization.hostBudgetBytes,
            executionEnvironmentSHA256: executionEnvironmentSHA256, workspaceEvidence: bytes,
            authenticateWorkspace: { guard $0 == bytes else { throw ProbeError("Calibration allowance changed") } },
            requireExecutionEnvironment: requireEnvironment, hostAllocationBound: hostAllocationBound, calibrationOnly: true)
        let value = try resources.quote(descriptor: descriptor, maximumBufferBytes: maximumBufferBytes,
                                        allocationBound: allocationBound)
        guard value.peak.nativeBytes <= authorization.nativeHardCapBytes,
              value.peak.hostBytes <= authorization.hostBudgetBytes else {
            throw ProbeError("Calibration quotation exceeds separate native/host authorization")
        }
        return Plan(quote: .init(authorizationSHA256: authorizationSHA256, descriptorSHA256: descriptor.fingerprint, cut: descriptor.cut, rank: rank, nativeBytes: value.peak.nativeBytes,
            hostBytes: value.peak.hostBytes, loadCapacityBytes: value.peak.reservedBytes,
            requestCapacityBytes: value.request.reservedBytes, inventorySHA256: workspace.inventorySHA256,
            configurationSHA256: workspace.configurationSHA256, numericalPolicySHA256: workspace.numericalPolicySHA256,
            executionEnvironmentSHA256: executionEnvironmentSHA256, qualifiesMaximumEnvelope: false),
            descriptor: descriptor, resources: resources, authorization: authorization)
    }

    public struct HostObservation: Codable {
        /// Host malloc accounting, not RSS minus MLX (which double-counts or misses mappings).
        public let mallocBytes: Int
        /// Whole-process footprint, kept separate from host/native component observations.
        public let processFootprintBytes: Int
        public init(mallocBytes: Int, processFootprintBytes: Int) {
            self.mallocBytes = mallocBytes; self.processFootprintBytes = processFootprintBytes
        }
    }
    public struct Observation: Codable {
        public let phase: String
        public let nativeActiveBytes: Int
        public let nativePeakBytes: Int
        public let host: HostObservation
    }
    public struct Report: Codable {
        public let nativeHardCapBytes: Int
        public let hostBudgetBytes: Int
        public let osHeadroomBytes: Int
        public let quote: Quote
        public let observations: [Observation]
        public let committedTokens: Int
        public let qualifiesMaximumEnvelope: Bool
        public let requiresProcessExit: Bool
    }

    /// Executes the production selected-stage JACCL/encrypted path, never a
    /// full model. Does not expose READY, tokens, a lease, or a retirement proof.
    /// `requireNativeCap` must verify an already installed allocation-enforcing
    /// native backing guard; a watchdog is not an implementation of this contract.
    /// The owner must force process exit on success AND failure, retaining roots.
    public static func run(plan: Plan, configuration: QwenResidentLoadConfiguration,
                           credential: ClusterDataPlaneCredential,
                           requireNativeCap: @escaping (Int) throws -> Void,
                           observeHost: () throws -> HostObservation) throws -> Report {
        let ceiling = plan.authorization.nativeHardCapBytes
        try requireNativeCap(ceiling)
        let baseline = try observeHost()
        guard baseline.mallocBytes >= 0, baseline.processFootprintBytes >= 0,
              Memory.activeMemory <= ceiling,
              plan.quote.nativeBytes <= ceiling - Memory.activeMemory else {
            throw ProbeError("Calibration native quotation plus baseline exceeds cap")
        }
        let physical = ProcessInfo.processInfo.physicalMemory
        let authorized = try GLM5NextStageLoadResources.sum([baseline.processFootprintBytes,
            ceiling, plan.authorization.hostBudgetBytes, plan.authorization.osHeadroomBytes])
        guard UInt64(authorized) <= physical else {
            throw ProbeError("Calibration baseline, native cap, host budget and OS headroom exceed physical memory")
        }
        // Retain before LOAD: neither a thrown observation nor peer failure may
        // deinitialize partially exposed model roots or reopen the process lease.
        let runtime = try GLM5NextResidentRuntime(configuration: configuration, descriptor: plan.descriptor,
            resources: plan.resources, processLease: .shared, hooks: .init(), calibrationOnly: true)
        retained.hold(runtime)
        var observations: [Observation] = []
        func sample(_ phase: String) throws {
            try requireNativeCap(ceiling)
            let host = try observeHost()
            guard host.mallocBytes >= 0, host.processFootprintBytes >= 0,
                  host.mallocBytes <= baseline.mallocBytes
                    || host.mallocBytes - baseline.mallocBytes <= plan.authorization.hostBudgetBytes else {
                throw ProbeError("Observed calibration host allocation exceeded its authorized budget")
            }
            guard UInt64(host.processFootprintBytes) <= physical - UInt64(plan.authorization.osHeadroomBytes) else {
                throw ProbeError("Observed calibration footprint consumed required OS headroom")
            }
            observations.append(.init(phase: phase, nativeActiveBytes: Memory.activeMemory,
                nativePeakBytes: Memory.peakMemory, host: host))
        }
        Memory.peakMemory = 0
        try sample("before-load")
        try runtime.load(dataPlane: credential)
        try sample("loaded")
        let a = plan.authorization
        let request = ClusterWorkerReservation(profileID: plan.descriptor.profile.identifier,
            promptTokenIDs: a.promptTokenIDs, stopTokenIDs: [], outputCount: a.outputCount,
            chunkSize: a.chunkSize, deadlineUptimeNanoseconds: configuration.lease?.uptimeNanoseconds ?? configuration.deadlineUptimeNanoseconds,
            capacityLimitBytes: plan.quote.requestCapacityBytes, sampling: nil)
        _ = try runtime.reserve(requestID: a.requestID, request: request)
        let completion = try runtime.start(requestID: a.requestID) { _, _, _ in
            try sample("committed-token")
            return true
        }
        try sample("request-finished")
        return .init(nativeHardCapBytes: ceiling, hostBudgetBytes: a.hostBudgetBytes, osHeadroomBytes: a.osHeadroomBytes,
                     quote: plan.quote, observations: observations, committedTokens: completion.committedTokens,
                     qualifiesMaximumEnvelope: false, requiresProcessExit: true)
    }

    private static let retained = Roots()
    private final class Roots: @unchecked Sendable {
        let lock = NSLock()
        var values: [GLM5NextResidentRuntime] = []
        func hold(_ value: GLM5NextResidentRuntime) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    }
}
