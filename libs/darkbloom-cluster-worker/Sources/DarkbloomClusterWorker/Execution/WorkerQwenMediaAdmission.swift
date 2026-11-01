import DarkbloomClusterProtocol

/// A typed media envelope must never reach an owner that could ignore it.
/// The native owner still validates geometry, processor, mode and resources;
/// this common executor gate also protects every foreign model family.
enum WorkerQwenMediaAdmission {
    static func accepts(_ value: ClusterWorkerReservation, ready: ClusterWorkerReady?) -> Bool {
        guard let media = value.qwenMedia else { return true }
        guard let ready, ready.media == ClusterQwenMedia.contract,
            ready.dataPlane?.encryptedAndVerified == true,
            ready.identity.artifactSHA256 == media.artifactSHA256,
            ready.identity.configurationSHA256 == media.configurationSHA256,
            ready.profile.id == value.profileID,
            value.route == nil, value.mimoImages == nil, value.stillImages == nil, value.glmMedia == nil,
            (ready.rank == 0 && media.items.allSatisfy({ $0.encoded != nil }))
                || (ready.rank == 1 && !media.carriesEncodedBytes) else { return false }
        return true
    }
}
