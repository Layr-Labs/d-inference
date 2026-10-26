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
                              link: ClusterLinkCosts = .unmeasured,
                              incumbentMode: ClusterGenerationMode? = nil,
                              environment: [String: String] = ProcessInfo.processInfo.environment,
                              benchDebugBuild: Bool = ClusterPlannerBenchCap.isDebugBuild) throws
        -> (lines: [String], result: ClusterPlacementResult, setup: ClusterPlacementSetup?) {
        // Developer bench only (`ClusterPlannerBenchCap`): a debug build may be told to plan as if each Mac could
        // give less memory than it detected; a release build refuses. The load gates never see this.
        let benchCap = try ClusterPlannerBenchCap.capBytes(environment: environment, debugBuild: benchDebugBuild)
        // Sharded deployments only unless the one explicit opt-in is set (`ClusterHandOffModes`, off by default).
        let handOff = try ClusterHandOffModes.enabled(environment: environment)
        // Developer bench only (`ClusterBenchChip`): a debug build may be told to plan both Macs as another chip.
        let benchChip = try ClusterBenchChip.planningChipName(environment: environment, debugBuild: benchDebugBuild)
        // Developer only (`ClusterForcedModeSetting`): a debug build may be told which mode family to place.
        let forced = try ClusterForcedModeSetting.mode(environment: environment, debugBuild: benchDebugBuild)
        let cappedLocal = try benchCap.map { try localProfile.cappedForBench(admissibleBytes: $0) } ?? localProfile
        let cappedPeer = try benchCap.map { try peerProfile.cappedForBench(admissibleBytes: $0) } ?? peerProfile
        let localProfile = try benchChip.map { try cappedLocal.renamedForBench(chip: $0) } ?? cappedLocal
        let peerProfile = try benchChip.map { try cappedPeer.renamedForBench(chip: $0) } ?? cappedPeer
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
        // A model no stage adapter runs is still planned, with the refusal in the plan's words; records never rule a
        // chip, an order or a mode out (owner, 2026-10-14 08:45).
        let granted = try leaderUnderGrant(requested: leader, members: [(local.id, localProfile.chip), (peer.id, peerProfile.chip)],
            runtimeModelID: capability.runtimeModelID, publicModelID: description.publicModelID,
            artifactSHA256: capability.artifactSHA256)
        policy.leader = granted.leader
        // The planner keeps to what a start accepts: any sharded mode the worker lists, with or without a record,
        // except the exact shapes a cross-cable check diverged at on these chips (`ClusterPairQualificationRecords`;
        // owner 2026-10-14 08:45).
        let records = ClusterPairServingGrants.records(runtimeModelID: capability.runtimeModelID,
            artifactSHA256: capability.artifactSHA256)
        let runtimeModelID = capability.runtimeModelID, artifactSHA256 = capability.artifactSHA256
        policy.admitsShape = { chips, cuts, mode in
            ClusterPairServingGrants.plannable(chips.map { ClusterChipClass(chipName: $0) }, cuts: cuts, mode: mode,
                runtimeModelID: runtimeModelID, artifactSHA256: artifactSHA256)
        }
        // A pipeline's speculative rounds, lossless by their passing records,
        // are credited the speed-up those records measured until this pair has
        // served the same placement both with and without them (the served
        // calibration's only source of the factor; owner rule: on by default
        // where lossless and faster).
        let recordedRounds = ClusterPairServingGrants.recordedPipelineSpeculativeFactor(runtimeModelID: runtimeModelID,
            artifactSHA256: artifactSHA256)
        policy.recordedPipelineSpeculativeFactor = recordedRounds
        policy.modes = capability.supportedGenerationModes
        policy.handOffModes = handOff
        policy.forcedMode = forced
        policy.schedules = capability.supportedPrefillSchedules
        let profiles = [(local.id, localProfile), (peer.id, peerProfile)]
        let speeds = ClusterSpeedEstimator.estimate(devices: profiles.map { .init(chip: $0.1.chip, osBuild: $0.1.osBuild) },
            artifactSHA256: layout.artifactSHA256, promptTokens: promptTokens ?? layout.maximumPromptTokens, measurements: measurements,
            indices: profiles.compactMap { $0.1.speedIndex })
        // Speeds that are only ratios become each Mac's own index estimate when tensor parallel is open
        // (`ClusterHardwarePrior`), so a request served in tensor parallel can correct them.
        var devices = ClusterHardwarePrior.absolute(zip(profiles, speeds).map { ClusterPlacementDevice(label: $0.0.0, profile: $0.0.1, speed: $0.1) },
            layout: layout, link: link)
        // Requests this pair served are measurements too: the next plan starts from them.
        let members = Set(profiles.map { $0.0 })
        let ours = served.filter { $0.setup.modelID == description.publicModelID && ($0.setup.ranks.map { Set($0) == members } ?? false) }
        // The request this pair's served requests look like (decode-heavy or prompt-heavy) is the one the
        // planner chooses tensor parallel or a pipeline for, unless the caller named one.
        if promptTokens == nil, outputTokens == nil, let mix = ClusterRequestMix.reference(ours.map(\.sample), layout: layout) {
            policy.promptTokens = mix.promptTokens; policy.outputTokens = mix.outputTokens
        }
        var servedLines: [String] = []
        if !ours.isEmpty {
            // With the measured link, so that requests served in tensor parallel correct each rank's share.
            let derived = try ClusterServedCalibration.measurements(entries: ours, devices: devices, layout: layout, link: link,
                measuredUTC: ISO8601DateFormatter().string(from: Date()))
            servedLines = ["Speed records from served requests"] + derived.lines
            if !derived.measurements.isEmpty {
                let again = ClusterSpeedEstimator.estimate(devices: profiles.map { .init(chip: $0.1.chip, osBuild: $0.1.osBuild) },
                    artifactSHA256: layout.artifactSHA256, promptTokens: promptTokens ?? layout.maximumPromptTokens,
                    measurements: measurements + derived.measurements, indices: profiles.compactMap { $0.1.speedIndex })
                devices = ClusterHardwarePrior.absolute(zip(profiles, again).map { ClusterPlacementDevice(label: $0.0.0, profile: $0.0.1, speed: $0.1) },
                    layout: layout, link: link)
            }
        }
        // What this pair served in each mode, for the reference request, and the mode the plan keeps because of it
        // (`ClusterServedModes.hold`): after a Darkbloom update (`incumbentMode`, the same model on the same pair)
        // the mode the pair served in, unless the planner and the pair's own requests both find another faster;
        // otherwise, once the pair served two modes, the one it served faster. A developer's forced mode keeps nothing.
        let reference = (prompt: policy.promptTokens ?? layout.maximumPromptTokens, output: policy.outputTokens ?? layout.maximumOutputTokens)
        let servedModes = ClusterServedModes.figures(ours, promptTokens: reference.prompt, outputTokens: reference.output)
        if !servedModes.isEmpty {
            servedLines += ["Served requests by mode"]
                + ClusterServedModes.lines(servedModes, promptTokens: reference.prompt, outputTokens: reference.output)
        }
        let plannable = capability.supportedGenerationModes.filter { layout.generationModes.contains($0) && (handOff || !$0.isHandOff) }
        if forced == nil, let hold = ClusterServedModes.hold(incumbent: incumbentMode, figures: servedModes, plannable: plannable,
                                                              promptTokens: reference.prompt, outputTokens: reference.output) {
            policy.keptMode = hold.mode; policy.keptModeMargin = hold.margin; policy.keptModeReason = hold.reason
        }
        // The link as the pair's last load measured it (`ClusterLinkProbeHistory`);
        // unmeasured, no tensor-parallel mode is chosen.
        let result = try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: policy, link: link)
        var lines = (forced.map(ClusterForcedModeSetting.lines) ?? [])
            + (benchCap.map(ClusterPlannerBenchCap.lines(capBytes:)) ?? []) + (benchChip.map(ClusterBenchChip.lines(chipName:)) ?? [])
            + servedLines
            + ClusterPlacementExplanation.describe(result, devices: devices, layout: layout)
        if let why = ClusterPlacementExplanation.deploymentReason(result) {
            lines += ["Tensor parallel or pipeline", "  " + why]
        }
        if handOff {
            lines += ClusterHandOffModes.lines(enabled: true)
        } else if let note = lines.firstIndex(where: { $0.hasPrefix("  Phase split, phase split + MTP") }) {
            lines.insert(contentsOf: ClusterHandOffModes.lines(enabled: false), at: note + 1)
        }
        if let recordedRounds, capability.supportedGenerationModes.contains(.pipelineMTP) {
            lines.append("Speculative rounds")
            lines.append("  " + String(format: "Pipeline speculative rounds are credited %.2fx", recordedRounds)
                + " over the plain pipeline: the decode speed-up this model's passing qualification records measured. "
                + "This pair's own figure replaces it once the pair has served the same placement both with and without the rounds.")
        }
        if let note = granted.note { lines.append("Pair serving"); lines.append("  " + note) }
        if records.restrictsShapes {
            lines.append("Diverged placements")
            lines.append("  This model diverged from its single-Mac reference in a cross-cable check at some placements "
                + "(\(records.restrictedFamilies.sorted().map(\.description).joined(separator: ", ")) modes): \(records.failedShapesText). "
                + "Those exact shapes are not planned; every other placement is, on any Macs.")
        }
        // Public traffic in one line (owner serving never waits for it): the coordinator's parity qualification decides.
        let publicLine = ClusterPairServingGrants.publicTrafficLine(runtimeModelID: capability.runtimeModelID,
            artifactSHA256: capability.artifactSHA256, mode: result.chosen?.mode)
        lines.append("Public traffic")
        lines.append("  " + publicLine.prefix(1).uppercased() + publicLine.dropFirst() + ".")
        var setup: ClusterPlacementSetup?
        if let chosen = result.chosen {
            var described = description
            if description.derivesRequestLimits {
                let chunk = ClusterPlacementRequestLimits.chunkTokens(runtimeModelID: capability.runtimeModelID,
                    artifactSHA256: capability.artifactSHA256, layoutMaximum: layout.maximumChunkTokens, capabilityMaximum: capability.profile.maximumChunkTokens)
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

    /// Which Mac leads, and a note when no cluster stage adapter runs the
    /// model (the owner's only refusal besides memory, owner 2026-10-14
    /// 08:45). Records never rule a leader, an order or a mode out: the
    /// planner keeps to what a start accepts through
    /// `ClusterPairServingGrants.plannable` (the shapes that diverged). A
    /// refused model is still planned, with the refusal in `note`, since a
    /// plan also answers whether the pair could hold it.
    static func leaderUnderGrant(requested: String?, members: [(id: String, chip: String)],
                                 runtimeModelID: String, publicModelID: String,
                                 artifactSHA256: String? = nil) throws -> (leader: String?, note: String?) {
        guard members.count == 2 else { return (requested, nil) }
        do {
            _ = try ClusterPairServingGrants.ownerServing(runtimeModelID: runtimeModelID, publicModelID: publicModelID,
                                                          artifactSHA256: artifactSHA256)
        } catch let refusal as ClusterPairServingRefusal {
            return (requested, refusal.description + " A setup made from this plan is refused when it is started.")
        }
        return (requested, nil)
    }
}
