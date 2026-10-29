import Foundation

/// Mutable fields belong exclusively to DistributedLocalServer's actor. The
/// session and response registry already synchronize their independent work.
final class DistributedLocalServerGeneration: @unchecked Sendable {
    let id: UUID
    let session: any DistributedLocalServerSession
    let responses: DistributedHTTPResponses
    var entry: MultiModelBatchSchedulerEngine.ModelRegistryEntry?
    var pin: UUID?
    var ownerStopTask: Task<Void, Never>?
    var pinWaiters: [CheckedContinuation<Void, Never>] = []

    init(session: any DistributedLocalServerSession) {
        let id = UUID(); self.id = id; self.session = session
        responses = DistributedHTTPResponses(generationID: id)
    }
}

/// Exact stable public/native/configuration identity; membership epoch is the
/// one field intentionally replaced. Installed sessions also carry the full
/// existing saved-configuration/capability binding.
struct DistributedLocalSessionBinding: Equatable, Sendable {
    let installed: ClusterStatusBinding?
    let publicModelID: String
    let directory: URL
    let modelType: String
    let eosTokenIDs: Set<Int>
    let modelVocabularySize: Int
    let runtimeModelID: String
    let artifactSHA256: String
    let configurationSHA256: String
    let peers: [DistributedResidentIdentity.Peer]
    let profileID: String
    let vocabularySize: Int
    let maxPromptTokens: Int
    let maxOutputTokens: Int
    let maxContextTokens: Int
    let requestTimeout: Duration

    init(_ session: any DistributedLocalServerSession) {
        installed = session.httpInstalledBinding
        publicModelID = session.model.publicModelID; directory = session.model.directory
        modelType = session.model.modelType; eosTokenIDs = session.model.eosTokenIDs
        modelVocabularySize = session.model.vocabularySize
        runtimeModelID = session.expectedIdentity.modelID
        artifactSHA256 = session.expectedIdentity.artifactSHA256
        configurationSHA256 = session.expectedIdentity.configurationSHA256
        peers = session.expectedIdentity.peers
        profileID = session.profile.id; vocabularySize = session.profile.vocabularySize
        maxPromptTokens = session.profile.maxPromptTokens; maxOutputTokens = session.profile.maxOutputTokens
        maxContextTokens = session.profile.maxContextTokens; requestTimeout = session.profile.requestTimeout
    }
}
