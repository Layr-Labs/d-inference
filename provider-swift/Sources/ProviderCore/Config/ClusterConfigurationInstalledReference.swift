import Foundation
import Darwin

extension ClusterConfigurationStore {
    /// Optional read of the saved setup's reference (diagnostics, the setup
    /// screens, approval checks and member supervision). A missing file or
    /// reference means no saved setup, and so does a file whose only fault is
    /// that other users can read it, when it saves no setup (as the installer
    /// writes it). Malformed or unsafe existing input remains an error; such a
    /// file that saves a setup fails with the fix. No writes.
    static func optionalInstalledReference(providerConfiguration: URL) throws -> ClusterConfigurationReference? {
        try ClusterConfigurationFiles.requireAbsolute(providerConfiguration.path)
        var value = stat()
        if lstat(providerConfiguration.path, &value) != 0, errno == ENOENT { return nil }
        let bytes: Data
        do {
            bytes = try ClusterConfigurationFiles.read(providerConfiguration, maximum: 1_048_576, privateMode: true)
        } catch {
            // Not private: the installer writes it with the default mode for a coordinator other than production's, and
            // the provider's next save (the first setup's) makes it private. Saving no setup, it has nothing to protect.
            guard value.st_mode & S_IFMT == S_IFREG, value.st_mode & 0o077 != 0,
                  let open = try? ClusterConfigurationFiles.read(providerConfiguration, maximum: 1_048_576),
                  let text = String(data: open, encoding: .utf8) else { throw error }
            guard try ConfigManager.parseValidating(text).cluster == nil else {
                throw ClusterConfigurationError.invalid(notPrivate(providerConfiguration, mode: value.st_mode))
            }
            return nil
        }
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw ClusterConfigurationError.invalid("Provider configuration is not UTF-8")
        }
        return try ConfigManager.parseValidating(text).cluster
    }

    /// A provider configuration that saves this Mac's cluster setup while other users can open it: what is wrong, and
    /// the fix.
    static func notPrivate(_ file: URL, mode: mode_t) -> String {
        "\(file.path) saves this Mac's cluster setup, but other users can open it (mode \(String(mode & 0o777, radix: 8))); "
            + "run `chmod 600 \(file.path)`"
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
