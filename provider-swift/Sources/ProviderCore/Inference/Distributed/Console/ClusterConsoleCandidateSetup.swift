import Foundation
import DarkbloomClusterProtocol

/// The three inputs `darkbloom cluster configure` takes, handed to the console
/// so the operator can read what they name before approving them.
public struct ClusterConsoleCandidate: Sendable, Equatable {
    public let configurationInput: URL
    public let capabilityInput: URL
    public let capabilitySHA256: String

    public init(configurationInput: URL, capabilityInput: URL, capabilitySHA256: String) {
        self.configurationInput = configurationInput; self.capabilityInput = capabilityInput
        self.capabilitySHA256 = capabilitySHA256
    }
}

/// A setup that is waiting for approval. Reading it trusts nothing and saves
/// nothing; approval is `ClusterConfigurationStore.configure`, run only when
/// the operator asks for it.
public struct ClusterConsoleCandidateSetup: Encodable, Sendable, Equatable {
    /// Why the inputs could not be read as a setup; nil when they could.
    public let error: String?
    public let pairing: ClusterConsolePairing?
    public let publicModelID: String?
    public let runtimeModelID: String?
    /// The digest saving these inputs would produce.
    public let configurationSHA256: String?
    /// That digest is the setup this Mac already has saved.
    public let alreadySaved: Bool

    public var approvable: Bool { error == nil && !alreadySaved }

    /// Decodes with the store's strict codecs, exactly as a save would,
    /// and stops before anything is published.
    static func read(_ candidate: ClusterConsoleCandidate, savedSHA256: String?) -> ClusterConsoleCandidateSetup {
        do {
            guard ClusterConfigurationSyntax.hash(candidate.capabilitySHA256) else {
                throw ClusterConfigurationError.invalid("Invalid capability input digest")
            }
            let capabilityData = try ClusterConfigurationFiles.read(candidate.capabilityInput,
                maximum: ClusterRuntimeCapabilityCodec.maximumBytes)
            guard ClusterConfigurationCodec.sha256(capabilityData) == candidate.capabilitySHA256 else {
                throw ClusterConfigurationError.invalid("Capability input digest differs")
            }
            let capability = try ClusterRuntimeCapabilityCodec.decode(capabilityData)
            let input = try ClusterConfigurationFiles.read(candidate.configurationInput, maximum: ClusterConfigurationCodec.maximumBytes)
            var configuration = try ClusterConfigurationCodec.decode(input, capability: capability,
                capabilitySHA256: candidate.capabilitySHA256)
            configuration.makePrefillSelectionExplicit()
            let digest = ClusterConfigurationCodec.sha256(try ClusterConfigurationCodec.encode(configuration,
                capability: capability, capabilitySHA256: candidate.capabilitySHA256))
            return .init(error: nil, pairing: .init(configuration: configuration),
                publicModelID: configuration.publicModelID, runtimeModelID: capability.runtimeModelID,
                configurationSHA256: digest, alreadySaved: digest == savedSHA256)
        } catch {
            return .init(error: ClusterConsoleText.bounded(error), pairing: nil, publicModelID: nil, runtimeModelID: nil,
                configurationSHA256: nil, alreadySaved: false)
        }
    }
}
