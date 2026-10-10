import DarkbloomClusterProtocol
import Foundation

/// Admission of one rank of a resident MiMo pair from its launch arguments,
/// the artifact's own configuration and manifest bytes and the process
/// environment. CPU only: nothing is hashed, constructed or allocated.
struct MiMoResidentAdmission {
    let configuration: QwenResidentLoadConfiguration
    let configBytes: Data, manifestBytes: Data
    let specification: MiMoRegisteredSpecification
    let plan: MiMoLayerStagePlan
    let profile: QwenLayerStageGenerationProfile
    let arithmetic: MiMoArithmeticEnvironment.Receipt
    let arithmeticSHA256: String
    let jaccl: QwenResidentJACCLConfiguration

    init(configuration: QwenResidentLoadConfiguration, configBytes: Data, manifestBytes: Data,
         environment: [String: String], now: UInt64, read: (URL, Int) throws -> Data) throws {
        let identity = configuration.identity
        // The identity's model ID selects one row of the closed catalog.
        guard let spec = try? MiMoRegisteredSpecification.specification(runtimeModelID: identity.modelID),
              (0...1).contains(configuration.rank), spec.supportedCuts.contains(configuration.stageCut),
              spec.supportedPrefillSchedules.contains(configuration.prefillSchedule),
              configuration.modelDirectory.isFileURL,
              identity.peers.count == 2, identity.peers[0].id != identity.peers[1].id,
              identity.peers.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 128 &&
                  $0.id.utf8.allSatisfy({ (33...126).contains($0) }) && qwenStageWireIsSHA256($0.buildSHA256) }),
              configuration.deadlineUptimeNanoseconds > now,
              configuration.deadlineUptimeNanoseconds - now <= MiMoRegisteredSpecification.maximumLifetimeNanoseconds,
              (1...1_048_576).contains(configBytes.count), (1...4_194_304).contains(manifestBytes.count),
              identity.configurationSHA256 == spec.configurationSHA256,
              identity.artifactSHA256 == spec.artifactSHA256,
              sha256(configBytes) == spec.configurationSHA256,
              sha256(manifestBytes) == spec.manifestSHA256 else {
            throw ProbeError("Resident MiMo load requires the registered model's closed identity, one of its cuts, "
                + "the serial prefill schedule and a bounded local lifetime")
        }
        // Before any model construction or native environment cache is used.
        arithmetic = try MiMoArithmeticEnvironment.admit(environment)
        arithmeticSHA256 = sha256(try canonicalJSONData(arithmetic))
        jaccl = try QwenResidentJACCLConfiguration.admit(environment: environment, read: read)
        guard jaccl.rank == configuration.rank else { throw ProbeError("Resident local rank differs from JACCL") }
        self.configuration = configuration; self.configBytes = configBytes; self.manifestBytes = manifestBytes
        specification = spec
        plan = try MiMoLayerStagePlan(configuration: configBytes, cut: configuration.stageCut)
        profile = try spec.profile()
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

    /// Rank, local path and local uptime are intentionally absent. Everything
    /// both ranks must have been told the same is here, before either loads.
    func loadAgreementFingerprint(mode: QwenResidentGenerationMode, transport: ClusterTransport,
                                  residency: Bool, measuredGate: Bool) throws -> String {
        let identity = configuration.identity
        return sha256(try canonicalJSONData([
            "mimo-resident-load-v1", identity.membershipEpoch.uuidString.lowercased(), identity.modelID,
            identity.configurationSHA256, identity.artifactSHA256, specification.manifestSHA256,
            plan.fingerprint, profile.fingerprint, arithmeticSHA256, jaccl.fingerprint,
            configuration.allocatorPolicy.rawValue, configuration.prefillSchedule.rawValue,
            mode.rawValue, transport.rawValue,
            // Each rank's own limit differs with its stage; the policy both run under is common.
            "residency=\(residency ? MiMoStageResidency.policy : "off")", "measuredGate=\(measuredGate)",
        ] + identity.peers.flatMap { [$0.id, $0.buildSHA256] }))
    }

    var wireProfile: ClusterWorkerProfile {
        .init(id: profile.identifier, vocabularySize: profile.vocabularySize,
            maximumPromptTokens: profile.maximumPromptTokens, maximumOutputTokens: profile.maximumOutputTokens,
            maximumChunkTokens: profile.maximumChunkTokens, maximumContextTokens: profile.maximumContextTokens)
    }
}

/// One request's named allowance on one rank, and its live check at the host
/// memory gate: the allowance plus the loading headroom must be admissible,
/// and the allocator limit must cover what is resident plus the allowance.
struct MiMoResidentRequestAllowance {
    let budget: MiMoRequestStateBudget
    var reservedBytes: Int { budget.reservedBytes }
    let watch = QwenDenseStageLoadWatch("Resident request")

    static func derive(specification: MiMoRegisteredSpecification, plan: MiMoLayerStagePlan, rank: Int,
                       maximumTokens: Int, chunkSize: Int) throws -> Self {
        guard plan.stages.count == 2, (0...1).contains(rank) else {
            throw ProbeError("Resident MiMo request allowance requires an admitted two-stage Plan")
        }
        return .init(budget: try .estimate(specification: specification, layers: plan.stages[rank].sourceRange,
            rank: rank, maximumTokens: maximumTokens, chunkSize: chunkSize,
            bound: QwenResidentResourceEnvironment.allocationBound))
    }

    func requireLive() throws {
        try QwenResidentResourceEnvironment.require()
        let os = try QwenDenseStageLoadResources.observeOS()
        let free = max(QwenDenseStageLoadPolicy.minimumAdmissibleBytes,
            try QwenLongPrefillCheckedBytes.sum([reservedBytes, QwenDenseStageLoadPolicy.loadingHeadroomBytes]))
        let allocator = try QwenLongPrefillCheckedBytes.sum([QwenDenseStageLoadResources.observeNative().activeBytes,
            QwenDenseStageLoadResources.observeNative().cacheBytes, reservedBytes,
            QwenDenseStageLoadPolicy.allocatorHeadroomBytes])
        guard try watch.admits(os, bytes: free) else { throw ProbeError("Resident MiMo request was refused") }
        guard QwenDenseStageLoadResources.observeNative().allocatorLimitBytes >= allocator else {
            throw ProbeError("Resident MiMo request exceeds the allocator limit")
        }
    }
}
