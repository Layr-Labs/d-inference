import Foundation

/// New Apple key generation under the persisted per-key cooldown and the
/// shared hourly budget. Kept apart from the exchange state machine.
struct ShadowKeyGeneration {
    let service: any AppAttestService
    let storage: any ShadowKeyStorage
    let budgetScope: String
    let keyScope: String
    /// Diagnostics stamped on the new key; never used for policy.
    var bootTime: Int64? = nil
    var appVersion: String? = nil

    /// `previous` is the retired/failed record in `keyScope`, if any.
    func generate(replacing previous: ShadowKeyRecord?) async throws -> ShadowKeyRecord {
        // An unregistered/invalid old key may be replaced at most hourly,
        // including across restarts. A failed generateKey that returned
        // no identifier may be retried sooner under the shared budget.
        if let previous, !previous.mayGenerateKey(at: Date()) { throw ShadowFailure.busy }
        // Record the generation budget and establish writable key
        // persistence BEFORE asking Apple for a key. Budget I/O goes
        // first so its failure cannot leave a new empty key marker
        // that strands an otherwise healthy device for an hour.
        var pending = ShadowKeyRecord(keyID: "", attested: false, createdAt: Date())
        pending.createdBootTime = bootTime
        pending.createdAppVersion = appVersion.map { String($0.prefix(AppAttestKeyHistory.maxVersionLength)) }
        // Persist a shared budget across account scopes as well as the
        // per-key cooldown, so account churn cannot bypass it.
        var budget = try storage.load(scope: budgetScope) ?? ShadowKeyRecord(keyID: "budget", attested: false, createdAt: Date())
        if Date().timeIntervalSince(budget.createdAt) >= KeyGenerationBudget.window { budget.createdAt = Date(); budget.generationCount = 0 }
        guard (budget.generationCount ?? 0) < KeyGenerationBudget.limit else { throw ShadowFailure.busy }
        budget.generationCount = (budget.generationCount ?? 0) + 1
        budget.generationHistory = KeyGenerationHistory.appending(pending.createdAt, to: budget.generationHistory)
        try storage.save(budget, scope: budgetScope)
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
        var key = ShadowKeyRecord(keyID: id, attested: false, createdAt: pending.createdAt)
        key.createdBootTime = pending.createdBootTime
        key.createdAppVersion = pending.createdAppVersion
        key.consecutiveAssertionFailures = 0
        try storage.save(key, scope: keyScope)
        return key
    }
}
