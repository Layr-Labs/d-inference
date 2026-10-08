import Foundation
import Darwin
import DarkbloomClusterProtocol

public struct ClusterConfigurationSaveResult: Encodable, Sendable, Equatable {
    public let configuration: String
    public let configurationSHA256: String
    public let capability: String
    public let capabilitySHA256: String
    public let deviceLeaseFile: String
    public let distributedEnabled = false
    public let readinessVerified = false
    public let installationVerified = false
    public let modelFilesVerified = false
    public let remoteTrustVerified = false
    public let existingTrustFilePinVerified = true

    // Output-only; saved results are never inputs to startup/admission.
    private enum CodingKeys: String, CodingKey {
        case configuration, configurationSHA256, capability, capabilitySHA256, deviceLeaseFile
        case distributedEnabled, readinessVerified, installationVerified, modelFilesVerified
        case remoteTrustVerified, existingTrustFilePinVerified
    }
}

/// Strict immutable records plus one atomic provider pointer update. No runtime,
/// network, model payload, process launch, journal recovery or mode change.
public struct ClusterConfigurationStore: Sendable {
    public let paths: ClusterUserPaths
    public init(paths: ClusterUserPaths) { self.paths = paths }

    public struct Saved: Sendable {
        public let configuration: ClusterConfiguration
        public let capability: ClusterRuntimeCapability
    }

    public func load(reference: ClusterConfigurationReference) throws -> Saved {
        let expected = try paths.configurationURL(sha256: reference.sha256)
        guard expected.path == reference.configuration else {
            throw ClusterConfigurationError.invalid("Saved cluster reference is outside its canonical store")
        }
        let data = try ClusterConfigurationFiles.read(expected, maximum: ClusterConfigurationCodec.maximumBytes, privateMode: true)
        guard ClusterConfigurationCodec.sha256(data) == reference.sha256 else {
            throw ClusterConfigurationError.invalid("Saved cluster configuration digest differs")
        }
        // The strict complete decode below remains authoritative; this bounded
        // extraction locates the content-addressed capability and grants nothing.
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let capabilityHash = object["capabilitySHA256"] as? String else {
            throw ClusterConfigurationError.invalid("Saved cluster capability reference is missing")
        }
        let capabilityData = try ClusterConfigurationFiles.read(paths.capabilityURL(sha256: capabilityHash),
            maximum: ClusterRuntimeCapabilityCodec.maximumBytes, privateMode: true)
        guard ClusterConfigurationCodec.sha256(capabilityData) == capabilityHash else {
            throw ClusterConfigurationError.invalid("Saved capability digest differs")
        }
        let capability = try ClusterRuntimeCapabilityCodec.decode(capabilityData)
        let configuration = try ClusterConfigurationCodec.decode(data, capability: capability, capabilitySHA256: capabilityHash)
        guard try ClusterConfigurationCodec.encode(configuration, capability: capability, capabilitySHA256: capabilityHash) == data else {
            throw ClusterConfigurationError.invalid("Saved cluster configuration is not canonical")
        }
        return Saved(configuration: configuration, capability: capability)
    }

    // Internal transaction seam permits a small actual-file fixture without
    // importing the provider's model/runtime dependency graph. The production
    // caller below supplies the real TOML update, inside this same device gate.
    func save(configurationInput: URL, capabilityInput: URL, capabilitySHA256: String,
              updateProvider: (ClusterConfigurationReference) throws -> Void) throws -> ClusterConfigurationSaveResult {
        guard ClusterConfigurationSyntax.hash(capabilitySHA256) else { throw ClusterConfigurationError.invalid("Invalid capability input digest") }
        let capabilityData = try ClusterConfigurationFiles.read(capabilityInput, maximum: ClusterRuntimeCapabilityCodec.maximumBytes)
        guard ClusterConfigurationCodec.sha256(capabilityData) == capabilitySHA256 else { throw ClusterConfigurationError.invalid("Capability input digest differs") }
        let capability = try ClusterRuntimeCapabilityCodec.decode(capabilityData)
        let input = try ClusterConfigurationFiles.read(configurationInput, maximum: ClusterConfigurationCodec.maximumBytes)
        var configuration = try ClusterConfigurationCodec.decode(input, capability: capability, capabilitySHA256: capabilitySHA256)
        configuration.makePrefillSelectionExplicit()
        configuration.makeTransportSelectionExplicit()
        let data = try ClusterConfigurationCodec.encode(configuration, capability: capability, capabilitySHA256: capabilitySHA256)
        let digest = ClusterConfigurationCodec.sha256(data)
        let destination = try paths.configurationURL(sha256: digest)
        let capabilityDestination = try paths.capabilityURL(sha256: capabilitySHA256)
        let reference = try ClusterConfigurationReference(configuration: destination.path, sha256: digest)

        try validateTrust(configuration.trust)
        let device = try ClusterConfigurationFiles.directory(paths.deviceDirectory, create: true, privateMode: true)
        defer { Darwin.close(device.descriptor) }
        try ClusterConfigurationFiles.withLock(device, name: paths.deviceLeaseFile.lastPathComponent, requireEmpty: true, privateMode: true) {
            let directory = try ClusterConfigurationFiles.directory(paths.configurationsDirectory, create: true, privateMode: true)
            defer { Darwin.close(directory.descriptor) }
            try ClusterConfigurationFiles.withLock(directory, name: "configuration.lock", privateMode: true) {
                try ClusterConfigurationFiles.publish(capabilityData, parent: directory, name: capabilityDestination.lastPathComponent,
                    maximum: ClusterRuntimeCapabilityCodec.maximumBytes)
                try ClusterConfigurationFiles.publish(data, parent: directory, name: destination.lastPathComponent,
                    maximum: ClusterConfigurationCodec.maximumBytes)
                _ = try load(reference: reference)
                try validateTrust(configuration.trust)
                try updateProvider(reference)
            }
        }
        return ClusterConfigurationSaveResult(configuration: destination.path, configurationSHA256: digest,
            capability: capabilityDestination.path, capabilitySHA256: capabilitySHA256, deviceLeaseFile: paths.deviceLeaseFile.path)
    }

    private func validateTrust(_ trust: ClusterConfiguration.Trust) throws {
        try ClusterConfigurationFiles.credentialMetadata(URL(fileURLWithPath: trust.identityFile), privateMode: true)
        let hosts = try ClusterConfigurationFiles.read(URL(fileURLWithPath: trust.knownHostsFile), maximum: 64 * 1024)
        guard ClusterConfigurationCodec.sha256(hosts) == trust.knownHostsSHA256,
              String(data: hosts, encoding: .utf8) != nil else {
            throw ClusterConfigurationError.invalid("Existing known-hosts input pin or encoding differs")
        }
    }
}
