import DarkbloomClusterProtocol
import Foundation

/// Process-local configuration. Build/peer labels are supplied bindings, not
/// native attestation. The enclosing worker must impose a hard process deadline.
public struct QwenResidentLoadConfiguration: Sendable {
    public let runtimeProfile: String?
    public let identity: ClusterWorkerIdentity
    public let modelDirectory: URL
    public let rank: Int
    public let stageCut: Int
    public let deadlineUptimeNanoseconds: UInt64
    /// The enclosing worker's fixed startup deadline, separate from its first
    /// renewable lease. Startup progress never renews this bound.
    public let startupDeadlineUptimeNanoseconds: UInt64?
    public let allocatorPolicy: QwenResidentAllocatorPolicy
    public let prefillSchedule: ClusterPrefillSchedule
    /// The worker's renewable rank lease (S03), or nil for a bounded tool run.
    /// A leased load has no fixed lifetime: `deadlineUptimeNanoseconds` is the
    /// lease's first deadline, and the owner moves the lease on while it wants
    /// the model resident.
    public let lease: ClusterLeaseDeadline?

    public init(identity: ClusterWorkerIdentity, modelDirectory: URL, rank: Int,
                stageCut: Int, deadlineUptimeNanoseconds: UInt64,
                allocatorPolicy: QwenResidentAllocatorPolicy = .unchanged,
                prefillSchedule: ClusterPrefillSchedule = .serial,
                lease: ClusterLeaseDeadline? = nil, runtimeProfile: String? = nil,
                startupDeadlineUptimeNanoseconds: UInt64? = nil) {
        self.runtimeProfile = runtimeProfile
        self.identity = identity; self.modelDirectory = modelDirectory
        self.rank = rank; self.stageCut = stageCut
        self.deadlineUptimeNanoseconds = deadlineUptimeNanoseconds
        self.startupDeadlineUptimeNanoseconds = startupDeadlineUptimeNanoseconds
        self.allocatorPolicy = allocatorPolicy
        self.prefillSchedule = prefillSchedule
        self.lease = lease
    }

    /// Resolve a fixed startup bound without treating a renewable first lease
    /// as a load lifetime, or extending an unleased tool's fixed lifetime.
    func startupWaitDeadline(now: UInt64) throws -> UInt64 {
        let selected: UInt64
        if let startupDeadlineUptimeNanoseconds {
            selected = lease == nil
                ? min(startupDeadlineUptimeNanoseconds, deadlineUptimeNanoseconds)
                : startupDeadlineUptimeNanoseconds
        } else {
            guard lease == nil else {
                throw ProbeError("A leased native startup requires its fixed startup deadline")
            }
            selected = deadlineUptimeNanoseconds
        }
        guard selected > now, selected - now <= ClusterWorkerLimits.deadlineNanoseconds else {
            throw ProbeError("Native startup deadline is expired or outside the protocol bound")
        }
        return selected
    }

    /// The deadline now: the lease's when leased, else the fixed one.
    public var currentDeadlineUptimeNanoseconds: UInt64 { lease?.uptimeNanoseconds ?? deadlineUptimeNanoseconds }

    /// Whether the load's deadline is admissible at `now`: in the future and at
    /// most one lease grant away when leased, or within the protocol's one-hour
    /// bound for a bounded tool run. There is no per-model lifetime.
    func admitsLoadDeadline(now: UInt64) -> Bool {
        let current = currentDeadlineUptimeNanoseconds
        let bound = lease == nil ? ClusterWorkerLimits.deadlineNanoseconds : ClusterWorkerLease.maximumNanoseconds
        return current > now && current - now <= bound
    }

    /// Whether a request's absolute deadline is admissible at `now`. Under a
    /// lease the owner renews the lease for as long as the request runs, so
    /// only the request protocol's own bound applies; a bounded run must end
    /// its requests before its fixed deadline.
    func admitsRequestDeadline(_ deadline: UInt64, now: UInt64) -> Bool {
        guard deadline > now else { return false }
        return lease == nil ? deadline <= deadlineUptimeNanoseconds : deadline - now <= ClusterWorkerLimits.deadlineNanoseconds
    }
}

struct QwenResidentAdmission {
    static let profileID = QwenResidentAdapterDefinition.profileID
    let configuration: QwenResidentLoadConfiguration
    let configBytes: Data, manifestBytes: Data
    let specification: QwenDenseRegisteredSpecification
    /// The closed resident row of `specification.model`: profile, cuts, schedules.
    let definition: QwenResidentModelDefinition
    let plan: QwenLayerStagePlan
    let profile: QwenLayerStageGenerationProfile
    let arithmetic: QwenLongPrefillArithmeticEnvironment.Receipt
    let arithmeticSHA256: String
    let jaccl: QwenResidentJACCLConfiguration

