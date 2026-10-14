import Foundation
import DarkbloomClusterPlacement
import DarkbloomClusterProtocol

/// The step of the guided flow that chooses which Mac leads and where the
/// model is cut. It detects this Mac and reads the artifact through the
/// installed `darkbloom-cluster-plan` (the worker's sibling, so the gate rule
/// and the stage plan are the worker's own), asks the other Mac's plan tool
/// for that Mac's profile over the pinned SSH route the installed session
/// uses, runs the planner, and writes a setup for each Mac. One command on
/// one Mac; a profile file that Mac printed can stand in for the route.
/// It saves nothing and starts nothing; each Mac approves its own setup.
public enum ClusterPlacementFlow {
    public static let toolName = ClusterPlacementInstallation.toolName

    public struct Inputs: Sendable {
        public var pairDescription: URL
        public var capability: URL
        public var capabilitySHA256: String
        public var localMemberID: String
        /// The other Mac's profile as that Mac printed it. Nil, the default,
        /// asks that Mac over the pinned SSH route instead.
        public var peerProfile: URL?
        public var speedMeasurements: [URL] = []
        public var promptTokens: Int?
        public var outputTokens: Int?
        public var regime = ClusterPlacementPolicy.Regime.rested
        /// A new directory for the two setups and the plan, created owner-only.
        public var output: URL
        public init(pairDescription: URL, capability: URL, capabilitySHA256: String, localMemberID: String,
                    peerProfile: URL? = nil, output: URL) {
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
                              regime: ClusterPlacementPolicy.Regime = .rested, leader: String? = nil,
                              served: [ClusterServedSpeedRecords.Entry] = [],
                              environment: [String: String] = ProcessInfo.processInfo.environment,
                              benchDebugBuild: Bool = ClusterPlannerBenchCap.isDebugBuild) throws
        -> (lines: [String], result: ClusterPlacementResult, setup: ClusterPlacementSetup?) {
        // Developer bench only (`ClusterPlannerBenchCap`): a debug build may be told to plan as if each Mac could
        // give less memory than it detected; a release build refuses. The load gates never see this.
        let benchCap = try ClusterPlannerBenchCap.capBytes(environment: environment, debugBuild: benchDebugBuild)
        let localProfile = try benchCap.map { try localProfile.cappedForBench(admissibleBytes: $0) } ?? localProfile
        let peerProfile = try benchCap.map { try peerProfile.cappedForBench(admissibleBytes: $0) } ?? peerProfile
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
        // The model's pair-serving grant can rule an order out before anything
        // is planned (owner decision D4): the planner then ranks only the order
        // a start would accept.
        let granted = try leaderUnderGrant(requested: leader, members: [(local.id, localProfile.chip), (peer.id, peerProfile.chip)],
            runtimeModelID: capability.runtimeModelID, publicModelID: description.publicModelID,
            artifactSHA256: capability.artifactSHA256)
        policy.leader = granted.leader
        // A model with a failed cross-cable check on record is planned only at
        // the shapes a check passed in (each rank's chip class, the cuts, the
        // mode): the universal rule of `ClusterPairQualificationRecords`.
        let records = ClusterPairServingGrants.records(runtimeModelID: capability.runtimeModelID,
            artifactSHA256: capability.artifactSHA256)
        if records.restrictsShapes {
            policy.admitsShape = { chips, cuts, mode in
                records.admits(chipClasses: chips.map { ClusterChipClass(chipName: $0) }, cuts: cuts, mode: mode)
            }
        }
        policy.modes = capability.supportedGenerationModes
        policy.schedules = capability.supportedPrefillSchedules
        let profiles = [(local.id, localProfile), (peer.id, peerProfile)]
        let speeds = ClusterSpeedEstimator.estimate(devices: profiles.map { .init(chip: $0.1.chip, osBuild: $0.1.osBuild) },
            artifactSHA256: layout.artifactSHA256, promptTokens: promptTokens ?? layout.maximumPromptTokens, measurements: measurements,
            indices: profiles.compactMap { $0.1.speedIndex })
        var devices = zip(profiles, speeds).map { ClusterPlacementDevice(label: $0.0.0, profile: $0.0.1, speed: $0.1) }
        // Requests this pair served are measurements too: the next plan starts from them.
        let members = Set(profiles.map { $0.0 })
        let ours = served.filter { $0.setup.modelID == description.publicModelID && ($0.setup.ranks.map { Set($0) == members } ?? false) }
        var servedLines: [String] = []
        if !ours.isEmpty {
            let derived = try ClusterServedCalibration.measurements(entries: ours, devices: devices, layout: layout, link: .unmeasured,
                measuredUTC: ISO8601DateFormatter().string(from: Date()))
            servedLines = ["Speed records from served requests"] + derived.lines
            if !derived.measurements.isEmpty {
                let again = ClusterSpeedEstimator.estimate(devices: profiles.map { .init(chip: $0.1.chip, osBuild: $0.1.osBuild) },
                    artifactSHA256: layout.artifactSHA256, promptTokens: promptTokens ?? layout.maximumPromptTokens,
                    measurements: measurements + derived.measurements, indices: profiles.compactMap { $0.1.speedIndex })
                devices = zip(profiles, again).map { ClusterPlacementDevice(label: $0.0.0, profile: $0.0.1, speed: $0.1) }
            }
        }
        let result = try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: policy)
        var lines = (benchCap.map(ClusterPlannerBenchCap.lines(capBytes:)) ?? []) + servedLines
            + ClusterPlacementExplanation.describe(result, devices: devices, layout: layout)
        if let note = granted.note { lines.append("Pair-serving grant"); lines.append("  " + note) }
        if records.restrictsShapes {
            lines.append("Qualified placements")
            lines.append("  This model diverged from its single-Mac reference in a cross-cable check at some placement, so only placements "
                + "a check passed in are planned: \(records.passedShapesText).")
        }
        var setup: ClusterPlacementSetup?
        if let chosen = result.chosen {
            var described = description
            if description.derivesRequestLimits {
                let chunk = ClusterPlacementRequestLimits.chunkTokens(runtimeModelID: capability.runtimeModelID,
                    layoutMaximum: layout.maximumChunkTokens, capabilityMaximum: capability.profile.maximumChunkTokens)
                let deadline = ClusterPlacementRequestLimits.requestTimeoutSeconds(result: result, chosen: chosen,
                    maximumPromptTokens: capability.profile.maximumPromptTokens, maximumOutputTokens: capability.profile.maximumOutputTokens)
                described = description.withRequestLimits(chunkTokens: chunk.tokens, requestTimeoutSeconds: deadline.seconds)
                lines.append("Request limits")
                lines.append("  Prefill chunk " + chunk.basis + ".")
                lines.append("  Request deadline " + deadline.basis + ".")
            }
            let value = try ClusterPlacementSetup.synthesize(description: described, capability: capability, chosen: chosen)
            lines.append("What happens next")
            lines += value.narration(localMemberID: localMemberID).map { "  " + $0 }
            setup = value
        }
        return (lines, result, setup)
    }

