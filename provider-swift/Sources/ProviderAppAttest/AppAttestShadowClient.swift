import Foundation

/// Serializes Apple/keychain work without occupying the serving actor. Reentrant
/// calls get a bounded busy result rather than spawning additional Apple calls.
public actor AppAttestShadowClient {
    private let service: any AppAttestService
    private let storage: any ShadowKeyStorage
    private let scope: String
    private var busy = false
    private var session: String?
    private var record: ShadowKeyRecord?
    private var preparedEnvironment: String?

    public init(scope: String, service: any AppAttestService = AppleAppAttestService(), storage: any ShadowKeyStorage = KeychainShadowKeyStorage()) {
        self.scope = scope; self.service = service; self.storage = storage
    }

    public func respond(to request: AppAttestShadowPayload, publicKey: String) async -> AppAttestShadowPayload {
        var response = AppAttestShadowPayload(action: ["prepare":"ready", "attest":"attestation", "assert":"assertion"][request.action] ?? "error", session: request.session)
        response.keyID = request.keyID
        response.challenge = request.challenge
        guard !busy else { response.result = ShadowFailure.busy.rawValue; return response }
        busy = true
        defer { busy = false }
        do {
            guard request.session.utf8.count == 44, Data(base64Encoded: request.session)?.count == 32,
                  let environment = request.environment, ["production", "development"].contains(environment),
                  Data(base64Encoded: publicKey)?.count == 32 else { throw ShadowFailure.invalidRequest }
            try Task.checkCancellation()
            if request.action == "prepare" {
                try await service.checkAvailability(environment: environment)
                let keyScope = scope + ":" + environment
                var key = try storage.load(scope: keyScope)
                if key == nil || key?.keyID.isEmpty == true {
                    // An unregistered/invalid old key may be replaced at most hourly,
                    // including across restarts; never generate keys in a retry loop.
                    if let key, Date().timeIntervalSince(key.createdAt) < 3600 { throw ShadowFailure.busy }
                    // Establish writable persistence and record the generation budget
                    // BEFORE asking Apple for a key. A locked/broken Keychain must not
                    // create an unrecorded key on every reconnect.
                    let pending = ShadowKeyRecord(keyID: "", attested: false, createdAt: Date())
                    try storage.save(pending, scope: keyScope)
                    let id = try await service.generateKey()
                    key = ShadowKeyRecord(keyID: id, attested: false, createdAt: pending.createdAt)
                    try storage.save(key!, scope: keyScope)
                }
                record = key; session = request.session; preparedEnvironment = environment
                response.keyID = key?.keyID
            } else {
                guard session == request.session, preparedEnvironment == environment,
                      var key = record, key.keyID == request.keyID,
                      let challenge = request.challenge, Data(base64Encoded: challenge)?.count == 32
                else { throw ShadowFailure.invalidRequest }
                let hash = request.clientHash(publicKey: publicKey)
                if request.action == "attest" {
                    guard !key.attested else {
                        key.keyID = ""; record = key
                        try storage.save(key, scope: scope + ":" + environment)
                        throw ShadowFailure.keyUnregistered
                    }
                    // Retry only an unavailable Apple service, with the SAME key/hash.
                    var proof: Data?
                    for attempt in 0..<3 {
                        do { proof = try await service.attestKey(key.keyID, hash: hash); break }
                        catch ShadowFailure.appleUnavailable where attempt < 2 {
                            try await Task.sleep(for: .seconds(attempt == 0 ? 2 : 8))
                        }
                    }
                    guard let proof, proof.count <= 32*1024 else { throw ShadowFailure.appleError }
                    key.attested = true; record = key
                    try storage.save(key, scope: scope + ":" + environment)
                    response.proof = proof.base64EncodedString()
                } else if request.action == "assert" {
                    // The coordinator may have persisted an attestation whose local
                    // acknowledgement was lost. A real assertion establishes usability.
                    let proof = try await service.generateAssertion(key.keyID, hash: hash)
                    guard proof.count <= 32*1024 else { throw ShadowFailure.appleError }
                    if !key.attested { key.attested = true; record = key; try storage.save(key, scope: scope + ":" + environment) }
                    response.proof = proof.base64EncodedString()
                } else { throw ShadowFailure.invalidRequest }
            }
            try Task.checkCancellation()
            response.result = "ok"
        } catch {
            let failure = error is CancellationError ? ShadowFailure.cancelled : (error as? ShadowFailure ?? .appleError)
            if failure == .appleInvalidKey, var key = record, let environment = preparedEnvironment {
                key.keyID = ""; record = key
                try? storage.save(key, scope: scope + ":" + environment)
            }
            response.result = failure.rawValue
        }
        return response
    }
}