    init(configuration: QwenResidentLoadConfiguration, configBytes: Data, manifestBytes: Data,
         environment: [String: String], now: UInt64,
         read: (URL, Int) throws -> Data) throws {
        let identity = configuration.identity
        // The identity's model ID selects one row of the closed catalog; an ID
        // outside it has no definition. Every other check is against that row.
        guard let definition = try? QwenResidentModelDefinition(runtimeModelID: identity.modelID),
              (0...1).contains(configuration.rank), definition.supportedCuts.contains(configuration.stageCut),
              definition.supportedPrefillSchedules.contains(configuration.prefillSchedule),
              configuration.modelDirectory.isFileURL,
              identity.peers.count == 2, identity.peers[0].id != identity.peers[1].id,
              identity.peers.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 128 &&
                  $0.id.utf8.allSatisfy({ (33...126).contains($0) }) && qwenStageWireIsSHA256($0.buildSHA256) }),
              configuration.admitsLoadDeadline(now: now),
              (1...1_048_576).contains(configBytes.count),
              (1...4_194_304).contains(manifestBytes.count),
              case let spec = definition.specification,
              identity.configurationSHA256 == spec.configurationSHA256,
              identity.artifactSHA256 == spec.artifactSHA256,
              sha256(configBytes) == spec.configurationSHA256,
              sha256(manifestBytes) == spec.manifestSHA256 else {
            throw ProbeError("Resident load requires a registered model's closed identity, one of its cuts and a bounded local lifetime")
        }
        // Before any model construction or native environment cache is used.
        arithmetic = try definition.arithmetic.admit(environment)
        arithmeticSHA256 = sha256(try canonicalJSONData(arithmetic))
        jaccl = try QwenResidentJACCLConfiguration.admit(environment: environment, read: read)
        guard jaccl.rank == configuration.rank else { throw ProbeError("Resident local rank differs from JACCL") }
        self.configuration = configuration; self.configBytes = configBytes; self.manifestBytes = manifestBytes
        specification = spec; self.definition = definition
        plan = try QwenLayerStagePlan(configuration: configBytes,
            ranges: [0..<configuration.stageCut, configuration.stageCut..<spec.layers], activeMTP: false)
        profile = try QwenResidentAdapterDefinition.profile(specification: spec)
        guard configuration.runtimeProfile == nil || configuration.runtimeProfile == profile.identifier else {
            throw ProbeError("Runtime profile does not match the native text adapter")
        }
        // Recalculate the existing named-state formula at the generation cap;
        // never relabel the separate exact 8192/512/output1 admission receipt.
        let maximum = try QwenLongPrefillTensorBudget.estimate(geometry: spec.expectedGeometry(),
            maximumTokens: profile.maximumContextTokens, chunkSize: profile.maximumChunkTokens)
        let ceilings = try QwenResidentResourceCeilings(specification: spec)
        guard maximum.conservativeStateAndBoundaryBytes <= ceilings.namedStateByteCeiling else {
            throw ProbeError("Resident generation exceeds the model's named-state ceiling")
        }
    }

    func request(_ value: ClusterWorkerReservation, id: UUID, now: UInt64) throws -> QwenLayerStageGenerationRequest {
        guard value.profileID == profile.identifier, value.capacityLimitBytes > 0,
              value.stopTokenIDs == Array(Set(value.stopTokenIDs)).sorted(),
              configuration.admitsRequestDeadline(value.deadlineUptimeNanoseconds, now: now) else {
            throw ProbeError("Resident reservation has wrong profile, stop IDs, capacity or local deadline")
        }
        guard value.mimoImages == nil else { throw ProbeError("Encoded MiMo images cannot enter a foreign model") }
        return try .init(profile: profile, requestID: id, promptTokenIDs: value.promptTokenIDs,
            chunkSize: value.chunkSize, outputCount: value.outputCount, stopTokenIDs: Set(value.stopTokenIDs),
            sampling: value.sampling, route: value.route)
    }

    /// Rank, local path and local uptime are intentionally absent. The explicit
    /// allocator and prefill policies must agree before either stage is loaded.
    func loadAgreementFingerprint() throws -> String {
        let identity = configuration.identity
        return sha256(try canonicalJSONData([
            "qwen-resident-load-v1", identity.membershipEpoch.uuidString.lowercased(), identity.modelID,
            identity.configurationSHA256, identity.artifactSHA256, specification.manifestSHA256,
            plan.fingerprint, profile.fingerprint, arithmeticSHA256, jaccl.fingerprint,
            configuration.allocatorPolicy.rawValue,
        ] + identity.peers.flatMap { [$0.id, $0.buildSHA256] }
            + QwenResidentPrefillSelection.loadAgreementFields(configuration.prefillSchedule)))
    }

    var wireProfile: ClusterWorkerProfile {
        .init(id: profile.identifier, vocabularySize: profile.vocabularySize,
            maximumPromptTokens: profile.maximumPromptTokens, maximumOutputTokens: profile.maximumOutputTokens,
            maximumChunkTokens: profile.maximumChunkTokens, maximumContextTokens: profile.maximumContextTokens)
    }
}
