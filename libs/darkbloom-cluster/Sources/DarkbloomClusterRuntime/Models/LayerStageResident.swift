import DarkbloomClusterProtocol
import Foundation
import MLXNN

/// One rank's admitted load of a registered model, whichever family registered
/// it. A family's own admission type makes every check; this is only what the
/// model-independent stage machinery reads from one.
protocol LayerStageResidentAdmission {
    var configuration: QwenResidentLoadConfiguration { get }
    var configBytes: Data { get }
    var manifestBytes: Data { get }
    var runtimeModelID: String { get }
    /// How a request on this model may be divided between the ranks, the pipeline first.
    var supportedGenerationModes: [ClusterGenerationMode] { get }
    var jaccl: QwenResidentJACCLConfiguration { get }
    var plan: QwenLayerStagePlan { get }
    var profile: QwenLayerStageGenerationProfile { get }
    /// The request every LOAD gate of the stage modes charges (default: the profile).
    var memoryProfile: QwenLayerStageGenerationProfile { get }
    var arithmeticContract: String { get }
    var arithmeticSHA256: String { get }
    /// What both ranks compare before either stage is read. Rank, local path
    /// and local uptime are absent; each family keeps its own leading tag.
    func loadAgreementFingerprint() throws -> String
    /// The worker's request admission against this load's profile and deadline.
    func request(_ value: ClusterWorkerReservation, id: UUID, now: UInt64) throws -> QwenLayerStageGenerationRequest
    /// This rank's verified stage. `constructed` receives the model before any
    /// tensor is read, so a weak reference answers for a load that fails part-way.
    func loadResidentStage(check: () throws -> Void,
                           constructed: (Module) -> Void) throws -> any LayerStageResidentStage
}

extension LayerStageResidentAdmission {
    var wireProfile: ClusterWorkerProfile {
        .init(id: profile.identifier, vocabularySize: profile.vocabularySize,
            maximumPromptTokens: profile.maximumPromptTokens, maximumOutputTokens: profile.maximumOutputTokens,
            maximumChunkTokens: profile.maximumChunkTokens, maximumContextTokens: profile.maximumContextTokens)
    }

    /// The profile, unless the family names a smaller memory plan
    /// (`QwenResidentAdmission.memoryProfile`).
    var memoryProfile: QwenLayerStageGenerationProfile { profile }

    /// The layer-stage modes size LOAD for `memoryProfile`, never more: a
    /// longer request is not served by them (their READY's serving context
    /// says so too). Every request within the profile passes when the two are
    /// one profile.
    func requireWithinMemoryProfile(_ value: ClusterWorkerReservation) throws {
        let p = memoryProfile
        guard value.promptTokenIDs.count <= p.maximumPromptTokens, value.outputCount <= p.maximumOutputTokens,
              value.promptTokenIDs.count <= p.maximumContextTokens - value.outputCount else {
            throw ProbeError("A request of \(value.promptTokenIDs.count + value.outputCount) context tokens is longer"
                + " than this mode serves (\(p.maximumContextTokens)); only tensor parallel serves the model's native context")
        }
    }
}

/// One rank's loaded stage and what its family knows about a request's storage.
protocol LayerStageResidentStage {
    var loaded: LoadedQwenLayerStage { get }
    /// The registered model's own ceiling for one request's named state.
    func namedStateByteCeiling() throws -> Int
    /// This rank's named request storage, each array at the allocator's bound.
    func requestAllowance(plan: QwenLayerStagePlan, rank: Int, maximumTokens: Int, chunkSize: Int,
                          bound: (Int) throws -> Int) throws -> QwenResidentRequestAllowance
    /// A recording capture's live gate, bound to this loaded source and to the
    /// allowance the owner reserved.
    func diagnosticResources(plan: QwenLayerStagePlan, request: QwenLayerStageGenerationRequest, rank: Int,
                             requestAllowance: QwenResidentRequestAllowance) throws -> QwenGenerationDiagnosticResources
    /// What a phase-split hand-off is planned from; nil for a family whose
    /// request state does not change owner.
    var handoffGeometry: QwenLongPrefillBudgetGeometry? { get }
}

/// Admits one rank's load through the registered family its identity names.
/// Every family's catalog is closed; a model ID in none of them is refused.
enum LayerStageResidentFamily {
    static func admission(configuration: QwenResidentLoadConfiguration, configBytes: Data, manifestBytes: Data,
                          environment: [String: String], now: UInt64,
                          read: (URL, Int) throws -> Data) throws -> any LayerStageResidentAdmission {
        if Gemma4RegisteredModel(rawValue: configuration.identity.modelID) != nil {
            return try Gemma4ResidentAdmission(configuration: configuration, configBytes: configBytes,
                manifestBytes: manifestBytes, environment: environment, now: now, read: read)
        }
        return try QwenResidentAdmission(configuration: configuration, configBytes: configBytes,
            manifestBytes: manifestBytes, environment: environment, now: now, read: read)
    }
}
