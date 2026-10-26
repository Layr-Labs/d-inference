import Darwin
import Foundation
import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import DarkbloomClusterRemote

/// The device profiles of a pair's members as the last plan read them (each
/// Mac's `darkbloom-cluster-plan device --json --index`), by member ID, in
/// `~/.darkbloom/cluster/member-profiles.json` (owner-only). Planning writes
/// it, whichever way it ran (the guided flow, `darkbloom cluster plan`); the
/// serving leader reads it to price each request's route. System facts only:
/// chip, cores, memory, OS build and the speed index; no name, no address.
public struct ClusterMemberProfiles: Codable, Sendable, Equatable {
    public static let schemaName = "darkbloom_cluster_member_profiles_v1"
    public static let maximumBytes = 262_144
    public static let maximumMembers = 16
    public let schema: String
    public let updatedAt: Double
    public let profiles: [String: ClusterDeviceProfile]

    public init(updatedAt: Double, profiles: [String: ClusterDeviceProfile]) {
        schema = Self.schemaName; self.updatedAt = updatedAt; self.profiles = profiles
    }

    public static func defaultFile(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent(".darkbloom/cluster/member-profiles.json")
    }

    /// Nil when absent, unreadable, not owner-only or malformed.
    public static func read(_ file: URL) -> ClusterMemberProfiles? {
        guard let data = try? ClusterConfigurationFiles.read(file, maximum: maximumBytes, privateMode: true),
              let value = try? JSONDecoder().decode(ClusterMemberProfiles.self, from: data),
              value.schema == schemaName, value.profiles.count <= maximumMembers,
              value.profiles.keys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 }) else { return nil }
        return value
    }

    /// Adds (or replaces) these members' profiles; others stay. Never throws
    /// into planning: a plan that cannot record them only routes nothing.
    @discardableResult
    public static func record(_ profiles: [String: ClusterDeviceProfile], homeDirectory: URL,
                              now: Double = Date().timeIntervalSince1970) -> Bool {
        let file = defaultFile(homeDirectory: homeDirectory)
        do {
            try ClusterConfigurationFiles.update(file, maximum: maximumBytes) { old in
                var kept = old.flatMap { try? JSONDecoder().decode(ClusterMemberProfiles.self, from: $0) }?.profiles ?? [:]
                for (id, profile) in profiles { kept[id] = profile }
                if kept.count > maximumMembers { kept = profiles }
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                return try encoder.encode(ClusterMemberProfiles(updatedAt: now, profiles: kept))
            }
            return true
        } catch { return false }
    }
}

/// Speed records written from served requests (`served-speed.json`), as the
/// planner and the router take them.
public enum ClusterServedSpeedHistory {
    /// Every usable record of the leader's file, each with the setup it was
    /// served on (model, mode, cut, members in rank order when recorded).
    public static func entries(homeDirectory: URL) -> [ClusterServedSpeedRecords.Entry] {
        guard let file = ClusterServedSpeedFile.read(ClusterServedSpeedFile.defaultFile(homeDirectory: homeDirectory)) else { return [] }
        return file.records.compactMap { record in
            guard record.isSpeedRecord, let sample = ClusterServedSample.fromTelemetry(route: record.route, promptTokens: record.promptTokens,
                cachedTokens: record.cachedTokens, completionTokens: record.completionTokens,
                firstTokenMilliseconds: record.firstTokenMilliseconds, decodeTokensPerSecond: record.decodeTokensPerSecond,
                outcome: record.outcome, finishedAt: record.finishedAt) else { return nil }
            return .init(setup: .init(modelID: record.modelID, mode: record.mode, cut: record.cut, ranks: record.ranks), sample: sample)
        }
    }

    /// The entries served on this pair of members (in either order) for this model.
    public static func entries(homeDirectory: URL, modelID: String, members: Set<String>) -> [ClusterServedSpeedRecords.Entry] {
        entries(homeDirectory: homeDirectory).filter {
            $0.setup.modelID == modelID && ($0.setup.ranks.map { Set($0) == members } ?? false)
        }
    }
}

/// The router a serving leader keeps for its saved setup: one decision per
/// request between the pair as placed and the member that already holds the
/// whole model (a phase split's decoding rank) serving it alone
/// (`ClusterRequestRouter`). Derived at start from what this setup is and
/// what was detected and served, never from a table: the members' profiles
/// the last plan recorded, the model's layout read by the plan tool installed
/// beside the worker, the speed estimates from the profiles' indices
/// corrected by the speed records of requests this pair served.
public enum ClusterRequestRoutingBasis {
    public struct Outcome: Sendable {
        /// Nil: every request runs as placed.
        public let routing: ClusterRequestRouting?
        /// In plain words: what decides, or why nothing is routed.
        public let note: String
    }

