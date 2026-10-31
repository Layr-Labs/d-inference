import Foundation
import Darwin

extension ClusterConfigurationStore {
    /// Diagnostics-only optional read. Missing file/reference means no saved
    /// setup; malformed or unsafe existing input remains an error. No writes.
    static func optionalInstalledReference(providerConfiguration: URL) throws -> ClusterConfigurationReference? {
        try ClusterConfigurationFiles.requireAbsolute(providerConfiguration.path)
        var value = stat()
        if lstat(providerConfiguration.path, &value) != 0, errno == ENOENT { return nil }
        let bytes = try ClusterConfigurationFiles.read(providerConfiguration, maximum: 1_048_576, privateMode: true)
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw ClusterConfigurationError.invalid("Provider configuration is not UTF-8")
        }
        return try ConfigManager.parseValidating(text).cluster
    }

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
