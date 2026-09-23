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
    private var preparedScope: String?
    private var preparedAccountScope: String?
    private var preparedProtocol: Int?

    public init(scope: String, service: any AppAttestService = AppleAppAttestService(), storage: any ShadowKeyStorage = KeychainShadowKeyStorage()) {
        self.scope = scope; self.service = service; self.storage = storage
    }

    public func respond(to request: AppAttestShadowPayload, publicKey: String, status: AppAttestStatus? = nil) async -> AppAttestShadowPayload {
        var response = AppAttestShadowPayload(action: ["prepare":"ready", "attest":"attestation", "assert":"assertion"][request.action] ?? "error", session: request.session)
        response.protocolVersion=request.protocolVersion
        response.keyID = request.keyID
        response.challenge = request.challenge
        guard !busy else { response.result = ShadowFailure.busy.rawValue; return response }
        busy = true
        defer { busy = false }
        var calledAttestation = false
        do {
            guard request.protocolVersion == nil || [1,2,3].contains(request.protocolVersion ?? 0),
                  request.session.utf8.count == 44, Data(base64Encoded: request.session)?.count == 32,
                  let environment = request.environment, ["production", "development"].contains(environment),
                  Data(base64Encoded: publicKey)?.count == 32 else { throw ShadowFailure.invalidRequest }
            try Task.checkCancellation()
            if request.action == "prepare" {
                try await service.checkAvailability(environment: environment)
                if [2,3].contains(request.protocolVersion ?? 0) {
                    guard let accountScope=request.accountScope, accountScope.utf8.count == 64 else { throw ShadowFailure.invalidRequest }
                }
                let keyScope = scope + ":" + environment + ([2,3].contains(request.protocolVersion ?? 0) ? ":account:" + (request.accountScope ?? "") : "")
                var key = try storage.load(scope: keyScope)
                if var interrupted = key, interrupted.attestationStartedAt != nil, interrupted.pendingProof == nil {
                    interrupted.retireEnrollment()
                    try storage.save(interrupted, scope: keyScope)
                    key = interrupted
                }
                if var stale = key, let attempt = stale.retryEnrollment,
                   !attempt.canResume(keyID: stale.keyID, session: request.session, protocolVersion: request.protocolVersion, now: Date()) {
                    stale.retireEnrollment()
                    try storage.save(stale, scope: keyScope)
                    key = stale
                }
                if var expired=key, expired.pendingProof != nil, Date().timeIntervalSince(expired.pendingCreatedAt ?? expired.createdAt)>86400 {
                    expired.retireEnrollment()
                    try storage.save(expired,scope:keyScope); key=expired
                }
                if key == nil || key?.keyID.isEmpty == true {
                    // An unregistered/invalid old key may be replaced at most hourly,
                    // including across restarts. A failed generateKey that returned
                    // no identifier may be retried sooner under the shared budget.
                    if let key, !key.mayGenerateKey(at: Date()) { throw ShadowFailure.busy }
                    // Record the generation budget and establish writable key
                    // persistence BEFORE asking Apple for a key. Budget I/O goes
                    // first so its failure cannot leave a new empty key marker
                    // that strands an otherwise healthy device for an hour.
                    var pending = ShadowKeyRecord(keyID: "", attested: false, createdAt: Date())
                    // Persist a shared budget across account scopes as well as the
                    // per-key cooldown, so account churn cannot bypass it.
                    let budgetScope=scope+":"+environment+":generation-budget"
                    let oldBudget=try storage.load(scope:budgetScope)
                    var budget=oldBudget ?? ShadowKeyRecord(keyID:"budget",attested:false,createdAt:Date())
                    if Date().timeIntervalSince(budget.createdAt)>=3600 { budget.createdAt=Date(); budget.generationCount=0 }
                    guard (budget.generationCount ?? 0)<5 else { throw ShadowFailure.busy }
                    budget.generationCount=(budget.generationCount ?? 0)+1
                    try storage.save(budget,scope:budgetScope)
                    try storage.save(pending, scope: keyScope)
                    let id: String
                    do {
                        id = try await service.generateKey()
                    } catch {
                        // The pre-call marker and budget were already persisted.
                        // Only Apple's completed error callback with no key ID
                        // permits a shorter retry. Cancellation, local admission
                        // and timeout are uncertain and retain the hour marker.
                        if mayRetryKeyGeneration(after: error) {
                            pending.generationRetryAfter = Date().addingTimeInterval(60)
                            try storage.save(pending, scope: keyScope)
                        }
                        throw error
                    }
                    key = ShadowKeyRecord(keyID: id, attested: false, createdAt: pending.createdAt)
                    try storage.save(key!, scope: keyScope)
                }
                record = key; session = request.session; preparedEnvironment = environment; preparedScope = keyScope; preparedAccountScope=request.accountScope; preparedProtocol=request.protocolVersion
                response.keyID = key?.keyID
            } else {
                guard session == request.session, preparedEnvironment == environment, preparedProtocol == request.protocolVersion, preparedAccountScope == request.accountScope,
                      var key = record, key.keyID == request.keyID,
                      let challenge = request.challenge, Data(base64Encoded: challenge)?.count == 32
                else { throw ShadowFailure.invalidRequest }
                guard let keyScope=preparedScope else { throw ShadowFailure.invalidRequest }
                var signedRequest=request
                if [2,3].contains(request.protocolVersion ?? 0) {
                    guard let status else { throw ShadowFailure.invalidRequest }
                    signedRequest.status=status; response.status=status
                }
                let hash = signedRequest.clientHash(publicKey: publicKey)
                if request.action == "attest" {
                    if [2,3].contains(request.protocolVersion ?? 0), let proof=key.pendingProof, let enrollment=key.pendingEnrollment {
                        response.proof=proof; response.enrollmentSession=enrollment; response.status=key.pendingStatus
                        response.result="ok"; return response
                    }
                    guard !key.attested else {
                        key.keyID = ""; record = key
                        try storage.save(key, scope: keyScope)
                        throw ShadowFailure.keyUnregistered
                    }
                    // Retry only an unavailable Apple service, with the SAME key/hash.
                    // Persist the original transcript across coordinator retries,
                    // reconnects and upgrades, not just the immediate loop below.
                    let enrollment = key.retryEnrollment ?? ShadowEnrollmentAttempt(
                        keyID: key.keyID, clientHash: hash, session: request.session,
                        protocolVersion: request.protocolVersion, status: status, createdAt: Date())
                    key.retryEnrollment = enrollment
                    var proof: Data?
                    for attempt in 0..<3 {
                        do {
                            key.attestationStartedAt = Date()
                            try storage.save(key, scope: keyScope)
                            record = key
                            calledAttestation = true
                            proof = try await service.attestKey(key.keyID, hash: enrollment.clientHash)
                            break
                        } catch where appAttestFailure(error) == .appleUnavailable && attempt < 2 {
                            // Apple answered: this key is safe to retry. A
                            // cancellation/crash during backoff is not an
                            // interrupted one-time call and must not retire it.
                            calledAttestation = false
                            key.attestationStartedAt = nil
                            record = key
                            try storage.save(key, scope: keyScope)
                            try await appAttestSleep(seconds: attempt == 0 ? 2 : 8)
                        }
                    }
                    guard let proof, proof.count <= 32*1024 else { throw ShadowFailure.appleError }
                    key.attested = true
                    key.attestationStartedAt = nil
                    key.retryEnrollment = nil
                    if [2,3].contains(request.protocolVersion ?? 0) {
                        key.pendingProof = proof.base64EncodedString()
                        key.pendingEnrollment = enrollment.session
                        key.pendingStatus = enrollment.status
                        key.pendingCreatedAt = enrollment.createdAt
                        response.enrollmentSession = enrollment.session
                        response.status = enrollment.status
                    }
                    record = key
                    try storage.save(key, scope: keyScope)
                    response.proof = proof.base64EncodedString()
                } else if request.action == "assert" {
                    // The coordinator may have persisted an attestation whose local
                    // acknowledgement was lost. A real assertion establishes usability.
                    // A definite serverUnavailable response has no proof to send.
                    // Retry this exchange only, with its original key and signed
                    // challenge; the coordinator still verifies the counter.
                    var proof: Data?
                    // Each Apple callback has a 25s deadline. One retry stays
                    // well inside the coordinator's 90s exchange timeout.
                    for attempt in 0..<2 {
                        do { proof = try await service.generateAssertion(key.keyID, hash: hash); break }
                        catch where appAttestFailure(error) == .appleUnavailable && attempt == 0 {
                            try await appAttestSleep(seconds: 2)
                        }
                    }
                    guard let proof else { throw ShadowFailure.appleError }
                    guard proof.count <= 32*1024 else { throw ShadowFailure.appleError }
                    key.attested=true; key.pendingProof=nil; key.pendingEnrollment=nil; key.pendingStatus=nil; key.pendingCreatedAt=nil; key.attestationStartedAt=nil; key.retryEnrollment=nil
                    record=key; try storage.save(key, scope:keyScope)
                    response.proof = proof.base64EncodedString()
                } else { throw ShadowFailure.invalidRequest }
            }
            try Task.checkCancellation()
            response.result = "ok"
        } catch {
            let failure = appAttestFailure(error)
            response.appleError = (error as? AppleAppAttestFailure)?.details
            if (calledAttestation || (request.action == "assert" && failure == .appleInvalidKey)), var key = record, let keyScope = preparedScope {
                // A successfully cached proof remains recoverable after a local
                // write/cancellation failure. Never replace it with an error.
                if failure == .appleInvalidKey || (calledAttestation && key.pendingProof == nil && shouldRetireEnrollmentKey(after: failure)) {
                    key.retireEnrollment()
                } else if failure == .appleUnavailable || failure == .busy {
                    key.attestationStartedAt = nil
                }
                record = key
                do { try storage.save(key, scope: keyScope) }
                catch { response.result = ShadowFailure.keychainError.rawValue; return response }
            }
            response.result = failure.rawValue
        }
        return response
    }
}
