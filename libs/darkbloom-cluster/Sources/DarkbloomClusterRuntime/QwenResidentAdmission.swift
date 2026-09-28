import DarkbloomClusterProtocol
import Foundation

/// Process-local configuration. Build/peer labels are supplied bindings, not
/// native attestation. The enclosing worker must impose a hard process deadline.
public struct QwenResidentLoadConfiguration: Sendable {
    public let identity: ClusterWorkerIdentity
    public let modelDirectory: URL
    public let rank: Int
    public let stageCut: Int
    public let deadlineUptimeNanoseconds: UInt64
    public let allocatorPolicy: QwenResidentAllocatorPolicy
    public let prefillSchedule: ClusterPrefillSchedule

    public init(identity: ClusterWorkerIdentity, modelDirectory: URL, rank: Int,
                stageCut: Int, deadlineUptimeNanoseconds: UInt64,
                allocatorPolicy: QwenResidentAllocatorPolicy = .unchanged,
                prefillSchedule: ClusterPrefillSchedule = .serial) {
        self.identity = identity; self.modelDirectory = modelDirectory
        self.rank = rank; self.stageCut = stageCut
        self.deadlineUptimeNanoseconds = deadlineUptimeNanoseconds
        self.allocatorPolicy = allocatorPolicy
        self.prefillSchedule = prefillSchedule
    }
}

struct QwenResidentAdmission {
    static let profileID = QwenResidentAdapterDefinition.profileID
    static let maximumLifetimeNanoseconds = QwenResidentAdapterDefinition.maximumLifetimeNanoseconds
    static let maximumRequests = QwenResidentAdapterDefinition.maximumRequests
    let configuration: QwenResidentLoadConfiguration
    let configBytes: Data, manifestBytes: Data
    let specification: QwenDenseRegisteredSpecification
    let plan: QwenLayerStagePlan
    let profile: QwenLayerStageGenerationProfile
    let arithmetic: QwenLongPrefillArithmeticEnvironment.Receipt
    let arithmeticSHA256: String
    let jaccl: QwenResidentJACCLConfiguration

    init(configuration: QwenResidentLoadConfiguration, configBytes: Data, manifestBytes: Data,
         environment: [String: String], now: UInt64,
         read: (URL, Int) throws -> Data) throws {
        let identity = configuration.identity
        guard (0...1).contains(configuration.rank), QwenResidentAdapterDefinition.supportedCuts.contains(configuration.stageCut),
              QwenResidentAdapterDefinition.supportedPrefillSchedules.contains(configuration.prefillSchedule),
              configuration.modelDirectory.isFileURL,
              identity.modelID == QwenRegisteredDenseModel.qwen35NineB.rawValue,
              identity.peers.count == 2, identity.peers[0].id != identity.peers[1].id,
              identity.peers.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 128 &&
                  $0.id.utf8.allSatisfy({ (33...126).contains($0) }) && qwenStageWireIsSHA256($0.buildSHA256) }),
              configuration.deadlineUptimeNanoseconds > now,
              configuration.deadlineUptimeNanoseconds - now <= Self.maximumLifetimeNanoseconds,
              (1...1_048_576).contains(configBytes.count),
              (1...4_194_304).contains(manifestBytes.count),
              let spec = QwenDenseRegisteredSpecification.all.first(where: { $0.model == .qwen35NineB }),
              identity.configurationSHA256 == spec.configurationSHA256,
              identity.artifactSHA256 == spec.artifactSHA256,
              sha256(configBytes) == spec.configurationSHA256,
              sha256(manifestBytes) == spec.manifestSHA256 else {
            throw ProbeError("Resident load requires the closed 9B identity, cut4|8|12|16 and bounded local lifetime")
        }
        // Before any model construction or native environment cache is used.
        arithmetic = try QwenLongPrefillArithmeticEnvironment.admit(environment)
        arithmeticSHA256 = sha256(try canonicalJSONData(arithmetic))
        jaccl = try QwenResidentJACCLConfiguration.admit(environment: environment, read: read)
        guard jaccl.rank == configuration.rank else { throw ProbeError("Resident local rank differs from JACCL") }
        self.configuration = configuration; self.configBytes = configBytes; self.manifestBytes = manifestBytes
        specification = spec
        plan = try QwenLayerStagePlan(configuration: configBytes,
            ranges: [0..<configuration.stageCut, configuration.stageCut..<spec.layers], activeMTP: false)
        profile = try QwenResidentAdapterDefinition.profile(specification: spec)
        // Recalculate the existing named-state formula at the generation cap;
        // never relabel the separate exact 8192/512/output1 admission receipt.
        let maximum = try QwenLongPrefillTensorBudget.estimate(geometry: spec.expectedGeometry(),
            maximumTokens: profile.maximumContextTokens, chunkSize: profile.maximumChunkTokens)
        guard maximum.conservativeStateAndBoundaryBytes <= QwenRegistered9BLongPrefillAdmission.namedTensorByteCeiling else {
            throw ProbeError("Resident generation exceeds the unchanged named-state ceiling")
        }
    }

    func request(_ value: ClusterWorkerReservation, id: UUID, now: UInt64) throws -> QwenLayerStageGenerationRequest {
        guard value.profileID == profile.identifier, value.capacityLimitBytes > 0,
              value.stopTokenIDs == Array(Set(value.stopTokenIDs)).sorted(),
              value.deadlineUptimeNanoseconds > now,
              value.deadlineUptimeNanoseconds <= configuration.deadlineUptimeNanoseconds else {
            throw ProbeError("Resident reservation has wrong profile, stop IDs, capacity or local deadline")
        }
        return try .init(profile: profile, requestID: id, promptTokenIDs: value.promptTokenIDs,
            chunkSize: value.chunkSize, outputCount: value.outputCount, stopTokenIDs: Set(value.stopTokenIDs))
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
