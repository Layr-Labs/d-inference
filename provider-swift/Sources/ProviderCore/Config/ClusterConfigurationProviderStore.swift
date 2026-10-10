import Foundation
import TOMLKit

extension ClusterConfigurationStore {
    /// Saving setup never enables distributed startup. Existing malformed TOML
    /// is refused instead of being replaced with defaults.
    public func configure(configurationInput: URL, capabilityInput: URL, capabilitySHA256: String,
                          providerConfiguration: URL) throws -> ClusterConfigurationSaveResult {
        try save(configurationInput: configurationInput, capabilityInput: capabilityInput, capabilitySHA256: capabilitySHA256) { reference in
            try ClusterConfigurationFiles.update(providerConfiguration, maximum: 1024 * 1024) { original in
                try Self.updatingProviderData(original, reference: reference)
            }
        }
    }

    static func updatingProviderData(_ original: Data?, reference: ClusterConfigurationReference) throws -> Data {
        let table: TOMLTable
        if let original {
            guard let text = String(data: original, encoding: .utf8) else {
                throw ClusterConfigurationError.invalid("Provider configuration is not UTF-8")
            }
            let current = try ConfigManager.parseValidating(text)
            if current.cluster == reference { return original }
            table = try TOMLTable(string: text)
        } else {
            table = TOMLTable()
        }
        // Mutate the raw TOML table rather than serializing a migrated
        // ProviderConfig. Every unrelated value (including unknown
        // tables and old migration stamps) retains its original meaning.
        // Formatting/comments may change; no migration is written here.
        table["cluster"] = TOMLTable(["configuration": reference.configuration, "sha256": reference.sha256])
        let text = table.convert()
        guard !text.isEmpty, try ConfigManager.parseValidating(text).cluster == reference else {
            throw ClusterConfigurationError.invalid("Provider cluster pointer did not serialize correctly")
        }
        let roundTrip = try TOMLTable(string: text)
        guard roundTrip == table else { throw ClusterConfigurationError.invalid("Provider TOML values changed during serialization") }
        return Data(text.utf8)
    }
}
