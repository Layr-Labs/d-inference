import Foundation

extension ClusterAutomaticBatchSetup {
    /// Saves only after the normal store proves an empty device journal. The
    /// CAS on every provider pointer prevents a concurrent operator choice
    /// from being overwritten. No worker is started or old journal recovered.
    func applyTransaction(paths: ClusterUserPaths, providerConfigurations: [URL], directory: URL,
               senderMemberID: String? = nil,
               parseReference: (Data) throws -> ClusterConfigurationReference,
               updateProvider: (Data, ClusterConfigurationReference) throws -> Data,
               beforePointerUpdate: (ClusterConfigurationReference, ClusterConfigurationReference) throws -> Void = { _, _ in })
        throws -> ClusterConfigurationReference {
        guard !providerConfigurations.isEmpty, configuration.count <= ClusterConfigurationCodec.maximumBytes,
              ClusterConfigurationSyntax.hash(previousSHA256) else {
            throw ClusterConfigurationError.invalid("Invalid automatic setup replacement")
        }
        let files = Array(Set(providerConfigurations)).sorted { $0.path < $1.path }
        func reference(_ file: URL) throws -> ClusterConfigurationReference {
            try parseReference(ClusterConfigurationFiles.read(file, maximum: 1_048_576, privateMode: true))
        }
        let previous = try reference(files[0])
        let store = ClusterConfigurationStore(paths: paths), saved = try store.load(reference: previous)
        let after = try ClusterConfigurationCodec.decode(configuration, capability: saved.capability,
            capabilitySHA256: saved.configuration.capabilitySHA256)
        let canonical = try ClusterConfigurationCodec.encode(after, capability: saved.capability,
            capabilitySHA256: saved.configuration.capabilitySHA256)
        let targetSHA256 = ClusterConfigurationCodec.sha256(canonical)
        guard previous.sha256 == previousSHA256 || previous.sha256 == targetSHA256 else {
            throw ClusterConfigurationError.invalid("The cluster setup changed before automatic replacement")
        }
        for file in files {
            guard try reference(file) == previous else {
                throw ClusterConfigurationError.invalid("The selected and owner setups disagree")
            }
        }
        if let senderMemberID {
            guard saved.configuration.role == .follower, saved.configuration.peers[0].id == senderMemberID else {
                throw ClusterConfigurationError.invalid("Only the saved serving leader may replace its follower's batch setup")
            }
        }
        // A reply can be lost after adoption. Repeating exactly the selected
        // canonical setup is idempotent; another later setup is never overwritten.
        if previous.sha256 == targetSHA256 { return previous }
        try ClusterAutomaticSetupHandoff.requireCompatible(saved.configuration, after, runtimeModelID: saved.capability.runtimeModelID)
        try ClusterConfigurationFiles.ensureDirectory(directory, create: true, privateMode: true)
        let input = directory.appendingPathComponent("batch-" + UUID().uuidString.lowercased() + ".json")
        try ClusterConfigurationFiles.update(input, maximum: ClusterConfigurationCodec.maximumBytes) { _ in configuration }
        defer { try? FileManager.default.removeItem(at: input) }
        var selected: ClusterConfigurationReference?
        _ = try store.save(configurationInput: input,
            capabilityInput: paths.capabilityURL(sha256: saved.configuration.capabilitySHA256),
            capabilitySHA256: saved.configuration.capabilitySHA256) { reference in
            try beforePointerUpdate(previous, reference)
            var written: [(URL, Data, Data)] = []
            do {
                for file in files {
                    var originalBytes: Data?, replacementBytes: Data?
                    try ClusterConfigurationFiles.update(file, maximum: 1_048_576) { original in
                        guard let original, try parseReference(original) == previous else {
                            throw ClusterConfigurationError.invalid("The setup pointer changed during automatic adoption")
                        }
                        let updated = try updateProvider(original, reference)
                        originalBytes = original; replacementBytes = updated
                        return updated
                    }
                    if let originalBytes, let replacementBytes { written.append((file, originalBytes, replacementBytes)) }
                }
            } catch {
                // Compensate only the exact bytes this transaction wrote. An
                // independent operator edit is never replaced during rollback.
                var restored = true
                for (file, original, replacement) in written.reversed() {
                    do {
                        try ClusterConfigurationFiles.update(file, maximum: 1_048_576) { current in
                            guard current == replacement else {
                                throw ClusterConfigurationError.invalid("The setup pointer changed before rollback")
                            }
                            return original
                        }
                    } catch { restored = false }
                }
                guard restored else {
                    throw ClusterConfigurationError.invalid("Automatic setup adoption failed and its pointers require reconciliation")
                }
                throw error
            }
            selected = reference
        }
        guard let selected else { throw ClusterConfigurationError.invalid("Automatic setup replacement was not saved") }
        return selected
    }
}
