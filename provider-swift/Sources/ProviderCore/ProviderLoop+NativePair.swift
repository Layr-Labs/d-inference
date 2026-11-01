import Foundation

extension ProviderLoop {
    /// Called before run() by a member whose saved setup carries a pair
    /// approval. The registration, challenge and heartbeat use this SAME signer
    /// and member role, and the registration carries this installation's
    /// membership. It adds no solo capacity, native runtime approval, automatic
    /// model load or fallback.
    public func installNativePairMember(_ installation: NativePairMemberInstallation) throws {
        guard isClusterMember, !nativePairConfigurationClosed, coordinatorClient == nil, nativePairMemberControl == nil,
              let signer, loopConfig.hardware.chipName == installation.chip, loopConfig.models.contains(where: { $0.id == installation.policy.model }),
              loopConfig.admitsModel(installation.policy.model) else { throw NativePairMemberError.unconfigured }
        // A roster registration names this member by the pin of the key that
        // signs its registration: a roster made for another key is refused.
        if let roster = installation.roster {
            guard ClusterMemberPin.of(sePublicKey: signer.publicKeyBase64) == roster.memberPin else {
                throw NativePairMemberError.unconfigured
            }
        }
        nativePairMemberControl = NativePairMemberControl(installation: installation, signer: signer)
    }
    public var nativePairMemberStatus: String? { nativePairMemberControl?.status }
    /// True when the installation's roster names this Mac by a pin other than
    /// its signing key's, so a start can say it must pair again (S17).
    public func nativePairRosterNamesAnotherKey(_ installation: NativePairMemberInstallation) -> Bool {
        guard let roster = installation.roster, let signer else { return false }
        return ClusterMemberPin.of(sePublicKey: signer.publicKeyBase64) != roster.memberPin
    }
}