    /// The routing for a validated plan. Never throws: any missing input
    /// leaves every request on the pair as placed, which is always qualified.
    static func make(plan: DistributedInstalledPlan, homeDirectory: URL, deadline: UInt64,
                     environment: [String: String] = ProcessInfo.processInfo.environment) -> Outcome {
        guard !plan.capability.hasPrivateImages else {
            return .init(routing:nil,note:"private image candidate: every request uses the bound native two-rank pipeline")
        }
        let configuration = plan.configuration
        let mode = configuration.selectedGenerationMode
        guard mode.isPhaseSplit else {
            return .init(routing: nil, note: "every request uses the pair: under \(mode.rawValue) no member holds the whole model")
        }
        // The alone route is kept but off by default (sharded deployments only, owner 2026-10-13): a saved phase split
        // setup still serves every request as placed unless the leader runs with the explicit opt-in.
        guard (try? ClusterHandOffModes.enabled(environment: environment)) == true else {
            return .init(routing: nil, note: "every request uses the cluster as placed: the per-request alone route is off by default "
                + "(sharded deployments only; \(ClusterHandOffModes.environmentName)=1 opts in). Plan again with `darkbloom cluster` for a sharded setup")
        }
        let stages = plan.partition.stages.sorted { $0.rank < $1.rank }
        let ranks = configuration.peers.sorted { $0.rank < $1.rank }.map(\.id)
        guard stages.count == ranks.count, ranks.count >= 2 else {
            return .init(routing: nil, note: "every request uses the pair: the plan's stages and members differ")
        }
        guard let recorded = ClusterMemberProfiles.read(ClusterMemberProfiles.defaultFile(homeDirectory: homeDirectory)),
              ranks.allSatisfy({ recorded.profiles[$0] != nil }) else {
            return .init(routing: nil, note: "every request uses the pair: no plan of this pair recorded both Macs' profiles "
                + "(plan it with `darkbloom cluster`)")
        }
        let layout: ClusterModelLayout
        do { layout = try ClusterInstalledHoldings.readLayout(configuration: configuration, deadline: deadline) } catch {
            return .init(routing: nil, note: "every request uses the pair: the model's layout was not read (\(String(describing: error).prefix(160)))")
        }
        guard layout.runtimeModelID == plan.capability.runtimeModelID, layout.artifactSHA256 == plan.capability.artifactSHA256,
              layout.configurationSHA256 == plan.capability.configurationSHA256 else {
            return .init(routing: nil, note: "every request uses the pair: the model directory's layout and the saved capability record differ")
        }
        let cuts = stages.dropLast().map(\.sourceLayerEnd)
        let profiles = ranks.map { (label: $0, profile: recorded.profiles[$0]!) }
        func devices(_ measurements: [ClusterSpeedMeasurement]) -> [ClusterPlacementDevice] {
            let speeds = ClusterSpeedEstimator.estimate(devices: profiles.map { .init(chip: $0.profile.chip, osBuild: $0.profile.osBuild) },
                artifactSHA256: layout.artifactSHA256, promptTokens: layout.maximumChunkTokens, measurements: measurements,
                indices: profiles.compactMap { $0.profile.speedIndex })
            return zip(profiles, speeds).map { ClusterPlacementDevice(label: $0.0.label, profile: $0.0.profile, speed: $0.1) }
        }
        let modelID = configuration.publicModelID
        let setupKey = ClusterServedSpeedRecords.Setup(modelID: modelID, mode: mode.rawValue,
            cut: ClusterServedSpeedRecords.Setup.cut(cuts, layerCount: layout.layerCount), ranks: ranks)
        // The estimates start from what this pair served, as the next plan does.
        var placed = devices([])
        let served = ClusterServedSpeedHistory.entries(homeDirectory: homeDirectory, modelID: modelID, members: Set(ranks))
        if let derived = try? ClusterServedCalibration.measurements(entries: served, devices: placed, layout: layout,
                                                                    link: .unmeasured, measuredUTC: "served"),
           !derived.measurements.isEmpty {
            placed = devices(derived.measurements)
        }
        let setup = ClusterRequestRouter.Setup(devices: placed, cuts: cuts, mode: mode,
            schedule: configuration.selectedPrefillSchedule, layout: layout, aloneRoute: true)
        let routing = ClusterRequestRouting(setup: setup) {
            ClusterServedSpeedHistory.entries(homeDirectory: homeDirectory).filter { $0.setup == setupKey }.map(\.sample)
        }
        let samples = served.filter { $0.setup == setupKey }.map(\.sample)
        let outputs = ClusterRequestRouter.expectedOutputTokens(maximum: 256, served: samples)
        let alone = setup.membersHoldingWholeModel.first?.label ?? "-"
        let note: String
        do {
            switch try ClusterRequestRouter.crossoverPromptTokens(setup, outputTokens: outputs,
                                                                  maximumPrompt: plan.capability.profile.maximumPromptTokens, served: samples) {
            case 1?: note = "every request uses the pair: it is predicted faster than \(alone) alone at every prompt length"
            case let tokens?: note = "prompts of \(tokens) tokens or more use the pair; shorter ones \(alone) alone"
            case nil: note = "every request is served by \(alone) alone: the pair is never predicted faster"
            }
        } catch { note = "routes are decided per request" }
        return .init(routing: routing, note: note + " (\(samples.count) speed record(s) of this setup; "
            + (placed.allSatisfy(\.speed.absolute) ? "measured speeds" : "speed index ratios") + ")")
    }
}
