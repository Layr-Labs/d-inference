import Foundation

/// Serializes Apple/keychain work without occupying the serving actor. Reentrant
/// calls get a bounded busy result rather than spawning additional Apple calls.
public actor AppAttestShadowClient {
    private let service: any AppAttestService
    private let storage: any ShadowKeyStorage
    private let scope: String
    private let runtimeContext: @Sendable () -> AppAttestRuntimeContext
    private let now: @Sendable () -> Date
    private var busy = false
    private var session: String?
    private var record: ShadowKeyRecord?
    private var preparedEnvironment: String?
    private var preparedScope: String?
    private var preparedAccountScope: String?
    private var preparedProtocol: Int?
    private var localStatus: AppAttestLocalStatus?

    public init(scope: String, service: any AppAttestService = AppleAppAttestService(), storage: any ShadowKeyStorage = KeychainShadowKeyStorage(),
                runtimeContext: @escaping @Sendable () -> AppAttestRuntimeContext = { AppAttestRuntimeContext.current() },
                now: @escaping @Sendable () -> Date = Date.init) {
        self.scope = scope; self.service = service; self.storage = storage
        self.runtimeContext = runtimeContext; self.now = now
    }

    /// Last local observation for the daemon state file; nil before any `prepare`.
    public func currentLocalStatus() -> AppAttestLocalStatus? { localStatus }

    /// When the outstanding uncancellable Apple call was admitted, or nil when
    /// idle. Readable while an exchange is in flight.
    public func appleOperationHeldSince() async -> Date? {
        await service.operationHeldSince()
    }

    public func respond(to request: AppAttestShadowPayload, publicKey: String, status: AppAttestStatus? = nil) async -> AppAttestShadowPayload {
        guard request.action == "prepare" else { return await exchange(request, publicKey: publicKey, status: status) }
        let context = runtimeContext()
        var response: AppAttestShadowPayload
        if let stalled = AppleOperationStall.reportedSeconds(heldSince: await appleOperationHeldSince(), now: now()) {
            // Apple never answered an earlier call; only a new process frees
            // its admission, so every Apple call would answer busy anyway.
            response = AppAttestShadowPayload(action: "ready", session: request.session)
            response.protocolVersion = request.protocolVersion
            response.result = ShadowFailure.busy.rawValue
            response.operationStalledSeconds = stalled
        } else {
            response = await exchange(request, publicKey: publicKey, status: status)
        }
        response.launchSession = context.launchSession
        response.bootTime = context.bootTime
        recordLocalStatus(request: request, response: response, context: context)
        return response
    }

    private func recordLocalStatus(request: AppAttestShadowPayload, response: AppAttestShadowPayload, context: AppAttestRuntimeContext) {
        let current = now()
        var key: AppAttestKeyState?
        // An availability failure never reaches Keychain in the exchange; keep it that way.
        if response.availabilityReason == nil, let environment = request.environment,
           let keyScope = keyScope(for: request, environment: environment) {
            key = try? AppAttestKeyState(
                record: storage.load(scope: keyScope),
                budget: storage.load(scope: KeyGenerationBudget.scope(scope, environment: environment)),
                now: current)
        }
        localStatus = AppAttestLocalStatus(
            observedAt: current.timeIntervalSince1970, launchSession: context.launchSession, bootTime: context.bootTime,
            availabilityReason: response.availabilityReason, operationStalledSeconds: response.operationStalledSeconds, key: key)
    }

    private func keyScope(for request: AppAttestShadowPayload, environment: String) -> String? {
        guard ["production", "development"].contains(environment) else { return nil }
        guard [2, 3].contains(request.protocolVersion ?? 0) else { return scope + ":" + environment }
        guard let account = request.accountScope, account.utf8.count == 64 else { return nil }
        return scope + ":" + environment + ":account:" + account
    }

    private func exchange(_ request: AppAttestShadowPayload, publicKey: String, status: AppAttestStatus?) async -> AppAttestShadowPayload {
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
                guard let keyScope = keyScope(for: request, environment: environment) else { throw ShadowFailure.invalidRequest }
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
                    key = try await ShadowKeyGeneration(
                        service: service, storage: storage,
                        budgetScope: KeyGenerationBudget.scope(scope, environment: environment), keyScope: keyScope
                    ).generate(replacing: key)
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
                    guard let proof else { throw ShadowFailure.appleError }
                    guard proof.count <= 32*1024 else { throw AppAttestAppleErrorSource.proofOversize }
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
                    guard proof.count <= 32*1024 else { throw AppAttestAppleErrorSource.proofOversize }
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
            response.availabilityReason = (error as? AppAttestAvailabilityFailure)?.reason
            response.appleErrorSource = error as? AppAttestAppleErrorSource
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
                catch {
                    response.result = ShadowFailure.keychainError.rawValue
                    response.appleError = nil
                    response.availabilityReason = nil
                    response.appleErrorSource = nil
                    return response
                }
            }
            response.result = failure.rawValue
        }
        return response
    }
}
