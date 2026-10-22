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

    /// Pure startup policy, before the process-wide measurement is enabled.
    /// Record-only measurement enforces every memory decision and is allowed;
    /// an image candidate may never request or inherit a refusal waiver.
    /// Other profiles retain their existing standalone qualification policy.
    static func memoryMeasurementMode(runtimeProfile: String?, environment: [String: String],
                                      existingModeWaivesRefusals: Bool) throws -> QwenDenseStageLoadMeasurement.Mode? {
        let requested = try QwenDenseStageLoadMeasurement.requested(environment: environment)
        guard runtimeProfile != ClusterMiMoImageCandidate.profileID
            || (requested != .measure && !existingModeWaivesRefusals) else {
            throw ProbeError("MiMo image candidate requires enforced host memory gates; measure mode or an active waiver is refused")
        }
        return requested
    }

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
              configuration.admitsLoadDeadline(now: now),
              (1...1_048_576).contains(configBytes.count), (1...4_194_304).contains(manifestBytes.count),
              identity.configurationSHA256 == spec.configurationSHA256,
              identity.artifactSHA256 == spec.artifactSHA256,
              sha256(configBytes) == spec.configurationSHA256,
              sha256(manifestBytes) == spec.manifestSHA256 else {
            throw ProbeError("Resident MiMo load requires the registered model's closed identity, one of its cuts, "
                + "one of its prefill schedules and a bounded local lifetime")
        }
        // Before any model construction or native environment cache is used.
        arithmetic = try MiMoArithmeticEnvironment.admit(environment)
        arithmeticSHA256 = sha256(try canonicalJSONData(arithmetic))
        jaccl = try QwenResidentJACCLConfiguration.admit(environment: environment, read: read)
        guard jaccl.rank == configuration.rank else { throw ProbeError("Resident local rank differs from JACCL") }
        self.configuration = configuration; self.configBytes = configBytes; self.manifestBytes = manifestBytes
        specification = spec
        guard environment["DARKBLOOM_CLUSTER_MIMO_VISION_DRAFT"] == nil,
              configuration.runtimeProfile == nil || configuration.runtimeProfile == spec.profileID
                || configuration.runtimeProfile == ClusterMiMoImageCandidate.profileID else {
            throw ProbeError("MiMo media selection requires the exact bound runtime profile; environment opt-ins are refused")
        }
        let imageCandidate = configuration.runtimeProfile == ClusterMiMoImageCandidate.profileID
        plan = try MiMoLayerStagePlan(configuration: configBytes, cut: configuration.stageCut,visionEnabled:imageCandidate)
        profile = try spec.profile(imageCandidate:imageCandidate)
    }

    /// `decodingRankHoldsEveryLayer`: the loaded mode is a phase split, whose
    /// decoding rank holds every layer and may serve a request alone.
    func request(_ value: ClusterWorkerReservation, id: UUID, now: UInt64,
                 decodingRankHoldsEveryLayer: Bool = false) throws -> QwenLayerStageGenerationRequest {
        guard value.profileID == profile.identifier, value.capacityLimitBytes > 0,
              value.stopTokenIDs == Array(Set(value.stopTokenIDs)).sorted(),
              configuration.admitsRequestDeadline(value.deadlineUptimeNanoseconds, now: now) else {
            throw ProbeError("Resident reservation has wrong profile, stop IDs, capacity or local deadline")
        }
        if let media = value.mimoImages {
            guard plan.visionEnabled, !decodingRankHoldsEveryLayer, value.route == nil else {
                throw ProbeError("MiMo images require the rank-0 native vision pipeline")
            }
            try media.validate(prompt:value.promptTokenIDs)
        }
        // Only a phase split's decoding rank holds every layer; under a pipeline
        // every request uses the pair.
        guard value.route == nil || decodingRankHoldsEveryLayer else {
            throw ProbeError("Under a pipeline no MiMo rank holds every layer: no request is served on one rank alone")
        }
        return try .init(profile: profile, requestID: id, promptTokenIDs: value.promptTokenIDs,
            chunkSize: value.chunkSize, outputCount: value.outputCount, stopTokenIDs: Set(value.stopTokenIDs),
            sampling: value.sampling, route: value.route, mimoImages:value.mimoImages)
    }

    /// Rank, local path and local uptime are intentionally absent. Everything
    /// both ranks must have been told the same is here, before either loads.
    func loadAgreementFingerprint(mode: QwenResidentGenerationMode, transport: ClusterTransport,
                                  residency: Bool, measuredGate: Bool, speculative: MiMoMTPTerms? = nil) throws -> String {
        let identity = configuration.identity
        return sha256(try canonicalJSONData([
            "mimo-resident-load-v1", identity.membershipEpoch.uuidString.lowercased(), identity.modelID,
            identity.configurationSHA256, identity.artifactSHA256, specification.manifestSHA256,
            plan.fingerprint, profile.fingerprint, arithmeticSHA256, jaccl.fingerprint,
            configuration.allocatorPolicy.rawValue, configuration.prefillSchedule.rawValue,
            mode.rawValue, transport.rawValue,
        ] + (speculative?.loadAgreementFields ?? []) + [
            // Each rank's own limit differs with its stage; the policy both run under is common.
            "residency=\(residency ? ClusterStageResidency.policy : "off")", "measuredGate=\(measuredGate)",
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
    /// Rank 1 of `pipeline_mtp_v1`: the speculative head's request state at
    /// the allocator's bound (`MiMoMTPHead.requestBytes`); 0 otherwise.
    var speculativeBytes = 0
    var imageBytes = 0
    var reservedBytes: Int { budget.reservedBytes + speculativeBytes + imageBytes }
    let watch = QwenDenseStageLoadWatch("Resident request")

    /// `phaseSplit`: rank 1 holds the state of every layer (its own range and
    /// the producer's it adopts or prefills alone), and the producer's state
    /// exists on both sides while it moves (`handoffBytes`, on each rank).
    static func derive(specification: MiMoRegisteredSpecification, plan: MiMoLayerStagePlan, rank: Int,
                       maximumTokens: Int, chunkSize: Int, phaseSplit: Bool = false,
                       speculativeBytes: Int = 0,imageCandidate: Bool = false) throws -> Self {
        guard plan.stages.count == 2, (0...1).contains(rank) else {
            throw ProbeError("Resident MiMo request allowance requires an admitted two-stage Plan")
        }
        guard speculativeBytes >= 0, speculativeBytes == 0 || (rank == 1 && !phaseSplit) else {
            throw ProbeError("Only the last rank of a speculative pipeline holds a speculative head's request state")
        }
        let layers = phaseSplit && rank == 1 ? 0..<plan.stages[1].sourceRange.upperBound : plan.stages[rank].sourceRange
        let own = try MiMoRequestStateBudget.estimate(specification: specification, layers: layers,
            rank: rank, maximumTokens: maximumTokens, chunkSize: chunkSize,
            bound: QwenResidentResourceEnvironment.allocationBound)
        guard phaseSplit else { return .init(budget: own, speculativeBytes: speculativeBytes,
            imageBytes:imageCandidate ? (rank == 0 ? ClusterMiMoImageCandidate.activationFloorBytes : ClusterMiMoImageCandidate.wireWorkingReserveBytes) : 0) }
        let moving = try MiMoRequestStateBudget.estimate(specification: specification, layers: plan.stages[0].sourceRange,
            rank: 0, maximumTokens: maximumTokens, chunkSize: chunkSize, bound: QwenResidentResourceEnvironment.allocationBound)
        return .init(budget: try own.adding(handoffBytes: try QwenLongPrefillCheckedBytes.sum([
            moving.fullAttentionStateBytes, moving.slidingStateBytes])))
    }

    /// `additionalNativeBytes`: what the request may add beyond its state
    /// (its prompt-prefix capture), charged in both checks.
    func requireLive(additionalNativeBytes: Int = 0) throws {
        try QwenResidentResourceEnvironment.require()
        guard additionalNativeBytes >= 0 else { throw ProbeError("Resident MiMo request charge is negative") }
        let os = try QwenDenseStageLoadResources.observeOS()
        let free = max(QwenDenseStageLoadPolicy.minimumAdmissibleBytes,
            try QwenLongPrefillCheckedBytes.sum([reservedBytes, additionalNativeBytes,
                QwenDenseStageLoadPolicy.loadingHeadroomBytes]))
        let allocator = try QwenLongPrefillCheckedBytes.sum([QwenDenseStageLoadResources.observeNative().activeBytes,
            QwenDenseStageLoadResources.observeNative().cacheBytes, reservedBytes, additionalNativeBytes,
            QwenDenseStageLoadPolicy.allocatorHeadroomBytes])
        guard try watch.admits(os, bytes: free) else { throw ProbeError("Resident MiMo request was refused") }
        guard QwenDenseStageLoadResources.observeNative().allocatorLimitBytes >= allocator else {
            throw ProbeError("Resident MiMo request exceeds the allocator limit")
        }
    }
}
