import Foundation
import DarkbloomClusterPlacement
import DarkbloomClusterProtocol

/// The step of the guided flow that chooses which Mac leads and where the
/// model is cut. It detects this Mac and reads the artifact through the
/// installed `darkbloom-cluster-plan` (the worker's sibling, so the gate rule
/// and the stage plan are the worker's own), takes the other Mac's profile as
/// that Mac printed it, runs the planner, and writes a setup for each Mac.
/// It saves nothing and starts nothing; each Mac approves its own setup.
public enum ClusterPlacementFlow {
    public static let toolName = "darkbloom-cluster-plan"

    public struct Inputs: Sendable {
        public var pairDescription: URL
        public var capability: URL
        public var capabilitySHA256: String
        public var localMemberID: String
        public var peerProfile: URL
        public var speedMeasurements: [URL] = []
        public var promptTokens: Int?
        public var outputTokens: Int?
        public var regime = ClusterPlacementPolicy.Regime.sustained
        /// A new directory for the two setups and the plan, created owner-only.
        public var output: URL
        public init(pairDescription: URL, capability: URL, capabilitySHA256: String, localMemberID: String,
                    peerProfile: URL, output: URL) {
            self.pairDescription = pairDescription; self.capability = capability
            self.capabilitySHA256 = capabilitySHA256; self.localMemberID = localMemberID
            self.peerProfile = peerProfile; self.output = output
        }
    }

    public struct Outcome: Sendable {
        /// What was detected, what was chosen and why, in plain words.
        public let lines: [String]
        public let result: ClusterPlacementResult
        /// Nil when the model was refused: then nothing was written.
        public let setup: ClusterPlacementSetup?
        public let written: [URL]
    }

    /// The planning itself, with everything detected already in hand. Pure,
    /// so a check can run the whole decision without a child process.
    public static func decide(description: ClusterPairDescription, capability: ClusterRuntimeCapability,
                              localMemberID: String, localProfile: ClusterDeviceProfile, peerProfile: ClusterDeviceProfile,
                              layout: ClusterModelLayout, measurements: [ClusterSpeedMeasurement] = [],
                              promptTokens: Int? = nil, outputTokens: Int? = nil,
                              regime: ClusterPlacementPolicy.Regime = .sustained) throws
        -> (lines: [String], result: ClusterPlacementResult, setup: ClusterPlacementSetup?) {
        guard let local = description.members.first(where: { $0.id == localMemberID }),
              let peer = description.members.first(where: { $0.id != localMemberID }) else {
            throw ClusterConfigurationError.invalid("This Mac's member ID, \(localMemberID), is not in the pair description")
        }
        guard layout.runtimeModelID == capability.runtimeModelID, layout.artifactSHA256 == capability.artifactSHA256,
              layout.configurationSHA256 == capability.configurationSHA256 else {
            throw ClusterConfigurationError.invalid("The artifact's layout and the worker's capability record describe different models")
        }
        // The planner may choose only what this worker build can be told to load.
        let described = Set(capability.partitions.compactMap { $0.stages.first?.sourceLayerEnd })
        guard Set(layout.admittedCuts).isSubset(of: described) else {
            throw ClusterConfigurationError.invalid("The layout admits a cut the worker's capability record does not describe; "
                + "the plan tool and the worker must be one build")
        }
        var policy = ClusterPlacementPolicy()
        policy.promptTokens = promptTokens; policy.outputTokens = outputTokens; policy.regime = regime
        policy.modes = capability.supportedGenerationModes
        policy.schedules = capability.supportedPrefillSchedules
        let profiles = [(local.id, localProfile), (peer.id, peerProfile)]
        let speeds = ClusterSpeedEstimator.estimate(devices: profiles.map { .init(chip: $0.1.chip, osBuild: $0.1.osBuild) },
            artifactSHA256: layout.artifactSHA256, promptTokens: promptTokens ?? layout.maximumPromptTokens, measurements: measurements)
        let devices = zip(profiles, speeds).map { ClusterPlacementDevice(label: $0.0.0, profile: $0.0.1, speed: $0.1) }
        let result = try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: policy)
        var lines = ClusterPlacementExplanation.describe(result, devices: devices, layout: layout)
        var setup: ClusterPlacementSetup?
        if let chosen = result.chosen {
            let value = try ClusterPlacementSetup.synthesize(description: description, capability: capability, chosen: chosen)
            lines.append("What happens next")
            lines += value.narration(localMemberID: localMemberID).map { "  " + $0 }
            setup = value
        }
        return (lines, result, setup)
    }
}
