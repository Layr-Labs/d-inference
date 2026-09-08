import BootContinuity
import Foundation

/// An inactive protocol-development seam. ProviderLoop does not instantiate it.
/// A future handshake must independently authorize this identity and any new
/// process key; a local recovery result must never restore coordinator trust.
public actor ProviderBootContinuity {
    private let custodian: BootContinuityCustodian
    private let processPublicKey: Data

    public init(nodeKeyPair: NodeKeyPair, activation: BootContinuityActivation = .disabled) {
        // Capture the live endpoint from local provider state. A challenge cannot
        // ask this adapter to endorse a different externally supplied endpoint.
        processPublicKey = nodeKeyPair.publicKeyBytes
        custodian = BootContinuityCustodian(activation: activation)
    }

    public func makeContext(accountID: String, deviceID: String, coordinatorOrigin: String,
                            policyGeneration: UInt64) async throws -> BootContinuityContext {
        try await custodian.makeContext(accountID: accountID, deviceID: deviceID,
                                        coordinatorOrigin: coordinatorOrigin, policyGeneration: policyGeneration)
    }

    public func recover(context: BootContinuityContext) async throws -> BootContinuityRecovery {
        try await custodian.recover(context: context)
    }

    public func prepareCandidateForBootstrap(context: BootContinuityContext) async throws -> BootContinuityDescriptor {
        try await custodian.prepareCandidateForBootstrap(context: context)
    }

    public func provePossession(serverNonce: Data) async throws -> BootContinuationProof {
        let challenge = try BootContinuationChallenge(nonce: serverNonce, processPublicKey: processPublicKey)
        return try await custodian.provePossession(challenge: challenge)
    }

    public func forgetRecoveredSession() async { await custodian.forgetRecoveredSession() }
}
