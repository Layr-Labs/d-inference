import Foundation

/// Experimental, local preparation seam. This actor never grants authorization,
/// persists request secrets, or changes the provider's live request key.
public actor BootContinuityCustodian {
    private let activation: BootContinuityActivation
    private let store: any BootIdentityStore
    private let engine: any BootKeyEngine
    private let application: any BootApplicationScope
    private var session: BootKeySession?

    public init(activation: BootContinuityActivation = .disabled) {
        self.activation = activation
        store = DataProtectionBootIdentityStore()
        engine = SecureEnclaveBootKeyEngine()
        application = SignedBootApplicationScope()
        // These constructors perform no Security or Keychain IO.
    }

    init(activation: BootContinuityActivation, store: any BootIdentityStore,
         engine: any BootKeyEngine, application: any BootApplicationScope) {
        self.activation = activation
        self.store = store
        self.engine = engine
        self.application = application
    }

    /// Context uses actual signed executable identity, never a claimed release.
    public func makeContext(accountID: String, deviceID: String, coordinatorOrigin: String,
                            policyGeneration: UInt64) throws -> BootContinuityContext {
        guard activation == .experimental else { throw BootContinuityError.disabled }
        return try BootContinuityContext(accountID: accountID, deviceID: deviceID,
                                         coordinatorOrigin: coordinatorOrigin,
                                         releaseID: application.currentReleaseID(),
                                         policyGeneration: policyGeneration)
    }

    public func recover(context: BootContinuityContext) throws -> BootContinuityRecovery {
        session = nil
        guard activation == .experimental else { return .disabled }
        try validateCaller(context)
        guard let data = try store.read(context: context) else { return .absent }
        let recovered = try BootKeySession.recover(record: data, context: context,
                                                  activation: activation, engine: engine)
        session = recovered
        return .recovered(descriptor(recovered))
    }

    /// Explicitly creates a *candidate*, not a trusted or authorized identity.
    /// Existing, stale, locked, and corrupt records require separate resolution;
    /// none causes automatic rotation. The future bootstrap owns that policy.
    public func prepareCandidateForBootstrap(context: BootContinuityContext) throws -> BootContinuityDescriptor {
        session = nil
        guard activation == .experimental else { throw BootContinuityError.disabled }
        try validateCaller(context)
        guard try store.read(context: context) == nil else { throw BootCustodyError.recordAlreadyExists }
        let candidate = try BootKeySession.create(context: context, activation: activation, engine: engine)
        // A competing process may have inserted since read. Insert-only semantics
        // reject that race; the losing candidate never becomes the active session.
        try store.insert(candidate.storageRecord(), context: context)
        session = candidate
        return descriptor(candidate)
    }

    public func provePossession(challenge: BootContinuationChallenge) throws -> BootContinuationProof {
        guard activation == .experimental else { throw BootContinuityError.disabled }
        guard let session else { throw BootCustodyError.noRecoveredSession }
        try validateCaller(session.context)
        return try session.provePossession(challenge)
    }

    /// Clears only process memory. It never deletes Keychain state.
    public func forgetRecoveredSession() { session = nil }

    private func validateCaller(_ context: BootContinuityContext) throws {
        try context.validate()
        guard try application.currentReleaseID() == context.releaseID else { throw BootCustodyError.releaseMismatch }
    }

    private func descriptor(_ session: BootKeySession) -> BootContinuityDescriptor {
        BootContinuityDescriptor(context: session.context, publicKey: session.publicKey)
    }
}