    /// Which Mac must lead for the placement to be one the model's
    /// pair-serving grant allows, read from the chip names the two profiles
    /// carry: the last rank is the decoding rank, the other the pipeline-only
    /// rank (`ClusterPairServingRole`). Nil leaves the planner free.
    ///
    /// A plan is advice and a profile is what a Mac printed about itself, so
    /// nothing is opened here: each Mac still checks the rank it runs with its
    /// own chip before it serves. This only keeps the planner from choosing an
    /// order that start would refuse, and says so. A chip name with no class
    /// (a test profile, a virtual machine) is left to that check. A model
    /// whose grant is withheld is still planned, with the refusal in `note`,
    /// since a plan also answers whether the pair could hold it.
    static func leaderUnderGrant(requested: String?, members: [(id: String, chip: String)],
                                 runtimeModelID: String, publicModelID: String,
                                 artifactSHA256: String? = nil) throws -> (leader: String?, note: String?) {
        guard members.count == 2 else { return (requested, nil) }
        let grant: ClusterPairServingGrant
        do {
            grant = try ClusterPairServingGrants.grant(runtimeModelID: runtimeModelID, publicModelID: publicModelID,
                                                       artifactSHA256: artifactSHA256)
        } catch let refusal as ClusterPairServingRefusal {
            return (requested, refusal.description + " A setup made from this plan is refused when it is started.")
        }
        let classes = members.map { ClusterChipClass(chipName: $0.chip) }
        /// The refusal a start would give when `first` leads; nil when the grant allows the order.
        func refusal(leading first: Int) -> ClusterPairServingRefusal? {
            for (rank, member) in [first, 1 - first].enumerated() {
                guard let chipClass = classes[member], let role = ClusterPairServingRole.of(rank: rank, rankCount: 2) else { continue }
                let allowed = grant.chipClasses(for: role)
                if !allowed.contains(chipClass) {
                    return .init(runtimeModelID: runtimeModelID, publicModelID: publicModelID,
                        reason: .classNotAllowed(rank: rank, role: role, chipClass: chipClass, allowed: allowed.sorted()))
                }
            }
            return nil
        }
        if let requested, let index = members.firstIndex(where: { $0.id == requested }) {
            if let refused = refusal(leading: index) { throw refused }
            return (requested, nil)
        }
        let refused = [refusal(leading: 0), refusal(leading: 1)]
        switch (refused[0], refused[1]) {
        case (nil, nil): return (requested, nil)
        case (.some(let both), .some): throw both
        default:
            let leader = refused[0] == nil ? 0 : 1
            func words(_ classes: Set<ClusterChipClass>) -> String { classes.sorted().map(\.rawValue).joined(separator: " or ") }
            return (members[leader].id, "This model is granted pair serving with the decoding rank (the last) on "
                + "\(words(grant.decodingRankChipClasses)) and the other rank on \(words(grant.pipelineRankChipClasses)). "
                + "On these two Macs that leaves one order, so \(members[leader].id) leads; the other order is not planned.")
        }
    }
}
