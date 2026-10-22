import Foundation

extension ClusterConfigurationStore {
    /// Strict bounded read for an installed owner. It does not migrate, rewrite,
    /// fall back to defaults, inspect models or acquire the native device lease.
    public static func installedReference(providerConfiguration: URL) throws -> ClusterConfigurationReference {
        let bytes = try ClusterConfigurationFiles.read(providerConfiguration, maximum: 1_048_576, privateMode: true)
        guard let text = String(data: bytes, encoding: .utf8),
              let reference = try ConfigManager.parseValidating(text).cluster else {
            throw ClusterConfigurationError.invalid("Installed owner requires saved cluster setup")
        }
        return reference
    }
}
