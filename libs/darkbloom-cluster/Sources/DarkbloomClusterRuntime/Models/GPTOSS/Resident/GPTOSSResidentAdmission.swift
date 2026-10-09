import DarkbloomClusterProtocol
import Foundation

/// Admission of one rank of a resident GPT-OSS pair from its launch arguments,
/// the artifact's own configuration and manifest bytes and the process
/// environment. CPU only: nothing is hashed, constructed or allocated.
struct GPTOSSResidentAdmission {
    let configuration: QwenResidentLoadConfiguration
    let configBytes: Data, manifestBytes: Data
    let specification: GPTOSSRegisteredSpecification
    let plan: GPTOSSLayerStagePlan
    let profile: QwenLayerStageGenerationProfile
    let arithmetic: GPTOSSArithmeticEnvironment.Receipt
    let arithmeticSHA256: String
    let jaccl: QwenResidentJACCLConfiguration

    init(configuration: QwenResidentLoadConfiguration, configBytes: Data, manifestBytes: Data,
         environment: [String: String], now: UInt64, read: (URL, Int) throws -> Data) throws {
        let identity = configuration.identity
        // The identity's model ID selects one row of the closed catalog.
        guard let spec = try? GPTOSSRegisteredSpecification.specification(runtimeModelID: identity.modelID),
              (0...1).contains(configuration.rank), spec.supportedCuts.contains(configuration.stageCut),
              spec.supportedPrefillSchedules.contains(configuration.prefillSchedule),
              configuration.modelDirectory.isFileURL,
              identity.peers.count == 2, identity.peers[0].id != identity.peers[1].id,
              identity.peers.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 128 &&
                  $0.id.utf8.allSatisfy({ (33...126).contains($0) }) && qwenStageWireIsSHA256($0.buildSHA256) }),
              configuration.deadlineUptimeNanoseconds > now,
              configuration.deadlineUptimeNanoseconds - now <= GPTOSSRegisteredSpecification.maximumLifetimeNanoseconds,
              (1...1_048_576).contains(configBytes.count), (1...4_194_304).contains(manifestBytes.count),
              identity.configurationSHA256 == spec.configurationSHA256,
              identity.artifactSHA256 == spec.artifactSHA256,
              sha256(configBytes) == spec.configurationSHA256,
              sha256(manifestBytes) == spec.manifestSHA256 else {
            throw ProbeError("Resident GPT-OSS load requires the registered model's closed identity, one of its cuts and a bounded local lifetime")
        }
        // Before any model construction or native environment cache is used.
        arithmetic = try GPTOSSArithmeticEnvironment.admit(environment)
        arithmeticSHA256 = sha256(try canonicalJSONData(arithmetic))
        jaccl = try QwenResidentJACCLConfiguration.admit(environment: environment, read: read)
        guard jaccl.rank == configuration.rank else { throw ProbeError("Resident local rank differs from JACCL") }
        try spec.requireManifest(manifestBytes, configuration: configBytes)
        self.configuration = configuration; self.configBytes = configBytes; self.manifestBytes = manifestBytes
        specification = spec
        plan = try GPTOSSLayerStagePlan(configuration: configBytes, cut: configuration.stageCut)
        profile = try spec.profile()
        // The largest request this row admits must fit the row's own state ledger.
        for rank in 0...1 {
            _ = try GPTOSSRequestStateBudget.estimate(specification: spec, layers: plan.stages[rank].layers,
                rank: rank, maximumTokens: profile.maximumContextTokens, chunkSize: profile.maximumChunkTokens,
                bound: { $0 })
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

    /// Rank, local path and local uptime are intentionally absent. Everything
    /// both ranks must have been told the same is here, before either loads.
    func loadAgreementFingerprint(mode: QwenResidentGenerationMode, transport: ClusterTransport) throws -> String {
        let identity = configuration.identity
        return sha256(try canonicalJSONData([
            "gpt-oss-resident-load-v1", identity.membershipEpoch.uuidString.lowercased(), identity.modelID,
            identity.configurationSHA256, identity.artifactSHA256, specification.manifestSHA256,
            plan.fingerprint, profile.fingerprint, arithmeticSHA256, jaccl.fingerprint,
            configuration.allocatorPolicy.rawValue, configuration.prefillSchedule.rawValue,
            mode.rawValue, transport.rawValue,
        ] + identity.peers.flatMap { [$0.id, $0.buildSHA256] }))
    }

    var wireProfile: ClusterWorkerProfile {
        .init(id: profile.identifier, vocabularySize: profile.vocabularySize,
            maximumPromptTokens: profile.maximumPromptTokens, maximumOutputTokens: profile.maximumOutputTokens,
            maximumChunkTokens: profile.maximumChunkTokens, maximumContextTokens: profile.maximumContextTokens)
    }

    /// The admission this rank's worker would pass on this Mac for a tool
    /// that creates no collective: a synthetic device matrix nothing opens,
    /// and no transport environment. The arithmetic environment is the actual
    /// process environment, because MLX reads those values itself.
    static func local(modelDirectory: URL, rank: Int, stageCut: Int, deadlineUptimeNanoseconds: UInt64,
                      identity: ClusterWorkerIdentity? = nil, label: String,
                      allocatorPolicy: QwenResidentAllocatorPolicy = .unchanged) throws -> Self {
        let nativeNames = ["JACCL_RANK", "MLX_RANK", "JACCL_IBV_DEVICES", "MLX_IBV_DEVICES",
            "JACCL_COORDINATOR", "MLX_JACCL_COORDINATOR", "JACCL_RING", "MLX_JACCL_RING"]
        var environment = ProcessInfo.processInfo.environment
        guard nativeNames.allSatisfy({ environment[$0] == nil }) else {
            throw ProbeError("\(label) refuses a cluster transport environment; it creates no collective")
        }
        let matrixPath = "/var/empty/darkbloom-\(label).matrix.json"
        let matrix = Data(#"[[null,"\#(label)-0"],["\#(label)-1",null]]"#.utf8)
        environment["JACCL_RANK"] = String(rank)
        environment["JACCL_IBV_DEVICES"] = matrixPath
        environment["JACCL_COORDINATOR"] = "127.0.0.1:1"
        let configBytes = try BoundedProbeInput.data(modelDirectory.appendingPathComponent("config.json"),
                                                    maximumBytes: 1_048_576)
        let spec = try GPTOSSRegisteredSpecification.specification(configuration: configBytes)
        let identity = identity ?? Self.localIdentity(spec, label: label)
        return try .init(configuration: .init(identity: identity, modelDirectory: modelDirectory, rank: rank,
                stageCut: stageCut, deadlineUptimeNanoseconds: deadlineUptimeNanoseconds, allocatorPolicy: allocatorPolicy),
            configBytes: configBytes,
            manifestBytes: BoundedProbeInput.data(modelDirectory.appendingPathComponent("manifest.json"),
                                                  maximumBytes: 4_194_304),
            environment: environment, now: DispatchTime.now().uptimeNanoseconds,
            read: { url, limit in url.path == matrixPath ? matrix : try BoundedProbeInput.data(url, maximumBytes: limit) })
    }

    static func localIdentity(_ spec: GPTOSSRegisteredSpecification, label: String) -> ClusterWorkerIdentity {
        .init(membershipEpoch: UUID(), modelID: spec.model.rawValue, artifactSHA256: spec.artifactSHA256,
            configurationSHA256: spec.configurationSHA256,
            peers: (0...1).map { ClusterWorkerPeer(id: "\(label)-\($0)", buildSHA256: String(repeating: "0", count: 64)) })
    }
}

/// One request's named allowance on one rank, and its live check at the host
/// memory gate: the allowance plus the loading headroom must be admissible,
/// and the allocator limit must cover what is resident plus the allowance.
struct GPTOSSResidentRequestAllowance {
    let budget: GPTOSSRequestStateBudget
    var reservedBytes: Int { budget.reservedBytes }
    /// This request's record at the host memory gate, and its first sample.
    let watch = QwenDenseStageLoadWatch("Resident request")

    static func derive(plan: GPTOSSLayerStagePlan, rank: Int, maximumTokens: Int, chunkSize: Int) throws -> Self {
        guard plan.stages.count == 2, (0...1).contains(rank) else {
            throw ProbeError("Resident GPT-OSS request allowance requires an admitted two-stage Plan")
        }
        return .init(budget: try .estimate(specification: plan.specification, layers: plan.stages[rank].layers,
            rank: rank, maximumTokens: maximumTokens, chunkSize: chunkSize,
            bound: QwenResidentResourceEnvironment.allocationBound))
    }

    func requireLive(additionalNativeBytes: Int = 0, additionalHostBytes: Int = 0) throws {
        guard additionalNativeBytes >= 0, additionalHostBytes >= 0 else {
            throw ProbeError("Invalid additional resident allowance")
        }
        try QwenResidentResourceEnvironment.require()
        let os = try QwenDenseStageLoadResources.observeOS()
        let native = QwenDenseStageLoadResources.observeNative()
        let free = max(QwenDenseStageLoadPolicy.minimumAdmissibleBytes,
            try QwenLongPrefillCheckedBytes.sum([reservedBytes, additionalNativeBytes, additionalHostBytes,
                QwenDenseStageLoadPolicy.loadingHeadroomBytes]))
        let allocator = try QwenLongPrefillCheckedBytes.sum([native.activeBytes, native.cacheBytes,
            reservedBytes, additionalNativeBytes, QwenDenseStageLoadPolicy.allocatorHeadroomBytes])
        guard try watch.admits(os, bytes: free) else { throw ProbeError("Resident GPT-OSS request was refused") }
        guard native.allocatorLimitBytes >= allocator else {
            throw ProbeError("Resident GPT-OSS request exceeds the allocator limit")
        }
    }
}
