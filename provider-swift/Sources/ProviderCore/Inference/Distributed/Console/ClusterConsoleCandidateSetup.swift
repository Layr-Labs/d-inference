import Foundation
import Darwin
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

    /// Both inputs as they are on disk now, decoded as a save would decode them.
    struct Contents {
        let configurationData: Data
        let capabilityData: Data
        let configuration: ClusterConfiguration
        let capability: ClusterRuntimeCapability
        /// The digest saving these bytes produces: the saved setup's identity.
        let configurationSHA256: String
    }

    /// Reads each input once, with the store's strict codecs, and stops
    /// before anything is published.
    func contents() throws -> Contents {
        guard ClusterConfigurationSyntax.hash(capabilitySHA256) else {
            throw ClusterConfigurationError.invalid("Invalid capability input digest")
        }
        let capabilityData = try ClusterConfigurationFiles.read(capabilityInput, maximum: ClusterRuntimeCapabilityCodec.maximumBytes)
        guard ClusterConfigurationCodec.sha256(capabilityData) == capabilitySHA256 else {
            throw ClusterConfigurationError.invalid("Capability input digest differs")
        }
        let capability = try ClusterRuntimeCapabilityCodec.decode(capabilityData)
        let configurationData = try ClusterConfigurationFiles.read(configurationInput, maximum: ClusterConfigurationCodec.maximumBytes)
        var configuration = try ClusterConfigurationCodec.decode(configurationData, capability: capability, capabilitySHA256: capabilitySHA256)
        configuration.makePrefillSelectionExplicit()
        let digest = ClusterConfigurationCodec.sha256(try ClusterConfigurationCodec.encode(configuration,
            capability: capability, capabilitySHA256: capabilitySHA256))
        return .init(configurationData: configurationData, capabilityData: capabilityData, configuration: configuration,
            capability: capability, configurationSHA256: digest)
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

    static func read(_ candidate: ClusterConsoleCandidate, savedSHA256: String?) -> ClusterConsoleCandidateSetup {
        do {
            let contents = try candidate.contents()
            return .init(error: nil, pairing: .init(configuration: contents.configuration),
                publicModelID: contents.configuration.publicModelID, runtimeModelID: contents.capability.runtimeModelID,
                configurationSHA256: contents.configurationSHA256, alreadySaved: contents.configurationSHA256 == savedSHA256)
        } catch {
            return .init(error: ClusterConsoleText.bounded(error), pairing: nil, publicModelID: nil, runtimeModelID: nil,
                configurationSHA256: nil, alreadySaved: false)
        }
    }
}

/// The inputs of one approval, held still. They are read once more, checked
/// to be the setup that was on screen when `y` was pressed, and copied to a
/// private directory; the save then reads the copies, so what is saved is
/// byte for byte what was reviewed, whatever happens to the originals.
struct ClusterConsoleReviewedSetup {
    let configurationInput: URL
    let capabilityInput: URL
    private let directory: URL

    /// `parent` must be this user's own directory with no symbolic link in its path.
    static func hold(_ candidate: ClusterConsoleCandidate, expectedSHA256: String, in parent: URL) throws -> ClusterConsoleReviewedSetup {
        let contents = try candidate.contents()
        guard contents.configurationSHA256 == expectedSHA256 else {
            throw ClusterConfigurationError.invalid("The setup changed after it was shown, so nothing was saved. Press r and review it again.")
        }
        let directory = parent.appendingPathComponent("darkbloom-cluster-approval-" + UUID().uuidString.lowercased(), isDirectory: true)
        guard mkdir(directory.path, 0o700) == 0 else {
            throw ClusterConfigurationError.invalid("Cannot hold the reviewed setup for saving (errno \(errno))")
        }
        let held = ClusterConsoleReviewedSetup(configurationInput: directory.appendingPathComponent("setup.json"),
            capabilityInput: directory.appendingPathComponent("capability.json"), directory: directory)
        do {
            for (data, url) in [(contents.configurationData, held.configurationInput), (contents.capabilityData, held.capabilityInput)] {
                let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard descriptor >= 0 else { throw ClusterConfigurationError.invalid("Cannot hold the reviewed setup for saving (errno \(errno))") }
                defer { Darwin.close(descriptor) }
                let written = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
                guard written == data.count else { throw ClusterConfigurationError.invalid("Cannot hold the reviewed setup for saving") }
            }
        } catch {
            held.release()
            throw error
        }
        return held
    }

    func release() {
        for url in [configurationInput, capabilityInput] { _ = unlink(url.path) }
        _ = rmdir(directory.path)
    }
}
