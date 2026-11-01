import Foundation

extension ClusterAutomaticBatchSetup {
    func apply(paths: ClusterUserPaths, providerConfigurations: [URL], directory: URL,
               senderMemberID: String? = nil,
               beforePointerUpdate: (ClusterConfigurationReference, ClusterConfigurationReference) throws -> Void = { _, _ in })
        throws -> ClusterConfigurationReference {
        try applyTransaction(paths: paths, providerConfigurations: providerConfigurations, directory: directory,
            senderMemberID: senderMemberID, parseReference: { bytes in
                guard let text = String(data: bytes, encoding: .utf8),
                      let reference = try ConfigManager.parseValidating(text).cluster else {
                    throw ClusterConfigurationError.invalid("Installed owner requires saved cluster setup")
                }
                return reference
            }, updateProvider: { try ClusterConfigurationStore.updatingProviderData($0, reference: $1) },
            beforePointerUpdate: beforePointerUpdate)
    }
}
