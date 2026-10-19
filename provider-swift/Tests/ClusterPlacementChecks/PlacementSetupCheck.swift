import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation

/// The guided flow's choice of rank order and Plan: both members' setups are
/// written from a placement, and say the same thing a typed setup would.
@main @MainActor struct PlacementSetupCheck {
    static var failures: [String] = []
    static var passed = 0
    static func require(_ name: String, _ value: @autoclosure () throws -> Bool) {
        do { if try value() { passed += 1 } else { failures.append(name) } } catch { failures.append("\(name): \(error)") }
    }
    static func refuses(_ name: String, because reason: String, _ body: () throws -> Void) {
        do { try body(); failures.append("accepted: " + name) } catch {
            if String(describing: error).contains(reason) { passed += 1 } else { failures.append("\(name): \(error)") }
        }
    }
    static func hash(_ character: Character) -> String { String(repeating: String(character), count: 64) }
    static let gib = 1_073_741_824

    /// A device whose gate would admit `freeGiB` now; the numbers are plain inputs.
    static func device(_ label: String, physicalGiB: Int, freeGiB: Int, prefill: Double, decode: Double) throws -> ClusterPlacementDevice {
        let physical = physicalGiB * gib, free = freeGiB * gib
        let memory = ClusterDeviceMemory(gatePolicy: "check", sampledUTC: "2026-10-09T00:00:00Z", judged: true, unjudgedReason: nil,
            physicalMemoryBytes: physical, actualFreeBytes: free, countedFileCacheBytes: 0, admissibleNowBytes: free,
            fileBackedBytes: 0, fileCacheReserveBytes: 0, fileCacheAboveReserveBytes: 0, anonymousBytes: physical - free - 4 * gib, wiredBytes: 4 * gib, compressorBytes: 0,
            pageableBytes: physical - 4 * gib, pressureLevel: 1, swapUsedBytes: 0, minimumAdmissibleBytes: 6 * gib,
            minimumTrulyFreeBytes: 16 * 1_048_576, loadingHeadroomBytes: 4 * gib, allocatorHeadroomBytes: 2 * gib,
            loadScratchBytes: 8 * 1_048_576, pageSizeBytes: 16_384)
        let profile = try ClusterDeviceProfile(chip: "Check chip", performanceCores: 8, efficiencyCores: 4, gpuCores: nil,
            osVersion: "27.0", osBuild: "CHECK", physicalMemoryBytes: physical, gpuRecommendedWorkingSetBytes: physical / 4 * 3,
            gpuMaximumBufferBytes: physical / 2, allocatorLimitBytes: physical / 10 * 9, memory: memory,
            power: .init(onExternalPower: true, lowPowerMode: false, thermalState: "nominal"))
        return .init(label: label, profile: profile, speed: .init(source: .measured, absolute: true,
            rested: .init(prefillTokensPerSecond: prefill, decodeTokensPerSecond: decode), sustained: nil, explanation: "check"))
    }

    /// `setup-check flow PAIR CAPABILITY MEMBER LOCAL_PROFILE PEER_PROFILE LAYOUT OUT [SPEED...]`
    /// runs the guided step's own decision on files, for looking at what it
    /// prints for a real pair without the provider build. The profiles and
    /// the layout are the ones `darkbloom-cluster-plan` printed; nothing is
    /// detected here. It writes the two setups into OUT, a new directory.
    static func flow(_ arguments: [String]) throws {
        guard arguments.count >= 7 else { throw ClusterConfigurationError.invalid("flow needs PAIR CAPABILITY MEMBER LOCAL_PROFILE PEER_PROFILE LAYOUT OUT [SPEED...]") }
        func read(_ path: String) throws -> Data { try Data(contentsOf: URL(fileURLWithPath: path)) }
        let description = try ClusterPairDescription.decode(read(arguments[0]))
        let capabilityData = try read(arguments[1])
        guard ClusterConfigurationCodec.sha256(capabilityData) == description.capabilitySHA256 else {
            throw ClusterConfigurationError.invalid("the pair description pins another capability record")
        }
        let decided = try ClusterPlacementFlow.decide(description: description,
            capability: try ClusterRuntimeCapabilityCodec.decode(capabilityData), localMemberID: arguments[2],
            localProfile: try ClusterDeviceProfile.decode(read(arguments[3])), peerProfile: try ClusterDeviceProfile.decode(read(arguments[4])),
            layout: try ClusterModelLayout.decode(read(arguments[5])),
            measurements: try arguments.dropFirst(7).map { try JSONDecoder().decode(ClusterSpeedMeasurement.self, from: read($0)) })
        for line in decided.lines { print(line) }
        guard let setup = decided.setup else { return }
        let output = URL(fileURLWithPath: arguments[6], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        for (member, data) in setup.configurations { try data.write(to: output.appendingPathComponent(member + ".setup.json")) }
    }

    /// MTP with the phase split, under the hand-off opt-in (`ClusterHandOffModes`;
    /// off by default since 2026-10-13, sharded deployments only): with the
    /// row's credit and the head in the layout (as the plan tool now reads
    /// them), the guided step saves `phase_split_mtp_v1` in both setups with
    /// the M5 decoding, and never the head on the M3 Ultra.
    static func speculativeHeadByDefault(layout: ClusterModelLayout, description: ClusterPairDescription,
                                         capability: ClusterRuntimeCapability, capabilityHash: String,
                                         slowTwo: [ClusterPlacementDevice]) throws {
        var object = try JSONSerialization.jsonObject(with: layout.encoded()) as! [String: Any]
        object["speculativeDecodeFactor"] = 1.44
        object["excluded"] = ["storedBytes": 136_881_152, "loadedBytes": 136_881_152, "largestTensorBytes": 31_457_280,
                              "tensorCount": 31, "requestWorkBytes": 0]
        object["speculativeHead"] = object["excluded"]
        let headed = try ClusterModelLayout.decode(JSONSerialization.data(withJSONObject: object))
        func chip(_ device: ClusterPlacementDevice, _ name: String) throws -> ClusterDeviceProfile {
            let p = device.profile
            return try .init(chip: name, performanceCores: p.performanceCores, efficiencyCores: p.efficiencyCores, gpuCores: p.gpuCores,
                osVersion: p.osVersion, osBuild: p.osBuild, physicalMemoryBytes: p.physicalMemoryBytes,
                gpuRecommendedWorkingSetBytes: p.gpuRecommendedWorkingSetBytes, gpuMaximumBufferBytes: p.gpuMaximumBufferBytes,
                allocatorLimitBytes: p.allocatorLimitBytes, memory: p.memory, power: p.power)
        }
        // mac-one is the 128 GiB M5, mac-two the 256 GiB M3 Ultra; nothing measured, as in the product today.
        let m5 = try chip(slowTwo[0], "Apple M5 Max"), m3 = try chip(slowTwo[1], "Apple M3 Ultra")
        for (who, local, peer) in [("mac-one", m5, m3), ("mac-two", m3, m5)] {
            let decided = try ClusterPlacementFlow.decide(description: description, capability: capability, localMemberID: who,
                localProfile: local, peerProfile: peer, layout: headed, environment: handOff)
            let configurations = try decided.setup.map { setup in
                try setup.configurations.values.map {
                    try ClusterConfigurationCodec.decode($0, capability: capability, capabilitySHA256: capabilityHash)
                }
            } ?? []
            // Under the opt-in the hand-off modes are ranked beside the sharded ones: the phase split + MTP with the
            // M3 Ultra leading and the M5 decoding is a candidate, but the 9B's passing pipeline_mtp_v1 records
            // (chip-agnostic since 2026-10-14) credit the pipeline's rounds 1.74x against the phase split's 1.44x
            // row, so the fastest, the pipeline's rounds, is chosen and saved by name in both setups.
            require("planned from \(who) under the hand-off opt-in: the phase split + MTP (M3 Ultra leading) is ranked, the recorded rounds are chosen and saved by name in both setups (chose \(decided.result.chosen?.mode.rawValue ?? "-"))",
                decided.result.chosen?.mode == .pipelineMTP
                    && configurations.count == 2 && configurations.allSatisfy { $0.generationMode == .pipelineMTP }
                    && decided.lines.contains { $0.contains("mac-two then mac-one, phase_split_mtp_v1: relative time") }
                    && decided.lines.contains { $0.hasPrefix("  Opted in: phase split, phase split + MTP") })
        }
        // The other order is asked for: a grant lists no chip (owner, 2026-10-14), so the M5 leading is planned too.
        let mirrored = try ClusterPlacementFlow.decide(description: description, capability: capability, localMemberID: "mac-one",
            localProfile: m5, peerProfile: m3, layout: headed, leader: "mac-one", environment: handOff)
        require("led by the M5, the 9B fixture is planned in the order asked", mirrored.setup?.leaderID == "mac-one")
        // Two Macs of no known generation: nothing prefers the phase split's head there. The 9B's passing
        // pipeline_mtp_v1 record measured the pipeline's rounds faster (lossless by the near-tie rule), and chips
        // never gate (owner, 2026-10-14): the rounds are credited the record's speed-up and planned by default.
        let unknown = try ClusterPlacementFlow.decide(description: description, capability: capability, localMemberID: "mac-one",
            localProfile: slowTwo[0].profile, peerProfile: slowTwo[1].profile, layout: headed, environment: handOff)
        require("chips of no known generation: no phase-split head; the recorded rounds are planned with their credit (chose \(unknown.result.chosen?.mode.rawValue ?? "-"))",
            unknown.result.chosen?.mode == .pipelineMTP
                && unknown.lines.contains { $0.contains("Pipeline speculative rounds are credited") })
        // The served calibration credits the rounds only from the same placement served both with and without them
        // (`ClusterServedCalibration.measurements(entries:)`); a pair that serves the rounds by default never serves
        // the plain pipeline there, so the line must not promise that serving alone replaces the records' figure.
        require("the credit line names when this pair's own figure replaces the records' (the same placement served both ways)",
            unknown.lines.contains { $0.contains("Pipeline speculative rounds are credited") && $0.contains("both with and without") }
                && !unknown.lines.contains { $0.contains("Requests this pair serves replace that figure") })
        // By default (no opt-in) the same Macs and layout shard the model: no phase split, both Macs hold layers,
        // the plan lists every sharded candidate with its prediction and reason, and names the opt-in.
        let name = ClusterHandOffModes.environmentName
        require("hand-off modes: unset, \"0\" and \"off\" are off; \"1\" and \"on\" opt in",
            try !ClusterHandOffModes.enabled(environment: [:]) && !ClusterHandOffModes.enabled(environment: [name: "0"])
                && !ClusterHandOffModes.enabled(environment: [name: "off"]) && ClusterHandOffModes.enabled(environment: [name: "1"])
                && ClusterHandOffModes.enabled(environment: [name: "on"]))
        for bad in ["yes", "2", "true ", "ON"] {
            refuses("hand-off modes: \"\(bad)\" is refused", because: "sharded deployments only") {
                _ = try ClusterHandOffModes.enabled(environment: [name: bad])
            }
        }
        for (who, local, peer) in [("mac-one", m5, m3), ("mac-two", m3, m5)] {
            let sharded = try ClusterPlacementFlow.decide(description: description, capability: capability, localMemberID: who,
                localProfile: local, peerProfile: peer, layout: headed, environment: [:])
            let configurations = try sharded.setup.map { setup in
                try setup.configurations.values.map {
                    try ClusterConfigurationCodec.decode($0, capability: capability, capabilitySHA256: capabilityHash)
                }
            } ?? []
            require("planned from \(who), default: a sharded mode with layers on both Macs, saved by name in both setups (never a phase split)",
                sharded.result.chosen.map { $0.mode.isSharded && $0.ranks.allSatisfy { $0.endLayer > $0.firstLayer } } == true
                    && configurations.count == 2 && configurations.allSatisfy { $0.generationMode.map { !$0.isHandOff } ?? true })
            require("planned from \(who), default: the plan lists the sharded candidates and names the opt-in (\(sharded.lines.filter { $0.contains(": chosen") }.joined(separator: " | ")))",
                sharded.lines.contains("Sharded deployment candidates")
                    && sharded.lines.contains { $0.contains("pipeline with speculative rounds: chosen") }
                    && sharded.lines.contains { $0.contains(name + "=1") && $0.contains("never offered in the onboarding") })
        }
        refuses("hand-off modes: a malformed setting stops the plan instead of planning something else", because: name) {
            _ = try ClusterPlacementFlow.decide(description: description, capability: capability, localMemberID: "mac-one",
                localProfile: m5, peerProfile: m3, layout: headed, environment: [name: "yes"])
        }
        // A setup saved with a hand-off mode (by the earlier default planner, or under the opt-in) is served only
        // under the opt-in: the owner of each rank refuses it otherwise and names the way back to a sharded setup.
        for mode in ClusterGenerationMode.allCases {
            if mode.isHandOff {
                refuses("hand-off modes: a saved \(mode.rawValue) setup is not served without the opt-in", because: "off by default") {
                    try ClusterHandOffModes.requireServable(mode, environment: [:])
                }
                refuses("hand-off modes: the refusal of a saved \(mode.rawValue) setup says how to shard it", because: "`darkbloom cluster`") {
                    try ClusterHandOffModes.requireServable(mode, environment: [name: "0"])
                }
                require("hand-off modes: a saved \(mode.rawValue) setup is served under the opt-in",
                    try { try ClusterHandOffModes.requireServable(mode, environment: handOff); return true }())
            } else {
                require("hand-off modes: a saved \(mode.rawValue) setup is served by default",
                    try { try ClusterHandOffModes.requireServable(mode, environment: [:]); return true }())
            }
        }
        refuses("hand-off modes: a malformed setting stops a saved phase split from serving", because: name) {
            try ClusterHandOffModes.requireServable(.phaseSplitMTP, environment: [name: "yes"])
        }
    }

    static let handOff = [ClusterHandOffModes.environmentName: "1"]

    /// The developer bench cap (`ClusterPlannerBenchCap`, test only): an explicit environment variable that, in a
    /// debug build, lowers what the planner believes each member can give a model, so a large pair is planned as a
    /// smaller pair would be. A release build refuses it; the load gates never see it.
    /// DEVELOPER ONLY (`ClusterForcedModeSetting`): `DARKBLOOM_CLUSTER_FORCE_MODE` forces a deployment mode family in a
    /// debug build, for pilots; a release build refuses to plan while it is set; a value that names no family is
    /// refused; the plan and the setup screen say it loudly in one line. Memory, the model's mode list and the
    /// qualification shapes still decide (the planner's own checks, libs PlacementChecks "forced mode").
    static func forcedMode(layout: ClusterModelLayout, description: ClusterPairDescription, capability: ClusterRuntimeCapability,
                           slowTwo: [ClusterPlacementDevice]) throws {
        let name = ClusterForcedModeSetting.environmentName
        require("forced mode: the setting is named DARKBLOOM_CLUSTER_FORCE_MODE", name == "DARKBLOOM_CLUSTER_FORCE_MODE")
        require("forced mode: unset (or empty), nothing is forced in either build",
            try ClusterForcedModeSetting.mode(environment: [:], debugBuild: true) == nil
                && ClusterForcedModeSetting.mode(environment: [:], debugBuild: false) == nil
                && ClusterForcedModeSetting.mode(environment: [name: ""], debugBuild: true) == nil)
        require("forced mode: a debug build reads tensor_parallel_v1 and pipeline_v1 (and the plain family names)",
            try ClusterForcedModeSetting.mode(environment: [name: "tensor_parallel_v1"], debugBuild: true) == .tensorParallel
                && ClusterForcedModeSetting.mode(environment: [name: "tensor_parallel"], debugBuild: true) == .tensorParallel
                && ClusterForcedModeSetting.mode(environment: [name: "pipeline_v1"], debugBuild: true) == .pipeline
                && ClusterForcedModeSetting.mode(environment: [name: "pipeline"], debugBuild: true) == .pipeline)
        refuses("forced mode: a release build refuses to plan while it is set", because: "not available in a release build") {
            _ = try ClusterForcedModeSetting.mode(environment: [name: "tensor_parallel_v1"], debugBuild: false)
        }
        for bad in ["tp", "phase_split_v1", "pipeline_prefill_tensor_decode_v1", "TENSOR_PARALLEL_V1", "1"] {
            refuses("forced mode: \"\(bad)\" is refused", because: "tensor_parallel_v1 or pipeline_v1") {
                _ = try ClusterForcedModeSetting.mode(environment: [name: bad], debugBuild: true)
            }
        }
        require("forced mode: the setup screen's one loud line, debug build",
            ClusterForcedModeSetting.notice(environment: [name: "tensor_parallel_v1"], debugBuild: true)
                == "Developer setting: tensor parallel forced (DARKBLOOM_CLUSTER_FORCE_MODE=tensor_parallel_v1; debug build only)."
                && ClusterForcedModeSetting.notice(environment: [name: "pipeline_v1"], debugBuild: true)
                    == "Developer setting: pipeline forced (DARKBLOOM_CLUSTER_FORCE_MODE=pipeline_v1; debug build only).")
        require("forced mode: unset, the setup screen has no developer line", ClusterForcedModeSetting.notice(environment: [:], debugBuild: true) == nil
            && ClusterForcedModeSetting.notice(environment: [:], debugBuild: false) == nil)
        require("forced mode: set in a release build, the screen says it is refused (and nothing is forced)",
            ClusterForcedModeSetting.notice(environment: [name: "tensor_parallel_v1"], debugBuild: false)?
                .hasPrefix("Developer setting DARKBLOOM_CLUSTER_FORCE_MODE is set but refused:") == true)
        refuses("forced mode: a release build refuses to plan a pair while it is set", because: "not available in a release build") {
            _ = try ClusterPlacementFlow.decide(description: description, capability: capability, localMemberID: "mac-one",
                localProfile: slowTwo[0].profile, peerProfile: slowTwo[1].profile, layout: layout, environment: [name: "pipeline_v1"],
                benchDebugBuild: false)
        }
        let piped = try ClusterPlacementFlow.decide(description: description, capability: capability, localMemberID: "mac-one",
            localProfile: slowTwo[0].profile, peerProfile: slowTwo[1].profile, layout: layout, environment: [name: "pipeline_v1"],
            benchDebugBuild: true)
        require("forced mode: pipeline forced, the plan is a pipeline and its words open with the developer setting",
            piped.result.chosen.map { !$0.mode.usesTensorParallelDecode && !$0.mode.isHandOff } == true && piped.setup != nil
                && piped.lines.first == "Developer setting: pipeline forced (\(name)=pipeline_v1)"
                && piped.lines.contains { $0.contains("developer only") && $0.contains("never offered") })
        // This fixture's runtime lists no tensor-parallel mode: forcing it is refused (the adapter rule), not swapped.
        refuses("forced mode: tensor parallel forced on a model whose runtime has no tensor-parallel mode is refused",
                because: "tensor parallel forced") {
            _ = try ClusterPlacementFlow.decide(description: description, capability: capability, localMemberID: "mac-one",
                localProfile: slowTwo[0].profile, peerProfile: slowTwo[1].profile, layout: layout, environment: [name: "tensor_parallel_v1"],
                benchDebugBuild: true)
        }
        let plain = try ClusterPlacementFlow.decide(description: description, capability: capability, localMemberID: "mac-one",
            localProfile: slowTwo[0].profile, peerProfile: slowTwo[1].profile, layout: layout, environment: [:], benchDebugBuild: true)
        require("forced mode: unset, the plan carries no developer line", !plain.lines.contains { $0.contains("Developer setting") })
        // Hardware 2026-10-14 (round 6e, first forced run): the planner chose tensor parallel and the setup refused it
        // ("This build's installed path runs a placement of exactly two ranges"). A tensor-parallel placement cuts no layer
        // range: both setups carry tensor_parallel_v1, two ranks, and a Plan of the capability record as the load's
        // identity (the worker loads its share of every layer; the pair checks ran it the same way).
        guard let piped = plain.result.chosen else { require("tensor parallel setup: a fixture placement", false); return }
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(piped)) as! [String: Any]
        object["mode"] = ClusterGenerationMode.tensorParallel.rawValue; object["cuts"] = [Int]()
        let tensor = try JSONDecoder().decode(ClusterPlacementCandidate.self, from: JSONSerialization.data(withJSONObject: object))
        let setup = try? ClusterPlacementSetup.synthesize(description: description, capability: capability, chosen: tensor)
        let described = capability.partitions.compactMap { $0.stages.first?.sourceLayerEnd }
        let layers = capability.partitions.first?.stages.last?.sourceLayerEnd ?? 0
        let middle = described.min { abs(2 * $0 - layers) < abs(2 * $1 - layers) }
        require("tensor parallel setup: two setups, tensor_parallel_v1, the middle Plan as the load's identity",
            setup.map { setup in setup.configurations.count == 2 && setup.cut == middle
                && setup.configurations.values.allSatisfy { String(decoding: $0, as: UTF8.self).contains("\"generationMode\":\"tensor_parallel_v1\"") } } == true)
        var three = object; three["cuts"] = [middle ?? 1]
        let malformed = try JSONDecoder().decode(ClusterPlacementCandidate.self, from: JSONSerialization.data(withJSONObject: three))
        refuses("tensor parallel setup: a tensor-parallel placement with a cut is refused", because: "exactly two") {
            _ = try ClusterPlacementSetup.synthesize(description: description, capability: capability, chosen: malformed)
        }
    }

    static func benchCap(layout: ClusterModelLayout, description: ClusterPairDescription, capability: ClusterRuntimeCapability,
                         slowTwo: [ClusterPlacementDevice]) throws {
        let name = ClusterPlannerBenchCap.environmentName
        require("bench cap: the variable is named as a developer bench override", name.hasPrefix("DARKBLOOM_DEV_BENCH_"))
        require("bench cap: unset, nothing is capped in either build", try ClusterPlannerBenchCap.capBytes(environment: [:], debugBuild: true) == nil
            && ClusterPlannerBenchCap.capBytes(environment: [:], debugBuild: false) == nil)
        require("bench cap: a debug build reads whole GiB", try ClusterPlannerBenchCap.capBytes(environment: [name: "96"], debugBuild: true) == 96 * gib)
        refuses("bench cap: a release build refuses the override", because: "not available in a release build") {
            _ = try ClusterPlannerBenchCap.capBytes(environment: [name: "96"], debugBuild: false)
        }
        // The developer bench chip (`ClusterBenchChip`, test only): a debug build plans and checks ranks as that chip;
        // a release build never reads it for a rank's class and refuses to plan while it is set.
        let chip = ClusterBenchChip.environmentName
        require("bench chip: a debug build reads it, a release build ignores it for a rank",
            ClusterBenchChip.chipName(environment: [chip: "Apple M4 Max"], debugBuild: true) == "Apple M4 Max"
                && ClusterBenchChip.chipName(environment: [chip: "Apple M4 Max"], debugBuild: false) == nil
                && ClusterChipClass.local(environment: [chip: "Apple M4 Max"], debugBuild: true) == ClusterChipClass(chipName: "Apple M4 Max")
                && ClusterChipClass.local(environment: [chip: "Apple M4 Max"], debugBuild: false) == ClusterChipClass.local(environment: [:], debugBuild: false))
        refuses("bench chip: a release build refuses to plan while it is set", because: "not available in a release build") {
            _ = try ClusterBenchChip.planningChipName(environment: [chip: "Apple M4 Max"], debugBuild: false)
        }
        refuses("bench chip: a release build refuses to plan a pair while it is set", because: "not available in a release build") {
            _ = try ClusterPlacementFlow.decide(description: description, capability: capability, localMemberID: "mac-one",
                localProfile: slowTwo[0].profile, peerProfile: slowTwo[1].profile, layout: layout, environment: [chip: "Apple M4 Max"],
                benchDebugBuild: false)
        }
        refuses("bench chip: a name that is no Apple silicon chip is refused", because: "must name an Apple silicon chip") {
            _ = try ClusterBenchChip.planningChipName(environment: [chip: "Apple M1 (Virtual)"], debugBuild: true)
        }
        for bad in ["", "abc", "0", "-8", "1e3", "9.5", " 96", "99999999"] {
            refuses("bench cap: \"\(bad)\" is refused", because: "whole number of GiB") {
                _ = try ClusterPlannerBenchCap.capBytes(environment: [name: bad], debugBuild: true)
            }
        }
        let plain = try ClusterPlacementFlow.decide(description: description, capability: capability, localMemberID: "mac-one",
            localProfile: slowTwo[0].profile, peerProfile: slowTwo[1].profile, layout: layout, environment: [:], benchDebugBuild: true)
        require("bench cap: uncapped, a member holds the 5 GiB fixture whole", plain.result.alone.contains { $0.fit == .now }
            && !plain.lines.contains { $0.contains("Developer bench cap") })
        // Capped to 10 GiB each, no member can hold the model and its request alone: the plan is a real split.
        let capped = try ClusterPlacementFlow.decide(description: description, capability: capability, localMemberID: "mac-one",
            localProfile: slowTwo[0].profile, peerProfile: slowTwo[1].profile, layout: layout,
            environment: [name: "10"], benchDebugBuild: true)
        require("bench cap: capped to 10 GiB, neither member holds the model alone", capped.result.alone.allSatisfy { !$0.fit.possible })
        require("bench cap: capped to 10 GiB, the chosen plan is a split in which no rank holds every layer and each fits the cap",
            capped.result.chosen.map { chosen in !chosen.mode.isPhaseSplit && chosen.ranks.count == 2
                && chosen.ranks.allSatisfy { $0.needBytes <= 10 * gib && $0.endLayer > $0.firstLayer } } == true && capped.setup != nil)
        require("bench cap: the plan says the cap is on, that it is test only and that the load gates are unchanged",
            capped.lines.contains { $0.contains("Developer bench cap") && $0.contains(name) }
                && capped.lines.contains { $0.contains("test only") } && capped.lines.contains { $0.contains("load gate") && $0.contains("unchanged") })
        refuses("bench cap: a release build refuses to plan with the override set", because: "not available in a release build") {
            _ = try ClusterPlacementFlow.decide(description: description, capability: capability, localMemberID: "mac-one",
                localProfile: slowTwo[0].profile, peerProfile: slowTwo[1].profile, layout: layout,
                environment: [name: "10"], benchDebugBuild: false)
        }
        refuses("bench cap: a cap below the load gate's own minimum is refused", because: "below the load gate's minimum") {
            _ = try ClusterPlacementFlow.decide(description: description, capability: capability, localMemberID: "mac-one",
                localProfile: slowTwo[0].profile, peerProfile: slowTwo[1].profile, layout: layout,
                environment: [name: "2"], benchDebugBuild: true)
        }
    }

    /// The request the pair's own served requests look like (`ClusterRequestMix`) is the one the planner chooses
    /// tensor parallel or a pipeline for, and the plan says why in one line.
    static func requestMix(layout: ClusterModelLayout, description: ClusterPairDescription, capability: ClusterRuntimeCapability,
                           slowTwo: [ClusterPlacementDevice]) throws {
        func entry(_ prompt: Int, _ output: Int) -> ClusterServedSpeedRecords.Entry {
            .init(setup: .init(modelID: description.publicModelID, mode: ClusterGenerationMode.pipeline.rawValue, cut: "unknown",
                               ranks: description.members.map(\.id)),
                  sample: .init(route: .pair, member: nil, promptTokens: prompt, outputTokens: output, firstTokenSeconds: 0.5,
                                decodeTokensPerSecond: 40, finishedAt: 1))
        }
        let plain = try ClusterPlacementFlow.decide(description: description, capability: capability, localMemberID: "mac-one",
            localProfile: slowTwo[0].profile, peerProfile: slowTwo[1].profile, layout: layout, environment: [:], benchDebugBuild: true)
        let mixed = try ClusterPlacementFlow.decide(description: description, capability: capability, localMemberID: "mac-one",
            localProfile: slowTwo[0].profile, peerProfile: slowTwo[1].profile, layout: layout,
            served: [entry(64, 100), entry(128, 120), entry(96, 110)], environment: [:], benchDebugBuild: true)
        require("request mix: unserved, the model's planned request stands",
            plain.result.promptTokens == layout.maximumPromptTokens && plain.result.outputTokens == layout.maximumOutputTokens)
        require("request mix: the pair's served requests (median 96-token prompt, 110-token answer) are the request the plan is made for",
            mixed.result.promptTokens == 96 && mixed.result.outputTokens == min(110, layout.maximumOutputTokens))
        require("the plan says in one line why it is tensor parallel or a pipeline",
            plain.lines.contains("Tensor parallel or pipeline")
                && plain.lines.contains { $0.hasPrefix("  Pipeline: ") || $0.hasPrefix("  Tensor parallel: ") })
    }

    /// The universal rule of qualification records (`ClusterPairQualificationRecords`, chip-agnostic since
    /// 2026-10-14): on a chip combination with a failed cross-cable check a model is planned and started only at
    /// shapes a check passed in; other combinations are not restricted, except that a rank that ran a diverged
    /// shape refuses that exact shape. Synthetic records of two to four ranks on several chips; then the registered
    /// GPT-OSS records through the guided step's own decision, on an M3 Ultra with an M5 Ultra (passed at cut 12,
    /// diverged at cut 4) and with a chip no check ran.
    static func qualifiedShapes(description base: [String: Any], slowTwo: [ClusterPlacementDevice]) throws {
        let m3 = ClusterChipClass(chipName: "Apple M3 Ultra")!, m5u = ClusterChipClass(chipName: "Apple M5 Ultra")!, m5 = ClusterChipClass(chipName: "Apple M5 Max")!
        let m2 = ClusterChipClass(chipName: "Apple M2 Max")!, m4 = ClusterChipClass(chipName: "Apple M4 Pro")!
        let open = ClusterPairQualificationRecords(runtimeModelID: "x",
            passed: [.init(chipClasses: [m3, m5], cuts: [16], mode: .pipeline)], failed: [])
        require("records: with no failed check no shape is restricted", !open.restrictsShapes
            && open.admits(chipClasses: [m2, m4], cuts: [3], mode: .phaseSplit)
            && open.admitsRank(0, of: 3, chipClass: m2, cuts: [1, 2], mode: .pipeline))
        let three = ClusterPairQualificationRecords(runtimeModelID: "x",
            passed: [.init(chipClasses: [m2, m4, m5u], cuts: [8, 20], mode: .pipeline),
                     .init(chipClasses: [m2, m2], cuts: [12], mode: .pipelineCompactDecode)],
            failed: [.init(chipClasses: [m2, m4, m5u], cuts: [10, 20], mode: .pipeline)])
        require("records: one failed check names its chip combination", three.restrictsShapes
            && three.restrictsCombination([m5u, m2, m4], family: .pipeline) && !three.restrictsCombination([m2, m2, m5u], family: .pipeline))
        require("records: a passed shape of three ranks is admitted whole", three.admits(chipClasses: [m2, m4, m5u], cuts: [8, 20], mode: .pipeline))
        // Owner, 2026-10-14 08:45: on the combination that diverged only the shape that diverged is refused; any
        // other cut, mode of another family or order is admitted, passed or not.
        require("records: the shape that diverged is refused, in either mode of its family",
            !three.admits(chipClasses: [m2, m4, m5u], cuts: [10, 20], mode: .pipeline)
                && !three.admits(chipClasses: [m2, m4, m5u], cuts: [10, 20], mode: .pipelineCompactDecode)
                && !three.admits(chipClasses: [m2, nil, m5u], cuts: [10, 20], mode: .pipeline))
        require("records: every other shape of the same chips is admitted",
            three.admits(chipClasses: [m2, m4, m5u], cuts: [8, 20], mode: .pipelineCompactDecode)
                && three.admits(chipClasses: [m5u, m4, m2], cuts: [8, 20], mode: .pipeline)
                && three.admits(chipClasses: [m2, m4, m5u], cuts: [12, 20], mode: .pipeline)
                && three.admits(chipClasses: [m2, nil, m5u], cuts: [8, 20], mode: .pipeline))
        // Mode-bound (O9): a failed pipeline check restricts the pipeline family's shapes; another family is
        // restricted by its own records and its grant, not by these.
        require("records: a failed check restricts its own mode family only", three.restrictedFamilies == [.pipeline]
            && three.admits(chipClasses: [m2, m4, m5u], cuts: [8, 20], mode: .phaseSplit))
        require("records: each rank refuses only the rank-shape that diverged with its own class",
            three.admitsRank(1, of: 3, chipClass: m4, cuts: [8, 20], mode: .pipeline)
                && !three.admitsRank(1, of: 3, chipClass: m4, cuts: [10, 20], mode: .pipelineCompactDecode)
                && three.admitsRank(1, of: 3, chipClass: m2, cuts: [10, 20], mode: .pipeline)
                && three.admitsRank(1, of: 2, chipClass: m4, cuts: [10, 20], mode: .pipeline)
                && three.admitsRank(1, of: 2, chipClass: m2, cuts: [12], mode: .pipelineCompactDecode))
        // A Mac checks its rank with only its own class at start, so a rank whose class ran a diverged rank-shape
        // refuses that rank-shape with any partner; the planner and the offer apply the same half and pick another cut.
        require("records: another chip combination is not restricted, except at a rank-shape its own class diverged at",
            three.admits(chipClasses: [m4, m2, m2], cuts: [10, 20], mode: .pipeline)
                && three.admits(chipClasses: [m5, m5, m5], cuts: [3, 7], mode: .pipeline)
                && !three.admits(chipClasses: [m2, m2, m4], cuts: [10, 20], mode: .pipeline))
        let four = ClusterPairQualificationRecords(runtimeModelID: "x", passed: [], failed: [.init(chipClasses: [m4, m4, m4, m4], cuts: [6, 12, 18], mode: .pipeline)])
        require("records: a model whose every check failed refuses the shapes that failed only", four.restrictsShapes
            && !four.admits(chipClasses: [m4, m4, m4, m4], cuts: [6, 12, 18], mode: .pipeline) && four.passedShapesText == "none"
            && four.admits(chipClasses: [m4, m4, m4, m4], cuts: [5, 12, 18], mode: .pipeline))

        // The registered records: GPT-OSS diverged at cuts 4, 8 and 10 with the M3 Ultra leading the M5 Ultra and passed at 11, 12, 16.
        let gpt = ClusterPairServingGrants.records(runtimeModelID: "registered_gpt_oss_20b")
        require("GPT-OSS: its failed checks refuse exactly the shapes that diverged", gpt.restrictsShapes
            && gpt.admits(chipClasses: [m3, m5u], cuts: [12], mode: .pipeline)
            && gpt.admits(chipClasses: [m3, m5u], cuts: [11], mode: .pipeline)
            && gpt.admits(chipClasses: [m3, m5u], cuts: [6], mode: .pipeline)
            && !gpt.admits(chipClasses: [m3, m5u], cuts: [10], mode: .pipeline)
            && !gpt.admits(chipClasses: [m3, m5u], cuts: [10], mode: .pipelineCompactDecode)
            && gpt.admits(chipClasses: [m3, m5u], cuts: [12], mode: .pipelineCompactDecode)
            && !gpt.admits(chipClasses: [m3, m5u], cuts: [4], mode: .pipeline)
            && gpt.admits(chipClasses: [m5u, m3], cuts: [12], mode: .pipeline))
        require("a model with no failed check is not restricted by shape",
            !ClusterPairServingGrants.records(runtimeModelID: "registered_qwen38_27b").restrictsShapes)
        try ClusterPairServingGrants.requirePlacement([m3, m5], runtimeModelID: "registered_qwen38_27b", publicModelID: "p", cuts: [16], mode: .pipeline)

        // The guided step on a 24-layer model registered as GPT-OSS, every cut admitted.
        var part = ClusterModelLayout.Part(storedBytes: gib / 2, loadedBytes: gib / 2, largestTensorBytes: gib / 8, tensorCount: 32)
        part.requestWorkBytes = 0
        let cuts = Array(1..<24)
        let layout = ClusterModelLayout(runtimeModelID: "registered_gpt_oss_20b", artifactSHA256: hash("b"), configurationSHA256: hash("c"),
            layers: (0..<24).map { .init(index: $0, kind: $0 % 2 == 0 ? "sliding_attention" : "full_attention", weights: part,
                stateFixedBytes: 2_621_440, stateBytesPerToken: $0 % 2 == 0 ? 0 : 4096, cost: 1) },
            ingress: .init(storedBytes: gib / 2, loadedBytes: gib / 2, largestTensorBytes: gib / 2, tensorCount: 3),
            egress: .init(storedBytes: gib / 2, loadedBytes: gib / 2, largestTensorBytes: gib / 2, tensorCount: 4),
            excluded: .init(), admittedCuts: cuts, structuralCuts: cuts,
            generationModes: [.pipeline, .pipelineCompactDecode], prefillSchedules: [.serial, .oneChunkLookahead],
            maximumPromptTokens: 8192, maximumOutputTokens: 128, maximumChunkTokens: 512, boundaryBytesPerToken: 11520,
            requestChargeEveryRankBytes: 0)
        let capability = try ClusterRuntimeCapability(runtimeBinarySHA256: hash("a"), adapterID: "gpt-oss-layer-stage", adapterVersion: 1,
            runtimeModelID: "registered_gpt_oss_20b", artifactSHA256: hash("b"), configurationSHA256: hash("c"), manifestSHA256: hash("d"),
            profile: .init(id: "registered_gpt_oss_20b_greedy_generation_v1", vocabularySize: 201088, maximumPromptTokens: 8192,
                maximumOutputTokens: 128, maximumChunkTokens: 512, maximumContextTokens: 8320),
            profileFingerprint: hash("e"), partitions: cuts.map { cut in
                .init(planSHA256: String(repeating: "7", count: 62) + String(format: "%02d", cut), stages: [
                    .init(rank: 0, sourceLayerStart: 0, sourceLayerEnd: cut, stagePlanSHA256: String(repeating: "1", count: 62) + String(format: "%02d", cut),
                          constructionConfigurationSHA256: hash("2")),
                    .init(rank: 1, sourceLayerStart: cut, sourceLayerEnd: 24, stagePlanSHA256: String(repeating: "3", count: 62) + String(format: "%02d", cut),
                          constructionConfigurationSHA256: hash("4"))]) },
            arithmeticPolicyID: "gpt_oss_ordinary_cache_split_experts_bf16_defaults_v1", arithmeticPolicySHA256: hash("5"),
            supportedPrefillSchedules: [.serial, .oneChunkLookahead], supportedGenerationModes: [.pipeline, .pipelineCompactDecode])
        var object = base
        object["capabilitySHA256"] = ClusterConfigurationCodec.sha256(try ClusterRuntimeCapabilityCodec.encode(capability))
        object["publicModelID"] = "fixture/gpt-oss"
        let description = try ClusterPairDescription.decode(JSONSerialization.data(withJSONObject: object))
        // Each profile carries the model-free device index the two Macs measured (2026-10-12): the M5 Ultra 5.0x the
        // M3 Ultra's prefill and 1.8x its decode, which alone puts the cut at 4.
        func profile(_ device: ClusterPlacementDevice, _ name: String, index: (Double, Double)? = nil) throws -> ClusterDeviceProfile {
            let p = device.profile
            var value = try ClusterDeviceProfile(chip: name, performanceCores: p.performanceCores, efficiencyCores: p.efficiencyCores, gpuCores: p.gpuCores,
                osVersion: p.osVersion, osBuild: p.osBuild, physicalMemoryBytes: p.physicalMemoryBytes,
                gpuRecommendedWorkingSetBytes: p.gpuRecommendedWorkingSetBytes, gpuMaximumBufferBytes: p.gpuMaximumBufferBytes,
                allocatorLimitBytes: p.allocatorLimitBytes, memory: p.memory, power: p.power)
            value.speedIndex = index.map { ClusterDeviceIndex(chip: name, osBuild: p.osBuild, benchmark: "qmm_h4096_b4_g64_x16_v1",
                prefillIndex: $0.0, decodeIndex: $0.1) }
            return value
        }
        let ultra3 = try profile(slowTwo[0], "Apple M3 Ultra", index: (469_577, 25_949))
        let ultra5 = try profile(slowTwo[1], "Apple M5 Ultra", index: (2_334_000, 45_290))
        let speeds = ClusterSpeedEstimator.estimate(devices: [ultra3, ultra5].map { .init(chip: $0.chip, osBuild: $0.osBuild) },
            artifactSHA256: layout.artifactSHA256, promptTokens: layout.maximumPromptTokens, measurements: [],
            indices: [ultra3, ultra5].compactMap(\.speedIndex))
        var free = ClusterPlacementPolicy(); free.leader = "mac-one"
        let ungated = try ClusterPlacementPlanner.plan(devices: [.init(label: "mac-one", profile: ultra3, speed: speeds[0]),
            .init(label: "mac-two", profile: ultra5, speed: speeds[1])], layout: layout, policy: free)
        require("GPT-OSS on the two Ultras: speed alone would cut where its check diverged",
            (ungated.chosen?.cut ?? 99) <= 10)
        let decided = try ClusterPlacementFlow.decide(description: description, capability: capability, localMemberID: "mac-one",
            localProfile: ultra3, peerProfile: ultra5, layout: layout, leader: "mac-one")
        // Diverged at cuts 4, 8 and 10 (owner, 2026-10-14 08:45): those shapes are steered away from and the planner picks
        // the fastest other placement, passed or never checked.
        let steered = decided.result.chosen.map { candidate in
            !(candidate.ranks.map(\.device) == ["mac-one", "mac-two"] && [4, 8, 10].contains(candidate.cut)) } ?? false
        require("GPT-OSS on an M3 Ultra and an M5 Ultra is steered to a placement that did not diverge, and planned",
            steered && decided.setup != nil && (decided.result.unqualifiedPossible ?? 0) > 0
                && decided.result.alternatives.allSatisfy { !($0.ranks.map(\.device) == ["mac-one", "mac-two"] && [4, 8, 10].contains($0.cut)) })
        require("the plan says why, with the diverged placements, and states public traffic",
            decided.lines.contains("Diverged placements")
                && decided.lines.contains { $0.contains("apple_m3_ultra then apple_m5_ultra at cut 4 (pipeline_v1)") }
                && decided.lines.contains("Public traffic"))
        // The developer bench chip on Macs that carry their measured device index (every Mac after its first probe):
        // the profiles renamed for planning must still validate (hardware 2026-10-14, round 6d: "Device profile carries
        // another Mac's speed index" refused every model the pair already held).
        let renamed = try? ultra3.renamedForBench(chip: "Apple M4 Max")
        require("bench chip: a renamed profile keeps its measured index, under the bench chip's name",
            renamed?.chip == "Apple M4 Max" && renamed?.speedIndex?.chip == "Apple M4 Max"
                && renamed?.speedIndex?.osBuild == ultra3.osBuild && renamed?.speedIndex?.benchmark == ultra3.speedIndex?.benchmark
                && renamed?.speedIndex?.prefillIndex == ultra3.speedIndex?.prefillIndex
                && renamed?.speedIndex?.decodeIndex == ultra3.speedIndex?.decodeIndex)
        let benchIndexed = try? ClusterPlacementFlow.decide(description: description, capability: capability, localMemberID: "mac-one",
            localProfile: ultra3, peerProfile: ultra5, layout: layout, environment: [ClusterBenchChip.environmentName: "Apple M4 Max"],
            benchDebugBuild: true)
        require("bench chip: two Macs that carry measured indices are planned as that chip",
            benchIndexed?.result.chosen != nil && benchIndexed?.lines.contains { $0.contains("Developer bench chip") } == true)
        let elsewhere = try ClusterPlacementFlow.decide(description: description, capability: capability, localMemberID: "mac-one",
            localProfile: ultra3, peerProfile: try profile(slowTwo[1], "Apple M4 Pro"), layout: layout, leader: "mac-one")
        require("GPT-OSS on a chip combination no check ran is planned by speed, never at a rank-shape the M3 Ultra diverged at",
            elsewhere.result.chosen.map { ![4, 8, 10].contains($0.cut) } == true && elsewhere.setup != nil
                && elsewhere.lines.contains { $0.contains("every other placement is, on any Macs") })
        let m4max = try profile(slowTwo[0], "Apple M4 Max"), m4maxPeer = try profile(slowTwo[1], "Apple M4 Max")
        let twoMax = try ClusterPlacementFlow.decide(description: description, capability: capability, localMemberID: "mac-one",
            localProfile: m4max, peerProfile: m4maxPeer, layout: layout)
        require("GPT-OSS on two M4 Max Macs is planned at the planner's own cut", twoMax.result.chosen != nil && twoMax.setup != nil)
    }

    /// The owner's flow on two Macs nobody qualified (owner, 2026-10-14 08:45: detect -> pick a model -> memory
    /// check -> the planner picks tensor parallel or pipeline), on synthetic 2x M4 Max of 64 GB and 128 GB: a model with
    /// no qualification record is planned, set up and says it is not yet qualified for public traffic; a model the two
    /// Macs cannot hold together is refused with the memory reason, never a qualification one.
    static func ownerPilot(description base: [String: Any]) throws {
        func model(_ id: String, adapter: String, policy: String, layers: Int, layerGiB: Double) throws
            -> (ClusterModelLayout, ClusterRuntimeCapability, ClusterPairDescription) {
            let bytes = Int(layerGiB * Double(gib))
            var part = ClusterModelLayout.Part(storedBytes: bytes, loadedBytes: bytes, largestTensorBytes: bytes / 8, tensorCount: 32)
            part.requestWorkBytes = 0
            let cuts = Array(1..<layers)
            let layout = ClusterModelLayout(runtimeModelID: id, artifactSHA256: hash("b"), configurationSHA256: hash("c"),
                layers: (0..<layers).map { .init(index: $0, kind: "block", weights: part, stateFixedBytes: 2_621_440, stateBytesPerToken: 4096, cost: 1) },
                ingress: .init(storedBytes: gib / 2, loadedBytes: gib / 2, largestTensorBytes: gib / 2, tensorCount: 3),
                egress: .init(storedBytes: gib / 2, loadedBytes: gib / 2, largestTensorBytes: gib / 2, tensorCount: 4),
                excluded: .init(), admittedCuts: cuts, structuralCuts: cuts,
                generationModes: [.pipeline, .pipelineCompactDecode], prefillSchedules: [.serial, .oneChunkLookahead],
                maximumPromptTokens: 8192, maximumOutputTokens: 128, maximumChunkTokens: 512, boundaryBytesPerToken: 11520,
                requestChargeEveryRankBytes: 0)
            let capability = try ClusterRuntimeCapability(runtimeBinarySHA256: hash("a"), adapterID: adapter, adapterVersion: 1,
                runtimeModelID: id, artifactSHA256: hash("b"), configurationSHA256: hash("c"), manifestSHA256: hash("d"),
                profile: .init(id: id + "_greedy_generation_v1", vocabularySize: 262_144, maximumPromptTokens: 8192,
                    maximumOutputTokens: 128, maximumChunkTokens: 512, maximumContextTokens: 8320),
                profileFingerprint: hash("e"), partitions: cuts.map { cut in
                    .init(planSHA256: String(repeating: "7", count: 62) + String(format: "%02d", cut), stages: [
                        .init(rank: 0, sourceLayerStart: 0, sourceLayerEnd: cut, stagePlanSHA256: String(repeating: "1", count: 62) + String(format: "%02d", cut),
                              constructionConfigurationSHA256: hash("2")),
                        .init(rank: 1, sourceLayerStart: cut, sourceLayerEnd: layers, stagePlanSHA256: String(repeating: "3", count: 62) + String(format: "%02d", cut),
                              constructionConfigurationSHA256: hash("4"))]) },
                arithmeticPolicyID: policy, arithmeticPolicySHA256: hash("5"),
                supportedPrefillSchedules: [.serial, .oneChunkLookahead], supportedGenerationModes: [.pipeline, .pipelineCompactDecode])
            var object = base
            object["capabilitySHA256"] = ClusterConfigurationCodec.sha256(try ClusterRuntimeCapabilityCodec.encode(capability))
            object["publicModelID"] = "fixture/" + id
            return (layout, capability, try ClusterPairDescription.decode(JSONSerialization.data(withJSONObject: object)))
        }
        func m4Max(_ label: String, _ physical: Int, free: Int) throws -> ClusterDeviceProfile {
            let p = try device(label, physicalGiB: physical, freeGiB: free, prefill: 1200, decode: 45).profile
            return try .init(chip: "Apple M4 Max", performanceCores: p.performanceCores, efficiencyCores: p.efficiencyCores, gpuCores: p.gpuCores,
                osVersion: p.osVersion, osBuild: p.osBuild, physicalMemoryBytes: p.physicalMemoryBytes,
                gpuRecommendedWorkingSetBytes: p.gpuRecommendedWorkingSetBytes, gpuMaximumBufferBytes: p.gpuMaximumBufferBytes,
                allocatorLimitBytes: p.allocatorLimitBytes, memory: p.memory, power: p.power)
        }
        let pairs = [("2x M4 Max 64 GB", try m4Max("mac-one", 64, free: 52), try m4Max("mac-two", 64, free: 52)),
                     ("2x M4 Max 128 GB", try m4Max("mac-one", 128, free: 116), try m4Max("mac-two", 128, free: 116))]
        // Gemma 4 26B (bf16 entry): a stage adapter runs it, and no qualification record of it is shipped.
        require("owner pilot: the unqualified model has no record and no public grant",
            ClusterPairServingGrants.records.allSatisfy { $0.runtimeModelID != "registered_gemma4_26b" }
                && (try? ClusterPairServingGrants.grant(runtimeModelID: "registered_gemma4_26b", publicModelID: "p")) == nil)
        let (small, smallCapability, smallDescription) = try model("registered_gemma4_26b", adapter: "gemma4-layer-stage",
            policy: "gemma4_cbv2_query128_bf16_tf32_weighted_r1_v1", layers: 30, layerGiB: 1.6)
        for (name, local, peer) in pairs {
            let decided = try ClusterPlacementFlow.decide(description: smallDescription, capability: smallCapability, localMemberID: "mac-one",
                localProfile: local, peerProfile: peer, layout: small)
            require("owner pilot: \(name) plans and sets up a model with no qualification record",
                decided.result.chosen != nil && decided.setup != nil && (decided.result.unqualifiedPossible ?? 0) == 0
                    && !decided.lines.contains("Pair serving"))
            require("owner pilot: \(name) says in one line it is not yet qualified for public traffic",
                decided.lines.contains("Public traffic") && decided.lines.contains("  Not yet qualified for public traffic."))
        }
        // A model the two 64 GB Macs cannot hold together (about 194 GiB): refused for memory, in the planner's words;
        // the same model on two 128 GB Macs is planned.
        let (big, bigCapability, bigDescription) = try model("registered_gemma4_26b", adapter: "gemma4-layer-stage",
            policy: "gemma4_cbv2_query128_bf16_tf32_weighted_r1_v1", layers: 30, layerGiB: 6.4)
        let tooBig = try ClusterPlacementFlow.decide(description: bigDescription, capability: bigCapability, localMemberID: "mac-one",
            localProfile: pairs[0].1, peerProfile: pairs[0].2, layout: big)
        require("owner pilot: a model too big for 2x M4 Max 64 GB is refused with the memory reason",
            tooBig.result.chosen == nil && tooBig.setup == nil && tooBig.result.refusal != nil && (tooBig.result.unqualifiedPossible ?? 0) == 0
                && tooBig.lines.contains("Refused: no division of this model between these Macs is possible, and no Mac holds it alone")
                && !tooBig.lines.contains { $0.contains("diverged in a cross-cable check on these chips") })
        let fits = try ClusterPlacementFlow.decide(description: bigDescription, capability: bigCapability, localMemberID: "mac-one",
            localProfile: pairs[1].1, peerProfile: pairs[1].2, layout: big)
        require("owner pilot: the same model on 2x M4 Max 128 GB is planned", fits.result.chosen != nil && fits.setup != nil)
    }

    static func main() throws {
        if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "flow" {
            do { try flow(Array(CommandLine.arguments.dropFirst(2))) } catch {
                FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1)
            }
            return
        }
        // The synthetic capabilities below carry the artifact hash("b"): in this check build it stands for each
        // registered model's own recorded artifact (a pair-serving grant rests on records of the installed artifact).
        let synthetic = hash("b")
        for record in ClusterPairServingGrants.records {
            let key = ClusterPairServingGrants.fixtureKey(synthetic, record.runtimeModelID)
            ClusterPairServingGrants.fixtureArtifacts.withLock {
                if $0[key] == nil { $0[key] = record.artifactSHA256 }
            }
        }
        // A 32-layer model of 5 GiB with the 9B's four admitted cuts.
        var part = ClusterModelLayout.Part(storedBytes: gib / 8, loadedBytes: gib / 8, largestTensorBytes: gib / 16, tensorCount: 30)
        part.requestWorkBytes = 0
        let layout = ClusterModelLayout(runtimeModelID: "registered_qwen35_9b", artifactSHA256: hash("b"), configurationSHA256: hash("c"),
            layers: (0..<32).map { .init(index: $0, kind: "block", weights: part, stateFixedBytes: 1_000_000, stateBytesPerToken: 1024, cost: 1) },
            ingress: .init(storedBytes: gib / 2, loadedBytes: gib / 2, largestTensorBytes: gib / 2, tensorCount: 3),
            egress: .init(storedBytes: gib / 2, loadedBytes: gib / 2, largestTensorBytes: gib / 2, tensorCount: 3),
            excluded: .init(), admittedCuts: [4, 8, 12, 16], structuralCuts: [4, 8, 12, 16, 20, 24, 28],
            generationModes: ClusterGenerationMode.allCases, prefillSchedules: [.serial, .oneChunkLookahead],
            maximumPromptTokens: 8192, maximumOutputTokens: 128, maximumChunkTokens: 512, boundaryBytesPerToken: 8192,
            requestChargeEveryRankBytes: 700_000_000)
        func partition(_ cut: Int, _ id: Character) -> ClusterRuntimePartition {
            .init(planSHA256: hash(id), stages: [
                .init(rank: 0, sourceLayerStart: 0, sourceLayerEnd: cut, stagePlanSHA256: String(repeating: "1", count: 62) + String(format: "%02d", cut),
                      constructionConfigurationSHA256: hash("2")),
                .init(rank: 1, sourceLayerStart: cut, sourceLayerEnd: 32, stagePlanSHA256: String(repeating: "3", count: 62) + String(format: "%02d", cut),
                      constructionConfigurationSHA256: hash("4"))])
        }
        let capability = try ClusterRuntimeCapability(runtimeBinarySHA256: hash("a"), adapterID: "qwen35-dense-layer-stage", adapterVersion: 1,
            runtimeModelID: "registered_qwen35_9b", artifactSHA256: hash("b"), configurationSHA256: hash("c"), manifestSHA256: hash("d"),
            profile: .init(id: "registered_qwen35_9b_greedy_generation_v1", vocabularySize: 248320, maximumPromptTokens: 8192,
                maximumOutputTokens: 128, maximumChunkTokens: 512, maximumContextTokens: 8320),
            profileFingerprint: hash("e"), partitions: [partition(4, "6"), partition(8, "7"), partition(12, "8"), partition(16, "9")],
            arithmeticPolicyID: "qwen_cbv2_query128_bf16_tf32_default_v1", arithmeticPolicySHA256: hash("5"), supportedPrefillSchedules: [.serial, .oneChunkLookahead], supportedGenerationModes: ClusterGenerationMode.allCases)
        let capabilityHash = ClusterConfigurationCodec.sha256(try ClusterRuntimeCapabilityCodec.encode(capability))
        func member(_ id: String, _ address: String, _ device: String) -> [String: Any] {
            ["id": id, "host": id + ".local", "port": 22, "user": "fixture", "ownerExecutable": "/Users/fixture/bin/darkbloom",
             "workerExecutable": "/Users/fixture/bin/darkbloom-cluster-worker", "modelDirectory": "/Users/fixture/model",
             "runtimeBinarySHA256": hash("a"), "jacclDevice": device, "linkAddress": address,
             "trust": ["identityFile": "/Users/fixture/.ssh/\(id)", "knownHostsFile": "/Users/fixture/.ssh/\(id).hosts", "knownHostsSHA256": hash("f")]]
        }
        let descriptionObject: [String: Any] = ["schema": ClusterPairDescription.schemaName, "clusterID": "fixture", "publicModelID": "fixture/qwen",
            "capabilitySHA256": capabilityHash, "chunkTokens": 512, "requestTimeoutSeconds": 300, "coordinatorPort": 12345,
            "members": [member("mac-one", "192.0.2.1", "rdma_en1"), member("mac-two", "192.0.2.2", "rdma_en2")],
            "tokenizerFiles": [["path": "tokenizer.json", "sha256": hash("6"), "purpose": "tokenizer"]]]
        let description = try ClusterPairDescription.decode(JSONSerialization.data(withJSONObject: descriptionObject))

        func setup(_ devices: [ClusterPlacementDevice], modes: [ClusterGenerationMode]? = [.pipeline]) throws -> (ClusterPlacementSetup, ClusterPlacementCandidate) {
            // A phase split named here is planned under the hand-off opt-in (off by default).
            var policy = ClusterPlacementPolicy(); policy.modes = modes; policy.handOffModes = modes?.contains { $0.isHandOff } ?? false
            guard let chosen = try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: policy).chosen else {
                throw ClusterConfigurationError.invalid("check: no placement")
            }
            return (try ClusterPlacementSetup.synthesize(description: description, capability: capability, chosen: chosen), chosen)
        }
        func decoded(_ setup: ClusterPlacementSetup, _ id: String) throws -> ClusterConfiguration {
            try ClusterConfigurationCodec.decode(setup.configurations[id]!, capability: capability, capabilitySHA256: capabilityHash)
        }

        // mac-two is the slower at prefill, so it takes the first and smaller range and leads.
        let slowTwo = [try device("mac-one", physicalGiB: 128, freeGiB: 100, prefill: 2700, decode: 80),
                       try device("mac-two", physicalGiB: 256, freeGiB: 200, prefill: 1000, decode: 62)]
        let (first, chosen) = try setup(slowTwo)
        let one = try decoded(first, "mac-one"), two = try decoded(first, "mac-two")
        require("the slower Mac at prefill holds the first range and leads", first.leaderID == "mac-two" && two.role == .leader && one.role == .follower)
        require("both setups name the peers in rank order, the leader first", one.peers == two.peers && one.peers.map(\.id) == ["mac-two", "mac-one"]
            && one.peers.map(\.rank) == [0, 1])
        require("the ranks meet on the leader's link address in both setups", one.coordinator.address == "192.0.2.2" && two.coordinator == one.coordinator)
        require("both setups pin the Plan the worker's record lists for the chosen cut",
            one.selectedPlanSHA256 == two.selectedPlanSHA256 && one.selectedPlanSHA256 == first.planSHA256
                && capability.partitions.first { $0.planSHA256 == first.planSHA256 }?.stages[0].sourceLayerEnd == chosen.cut)
        require("each setup carries its own member's trust files", one.trust?.identityFile.hasSuffix("mac-one") == true && two.trust?.identityFile.hasSuffix("mac-two") == true)
        require("the chosen schedule is saved explicitly and the pipeline keeps its omitted spelling",
            one.prefillSchedule == chosen.prefillSchedule && one.generationMode == nil)
        // The same setup, typed by hand, is the same bytes.
        var typed = try JSONSerialization.jsonObject(with: first.configurations["mac-two"]!) as! [String: Any]
        typed["role"] = "leader"
        let retyped = try ClusterConfigurationCodec.encode(try ClusterConfigurationCodec.decode(JSONSerialization.data(withJSONObject: typed),
            capability: capability, capabilitySHA256: capabilityHash), capability: capability, capabilitySHA256: capabilityHash)
        require("a synthesized setup is byte for byte what the strict codec writes for the same choices", retyped == first.configurations["mac-two"]!)

        // Which Mac asks does not matter, and either Mac can end up leading.
        let (reversed, _) = try setup(slowTwo.reversed())
        require("the setups do not depend on which Mac was named first", reversed == first)
        let slowOne = [try device("mac-one", physicalGiB: 128, freeGiB: 100, prefill: 1000, decode: 62),
                       try device("mac-two", physicalGiB: 256, freeGiB: 200, prefill: 2700, decode: 80)]
        let (flipped, _) = try setup(slowOne)
        let flippedOne = try decoded(flipped, "mac-one")
        require("with the speeds exchanged the other Mac leads", flipped.leaderID == "mac-one"
            && flippedOne.role == .leader && flippedOne.coordinator.address == "192.0.2.1")
        require("the narration says where the session is started from, for either Mac",
            flipped.narration(localMemberID: "mac-one")[1].contains("started from this Mac")
                && flipped.narration(localMemberID: "mac-two")[1].contains("started from that Mac"))

        // Memory decides before speed: a Mac that admits little takes the small range whatever its speed.
        let tight = [try device("mac-one", physicalGiB: 16, freeGiB: 9, prefill: 2700, decode: 80),
                     try device("mac-two", physicalGiB: 256, freeGiB: 200, prefill: 1000, decode: 62)]
        let (small, smallChosen) = try setup(tight)
        require("a Mac that admits 9 GiB takes a range it can hold, and the setup follows the placement",
            smallChosen.ranks.allSatisfy { $0.fit == .now } && small.configurations.count == 2
                && smallChosen.ranks.first { $0.device == "mac-one" }!.needBytes <= 9 * gib)

        // A phase split is saved by name.
        let (split, splitChosen) = try setup(slowTwo, modes: [.phaseSplit])
        let splitOne = try decoded(split, "mac-one"), splitTwo = try decoded(split, "mac-two")
        require("a phase split is saved by name in both setups", splitChosen.mode == .phaseSplit
            && splitOne.generationMode == .phaseSplit && splitTwo.generationMode == .phaseSplit)
        try speculativeHeadByDefault(layout: layout, description: description, capability: capability,
            capabilityHash: capabilityHash, slowTwo: slowTwo)
        try qualifiedShapes(description: descriptionObject, slowTwo: slowTwo)
        try ownerPilot(description: descriptionObject)
        try benchCap(layout: layout, description: description, capability: capability, slowTwo: slowTwo)
        try forcedMode(layout: layout, description: description, capability: capability, slowTwo: slowTwo)
        try requestMix(layout: layout, description: description, capability: capability, slowTwo: slowTwo)

        // A cut the record does not describe is refused, in words.
        let elsewhere = try ClusterPlacementPlanner.evaluate(devices: slowTwo.reversed(), cuts: [20], mode: .pipeline,
            prefillSchedule: .oneChunkLookahead, layout: layout)
        refuses("a cut the worker's record does not describe is refused", because: "describes cuts 4, 8, 12, 16 only") {
            _ = try ClusterPlacementSetup.synthesize(description: description, capability: capability, chosen: elsewhere)
        }
        refuses("a placement naming a device the description does not is refused", because: "the pair description does not") {
            let strangers = [try device("mac-one", physicalGiB: 128, freeGiB: 100, prefill: 1000, decode: 62),
                             try device("mac-three", physicalGiB: 256, freeGiB: 200, prefill: 2700, decode: 80)]
            _ = try setup(strangers)
        }
        refuses("a description with one member is refused", because: "exactly two distinct members") {
            var object = descriptionObject; object["members"] = [member("mac-one", "192.0.2.1", "rdma_en1")]
            _ = try ClusterPairDescription.decode(JSONSerialization.data(withJSONObject: object))
        }
        // The whole decision of the guided step, with what was detected already in hand.
        let decided = try ClusterPlacementFlow.decide(description: description, capability: capability, localMemberID: "mac-one",
            localProfile: slowTwo[0].profile, peerProfile: slowTwo[1].profile, layout: layout)
        require("the guided step plans, writes both setups and says in plain words what happens next",
            decided.setup?.configurations.count == 2 && decided.lines.contains("What happens next")
                && decided.lines.contains { $0.contains("This is a plan, not an admission") }
                && decided.lines.contains { $0.contains("Speed did not inform this split") })
        require("run on the other Mac, the same step reaches the same setups and names the same leader",
            try ClusterPlacementFlow.decide(description: description, capability: capability, localMemberID: "mac-two",
                localProfile: slowTwo[1].profile, peerProfile: slowTwo[0].profile, layout: layout).setup == decided.setup)
        refuses("a layout of another model than the record's is refused", because: "describe different models") {
            let other = ClusterModelLayout(runtimeModelID: "registered_qwen38_27b", artifactSHA256: layout.artifactSHA256,
                configurationSHA256: layout.configurationSHA256, layers: layout.layers, ingress: layout.ingress, egress: layout.egress,
                excluded: layout.excluded, admittedCuts: layout.admittedCuts, structuralCuts: layout.structuralCuts,
                generationModes: layout.generationModes, prefillSchedules: layout.prefillSchedules, maximumPromptTokens: 8192,
                maximumOutputTokens: 128, maximumChunkTokens: 512, boundaryBytesPerToken: 8192, requestChargeEveryRankBytes: 0)
            _ = try ClusterPlacementFlow.decide(description: description, capability: capability, localMemberID: "mac-one",
                localProfile: slowTwo[0].profile, peerProfile: slowTwo[1].profile, layout: other)
        }
        refuses("a member ID the description does not hold is refused", because: "is not in the pair description") {
            _ = try ClusterPlacementFlow.decide(description: description, capability: capability, localMemberID: "mac-nine",
                localProfile: slowTwo[0].profile, peerProfile: slowTwo[1].profile, layout: layout)
        }
        // The model's pair-serving grant (owner decision D4) at plan time. The 9B is granted with the M3 Ultra
        // leading and the M5 Max decoding: on those two chips the planner is held to that order, whichever Mac
        // asks and whatever the speeds prefer; asked for the other order, the step refuses as a start would.
        func chip(_ device: ClusterPlacementDevice, _ name: String) throws -> ClusterDeviceProfile {
            let p = device.profile
            return try .init(chip: name, performanceCores: p.performanceCores, efficiencyCores: p.efficiencyCores, gpuCores: p.gpuCores,
                osVersion: p.osVersion, osBuild: p.osBuild, physicalMemoryBytes: p.physicalMemoryBytes,
                gpuRecommendedWorkingSetBytes: p.gpuRecommendedWorkingSetBytes, gpuMaximumBufferBytes: p.gpuMaximumBufferBytes,
                allocatorLimitBytes: p.allocatorLimitBytes, memory: p.memory, power: p.power)
        }
        let m3 = try chip(slowTwo[0], "Apple M3 Ultra"), m5 = try chip(slowTwo[1], "Apple M5 Max")
        for (who, local, peer) in [("mac-one", m3, m5), ("mac-two", m5, m3)] {
            let held = try ClusterPlacementFlow.decide(description: description, capability: capability, localMemberID: who,
                localProfile: local, peerProfile: peer, layout: layout)
            require("the 9B on an M3 Ultra and an M5 Max is planned with no refusal note, asked from \(who)",
                held.setup != nil && !held.lines.contains("Pair serving"))
        }
        require("an order asked for is planned as asked", try ClusterPlacementFlow.decide(description: description, capability: capability,
            localMemberID: "mac-one", localProfile: m3, peerProfile: m5, layout: layout, leader: "mac-one").setup?.leaderID == "mac-one"
            && (try ClusterPlacementFlow.decide(description: description, capability: capability,
                localMemberID: "mac-one", localProfile: m3, peerProfile: m5, layout: layout, leader: "mac-two").setup?.leaderID == "mac-two"))
        let m4max = try chip(slowTwo[1], "Apple M4 Max"), m4maxOther = try chip(slowTwo[0], "Apple M4 Max")
        for (name, local, peer) in [("two M5 Max Macs", m5, m5), ("an M3 Ultra and an M4 Max", m3, m4max), ("two M4 Max Macs", m4maxOther, m4max)] {
            let planned = try ClusterPlacementFlow.decide(description: description, capability: capability, localMemberID: "mac-one",
                localProfile: local, peerProfile: peer, layout: layout)
            require("the 9B on \(name) is planned (no chip gates a grant)", planned.setup != nil && planned.result.chosen != nil)
        }
        // Request limits are derived, not typed: the chunk from the model's qualification records and its limits,
        // the deadline from the chosen placement's predicted time for the longest request it admits.
        let planned = try ClusterPlacementPlanner.plan(devices: slowTwo, layout: layout, policy: ClusterPlacementPolicy())
        let slowerPair = [try device("mac-one", physicalGiB: 128, freeGiB: 100, prefill: 1350, decode: 40),
                          try device("mac-two", physicalGiB: 256, freeGiB: 200, prefill: 500, decode: 31)]
        let plannedSlower = try ClusterPlacementPlanner.plan(devices: slowerPair, layout: layout, policy: ClusterPlacementPolicy())
        if let fast = planned.chosen, let slow = plannedSlower.chosen {
            let a = ClusterPlacementRequestLimits.requestTimeoutSeconds(result: planned, chosen: fast, maximumPromptTokens: 8192, maximumOutputTokens: 128)
            let b = ClusterPlacementRequestLimits.requestTimeoutSeconds(result: plannedSlower, chosen: slow, maximumPromptTokens: 32_768, maximumOutputTokens: 4096)
            let long = ClusterPlacementRequestLimits.requestTimeoutSeconds(result: planned, chosen: fast, maximumPromptTokens: 32_768, maximumOutputTokens: 4096)
            require("a request deadline follows the predicted time of the longest request: within the codec's bounds, longer on slower Macs and for longer requests",
                a.seconds == 60 && long.seconds > a.seconds && b.seconds > long.seconds && b.seconds <= 3600 && a.basis.contains("8192 prompt tokens"))
        } else { require("the request-limit fixtures plan", false) }
        let relativeDevices = slowTwo.map { d in
            ClusterPlacementDevice(label: d.label, profile: d.profile, speed: .init(source: .transferredByDeviceIndex, absolute: false,
                rested: d.speed.rested, sustained: nil, explanation: "relative"))
        }
        let relative = try ClusterPlacementPlanner.plan(devices: relativeDevices, layout: layout, policy: ClusterPlacementPolicy())
        if let chosenRelative = relative.chosen {
            require("a plan from relative speeds only never ends a request by a guess",
                ClusterPlacementRequestLimits.requestTimeoutSeconds(result: relative, chosen: chosenRelative, maximumPromptTokens: 8192, maximumOutputTokens: 128).seconds == 3600)
        }
        func run(_ model: String, chunk: Int, _ outcome: [String] = ["divergedAtNearTie"],
                 prompt: Int? = nil, artifact: String? = nil) -> ClusterPairQualificationRecord {
            .init(runtimeModelID: model, artifactSHA256: artifact ?? hash("a"), ranks: [.init(rank: 0, chip: "Apple M2 Max", operatingSystem: nil), .init(rank: 1, chip: "Apple M2 Max", operatingSystem: nil)],
                cuts: [8], generationMode: "pipeline_v1", prefillSchedule: "serial_v1", chunkTokens: chunk, promptTokens: prompt ?? max(64, chunk), outputTokens: 8, transport: "jaccl",
                pairReportSHA256: hash("b"), pairReportCreatedUTC: "t", comparisons: outcome.map { .init(referenceChip: nil, verdict: $0, firstDivergenceIndex: nil,
                gapInULPs: nil, nearTieThresholdULPs: 4, allowed: []) }, producer: "check")
        }
        let chunkRecords = [run("m", chunk: 256), run("m", chunk: 256), run("m", chunk: 512), run("m", chunk: 128, ["diverged"]), run("m", chunk: 4096)]
        require("the prefill chunk is the one the model's passing qualification runs used, within its limits",
            ClusterPlacementRequestLimits.chunkTokens(runtimeModelID: "m", layoutMaximum: 2048, capabilityMaximum: 1024, records: chunkRecords).tokens == 256
            && ClusterPlacementRequestLimits.chunkTokens(runtimeModelID: "other", layoutMaximum: 2048, capabilityMaximum: 1024, records: chunkRecords).tokens == 1024
            && ClusterPlacementRequestLimits.chunkTokens(runtimeModelID: "registered_qwen35_9b", layoutMaximum: 512, capabilityMaximum: 512).tokens == 512)
        let shortOnly = [run("m", chunk: 512, prompt: 52)]
        let shortChoice = ClusterPlacementRequestLimits.chunkTokens(runtimeModelID: "m",
            layoutMaximum: 2048, capabilityMaximum: 2048, records: shortOnly)
        require("a passing 52-token prompt cannot select its unexercised 512-token chunk cap",
            shortOnly[0].isConsistent && shortOnly[0].outcome == .passed
            && shortChoice.tokens == 2048 && shortChoice.basis.contains("largest supported chunk")
            && shortChoice.basis.contains("no matching long-prompt measurement"))
        let exercised512 = [run("m", chunk: 512, prompt: 1024)] + shortOnly + shortOnly
        require("one real full-chunk-capable passing prompt preserves512 over repeated short hints",
            ClusterPlacementRequestLimits.chunkTokens(runtimeModelID: "m",
                layoutMaximum: 2048, capabilityMaximum: 2048, records: exercised512).tokens == 512)
        require("the prompt-equals-chunk boundary is eligible, without proving actual frame geometry",
            ClusterPlacementRequestLimits.chunkTokens(runtimeModelID: "m",
                layoutMaximum: 2048, capabilityMaximum: 2048,
                records: [run("m", chunk: 512, prompt: 512)]).tokens == 512)
        require("fallbacks and record choices stay within both capability and layout caps",
            ClusterPlacementRequestLimits.chunkTokens(runtimeModelID: "m",
                layoutMaximum: 2048, capabilityMaximum: 256, records: exercised512).tokens == 256
            && ClusterPlacementRequestLimits.chunkTokens(runtimeModelID: "m",
                layoutMaximum: 128, capabilityMaximum: 2048, records: exercised512).tokens == 128)
        require("failed full prompts do not set a chunk preference and larger eligible ties still win",
            ClusterPlacementRequestLimits.chunkTokens(runtimeModelID: "m",
                layoutMaximum: 2048, capabilityMaximum: 2048,
                records: [run("m", chunk: 512, ["diverged"])]).tokens == 2048
            && ClusterPlacementRequestLimits.chunkTokens(runtimeModelID: "m",
                layoutMaximum: 2048, capabilityMaximum: 2048,
                records: [run("m", chunk: 512), run("m", chunk: 1024)]).tokens == 1024)
        let artifactRecords = [run("m", chunk: 512, artifact: hash("b")),
                               run("m", chunk: 512, artifact: hash("b")),
                               run("m", chunk: 1024, artifact: hash("a"))]
        require("an installed artifact ignores another artifact's more frequent chunk hint",
            ClusterPlacementRequestLimits.chunkTokens(runtimeModelID: "m", artifactSHA256: hash("a"),
                layoutMaximum: 2048, capabilityMaximum: 2048, records: artifactRecords).tokens == 1024)
        let absentArtifact = ClusterPlacementRequestLimits.chunkTokens(runtimeModelID: "m",
            artifactSHA256: hash("c"), layoutMaximum: 2048, capabilityMaximum: 2048,
            records: artifactRecords)
        require("a missing matching artifact falls back honestly while omitted identity stays compatible",
            absentArtifact.tokens == 2048 && absentArtifact.basis.contains("largest supported chunk")
            && ClusterPlacementRequestLimits.chunkTokens(runtimeModelID: "m",
                layoutMaximum: 2048, capabilityMaximum: 2048, records: artifactRecords).tokens == 512)
        let bundledShortGLM = ClusterPairServingGrants.records.first(where: {
            $0.runtimeModelID == "registered_glm53_flash" && $0.promptTokens == 52 && $0.chunkTokens == 512
        })
        require("the real bundled short GLM fixture exists", bundledShortGLM != nil)
        if let shortGLM = bundledShortGLM {
            let selected = ClusterPlacementRequestLimits.chunkTokens(runtimeModelID: shortGLM.runtimeModelID,
                artifactSHA256: shortGLM.artifactSHA256, layoutMaximum: 2048, capabilityMaximum: 2048,
                records: [shortGLM])
            require("the real bundled short GLM pass stays a passing record without forcing512",
                shortGLM.isConsistent && shortGLM.outcome == .passed && selected.tokens == 2048
                && selected.basis.contains("largest supported chunk") && selected.basis.contains("no matching long-prompt measurement"))
        }
        // The guided flow asks for derived limits (zero) and gets setups that carry them.
        let derivedObject = descriptionObject.merging(["chunkTokens": 0, "requestTimeoutSeconds": 0]) { $1 }
        let derivedDescription = try ClusterPairDescription.decode(JSONSerialization.data(withJSONObject: derivedObject))
        let derived = try ClusterPlacementFlow.decide(description: derivedDescription, capability: capability, localMemberID: "mac-one",
            localProfile: m3, peerProfile: m5, layout: layout)
        if let derivedSetup = derived.setup {
            let leader = try decoded(derivedSetup, derivedSetup.leaderID)
            require("a derived setup carries the qualified chunk and a derived deadline, and says why",
                derivedDescription.derivesRequestLimits && !description.derivesRequestLimits && leader.chunkTokens == 512
                && (60...3600).contains(leader.requestTimeoutSeconds) && derived.lines.contains("Request limits"))
        } else { require("the derived-limits fixture plans", false) }
        let stated = try ClusterPlacementFlow.decide(description: description, capability: capability, localMemberID: "mac-one",
            localProfile: m3, peerProfile: m5, layout: layout)
        require("a description that states its limits keeps them", try stated.setup.map { try decoded($0, $0.leaderID).requestTimeoutSeconds } == 300
            && !stated.lines.contains("Request limits"))
        // Pure decisions of the rule itself. A grant lists no chip: no order is ruled out for any granted model.
        let pair = [(id: "a", chip: "Apple M3 Ultra"), (id: "b", chip: "Apple M5 Max")]
        for model in ["registered_qwen38_27b", "registered_qwen35_35b_a3b", "registered_qwen36_35b_a3b", "registered_ternary_bonsai_2_27b",
                      "registered_nemotron35_lightning", "registered_gpt_oss_20b"] {
            for members in [pair, Array(pair.reversed()), [(id: "a", chip: "Apple M4 Max"), (id: "b", chip: "Apple M4 Max")]] {
                let free = try ClusterPlacementFlow.leaderUnderGrant(requested: nil, members: members, runtimeModelID: model, publicModelID: "p")
                require("\(model) leaves the planner free on \(members.map(\.chip))", free.leader == nil && free.note == nil)
            }
        }
        // A model no stage adapter runs is still planned, and the plan says a start refuses it; a chip name with no class is left to the start.
        let refused = try ClusterPlacementFlow.leaderUnderGrant(requested: nil, members: pair, runtimeModelID: "registered_unknown_model", publicModelID: "p")
        require("a model no stage adapter runs: its plan carries the refusal", refused.leader == nil
            && refused.note?.contains("no cluster stage adapter") == true && refused.note?.contains("refused when it is started") == true)
        let unknown = try ClusterPlacementFlow.leaderUnderGrant(requested: "b", members: [(id: "a", chip: "Check chip"), (id: "b", chip: "Check chip")],
            runtimeModelID: "registered_qwen35_9b", publicModelID: "p")
        require("a chip name with no class decides nothing at plan time", unknown.leader == "b" && unknown.note == nil)
        syntheticQualificationRecords()
        modeBoundGrants()
        recordedSpeculativeCredit()
        // Leader-first onboarding: the Mac where `darkbloom cluster` started leads the cluster (model, sync, start),
        // but which Mac runs rank 0 and which decodes is the planner's, from detected hardware and the model's grant.
        // Synthetic hardware, each pair planned from both Macs: the placement must not follow who asks.
        let m5u = try chip(slowTwo[1], "Apple M5 Ultra"), m3u = try chip(slowTwo[0], "Apple M3 Ultra")
        let fromM3 = try ClusterPlacementFlow.decide(description: description, capability: capability, localMemberID: "mac-one",
            localProfile: m3u, peerProfile: m5u, layout: layout)
        let fromM5 = try ClusterPlacementFlow.decide(description: description, capability: capability, localMemberID: "mac-two",
            localProfile: m5u, peerProfile: m3u, layout: layout)
        require("onboarding on an M3 Ultra and an M5 Ultra: the 9B's placement is the planner's, whichever Mac leads",
            fromM3.setup != nil && fromM3.setup == fromM5.setup)
        let shapes: [(String, [ClusterPlacementDevice])] = [
            ("two 64 GB Macs", [try device("mac-one", physicalGiB: 64, freeGiB: 40, prefill: 1500, decode: 50),
                                 try device("mac-two", physicalGiB: 64, freeGiB: 40, prefill: 1500, decode: 50)]),
            ("a 48 GB and a 256 GB Mac", [try device("mac-one", physicalGiB: 48, freeGiB: 24, prefill: 900, decode: 40),
                                           try device("mac-two", physicalGiB: 256, freeGiB: 200, prefill: 1000, decode: 62)]),
            ("a 128 GB and a 256 GB Mac of other speeds", slowOne)]
        for (name, devices) in shapes {
            let a = try ClusterPlacementFlow.decide(description: description, capability: capability, localMemberID: "mac-one",
                localProfile: devices[0].profile, peerProfile: devices[1].profile, layout: layout)
            let b = try ClusterPlacementFlow.decide(description: description, capability: capability, localMemberID: "mac-two",
                localProfile: devices[1].profile, peerProfile: devices[0].profile, layout: layout)
            require("onboarding on \(name): the same placement whichever Mac leads", a.setup != nil && a.setup == b.setup
                && a.result.chosen?.ranks.allSatisfy { $0.fit == .now } == true)
        }
        guard failures.isEmpty else {
            for failure in failures { FileHandle.standardError.write(Data("FAIL: \(failure)\n".utf8)) }
            exit(1)
        }
        print("placement setup checks passed: \(passed)")
    }

    /// A pipeline's speculative rounds are credited the speed-up their passing
    /// records measured (owner rule: on by default where lossless and measured
    /// faster): the smallest of the installed artifact's passing
    /// `pipeline_mtp_v1` records that carry one; nothing when the family is
    /// withheld, when no record measured it, or for a record of another family.
    static func recordedSpeculativeCredit() {
        func record(_ model: String, mode: String = "pipeline_mtp_v1", verdict: String = "tokensEqualLogitsDiffer",
                    artifact: Character = "a", measured: (Double, Double)? = (66.3, 36.1)) -> ClusterPairQualificationRecord {
            .init(runtimeModelID: model, artifactSHA256: hash(artifact),
                ranks: [.init(rank: 0, chip: "Apple M3 Ultra", operatingSystem: "27.0"), .init(rank: 1, chip: "Apple M5 Ultra", operatingSystem: "27.0")],
                cuts: [8], generationMode: mode, prefillSchedule: "one_chunk_lookahead_v1", chunkTokens: 512, promptTokens: 3952,
                outputTokens: 64, transport: "jaccl", pairReportSHA256: hash("b"), pairReportCreatedUTC: "2026-10-14T00:00:00Z",
                comparisons: [.init(referenceChip: "Apple M3 Ultra", verdict: verdict, firstDivergenceIndex: nil, gapInULPs: nil,
                                    nearTieThresholdULPs: 4, allowed: ["schedule"])], producer: "check",
                measuredDecode: measured.map { .init(modeTokensPerSecond: $0.0, plainPipelineTokensPerSecond: $0.1,
                    modeReportSHA256: hash("c"), plainReportSHA256: hash("d")) })
        }
        let decisions = ClusterPairServingDecisions(records: [
            record("registered_rounds", mode: "pipeline_v1", measured: nil),
            record("registered_rounds"), record("registered_rounds", measured: (59.0, 36.1)),
            record("registered_untimed", mode: "pipeline_v1", measured: nil), record("registered_untimed", measured: nil),
            record("registered_divergedrounds", mode: "pipeline_v1", measured: nil),
            record("registered_divergedrounds"), record("registered_divergedrounds", verdict: "diverged"),
            record("registered_plainonly", mode: "pipeline_v1", measured: (70, 35)),
            record("registered_qwen38_27b", mode: "pipeline_v1", measured: nil), record("registered_qwen38_27b"),
        ])
        func factor(_ model: String, artifact: String? = nil) -> Double? {
            ClusterPairServingGrants.recordedPipelineSpeculativeFactor(runtimeModelID: model, artifactSHA256: artifact, decisions: decisions)
        }
        require("passing records of the rounds credit the smallest speed-up they measured",
            abs((factor("registered_rounds") ?? 0) - 59.0 / 36.1) < 1e-9)
        require("the record's figure survives its JSON line", (try? ClusterPairQualificationRecord.decodeLines(record("registered_rounds").encodedLine()))?
            .first?.measuredPipelineSpeculativeSpeedup.map { abs($0 - 66.3 / 36.1) < 1e-9 } == true)
        require("passing rounds that measured nothing credit nothing", factor("registered_untimed") == nil)
        require("a diverged record of the rounds withholds the family and credits nothing", factor("registered_divergedrounds") == nil)
        require("a pipeline record's figure is no speculative credit", factor("registered_plainonly") == nil)
        require("records of another artifact credit nothing", factor("registered_rounds", artifact: hash("z")) == nil)
        require("a member's roster plan may name the rounds (protocol.ClusterPlanModes)",
            ClusterPlan.modes.contains(ClusterGenerationMode.pipelineMTP.rawValue))
        require("the rounds are plannable where their family is granted",
            ClusterPairServingGrants.plannable([ClusterChipClass(chipName: "Apple M3 Ultra"), ClusterChipClass(chipName: "Apple M5 Ultra")],
                cuts: [8], mode: .pipelineMTP, runtimeModelID: "registered_qwen38_27b", decisions: decisions))
        // The owner's serving needs a cluster stage adapter (owner rule 08:45): a model no adapter runs is never plannable.
        require("a model no stage adapter runs is not plannable, whatever its records",
            !ClusterPairServingGrants.plannable([ClusterChipClass(chipName: "Apple M3 Ultra"), ClusterChipClass(chipName: "Apple M5 Ultra")],
                cuts: [8], mode: .pipelineMTP, runtimeModelID: "registered_rounds", decisions: decisions))
    }

    /// Mode-bound PUBLIC grants (owner sign-off O9), chip-agnostic (owner,
    /// 2026-10-14 08:25): a record qualifies only its own mode family for
    /// public traffic, on any Apple silicon; a diverged record withholds a
    /// family from public traffic only when nothing of it passed; an
    /// inconclusive one neither grants nor withholds. The owner's serving
    /// (08:45) is refused only for a model no stage adapter runs, in any mode
    /// the runtime has, away from the exact shapes that diverged. Synthetic
    /// records on chips this bench never had, under registered model names.
    static func modeBoundGrants() {
        func record(_ model: String, _ chips: [String], cuts: [Int], mode: String, verdicts: [String] = ["tokensEqualLogitsDiffer"]) -> ClusterPairQualificationRecord {
            .init(runtimeModelID: model, artifactSHA256: hash("a"), ranks: chips.enumerated().map { .init(rank: $0.offset, chip: $0.element, operatingSystem: "27.0") },
                cuts: cuts, generationMode: mode, prefillSchedule: "serial_v1", chunkTokens: 512, promptTokens: 4096, outputTokens: 128, transport: "jaccl",
                pairReportSHA256: hash("b"), pairReportCreatedUTC: "2026-10-14T00:00:00Z",
                comparisons: verdicts.map { .init(referenceChip: chips.last, verdict: $0, firstDivergenceIndex: 7, gapInULPs: $0 == "diverged" ? 9 : 1,
                                                  nearTieThresholdULPs: 4, allowed: ["cut"]) }, producer: "check")
        }
        func cls(_ name: String) -> ClusterChipClass? { ClusterChipClass(chipName: name) }
        let m2Max = cls("Apple M2 Max"), m4Max = cls("Apple M4 Max"), m3Ultra = cls("Apple M3 Ultra"), m5Ultra = cls("Apple M5 Ultra"), m5Max = cls("Apple M5 Max")
        let handoffModel = "registered_qwen38_27b", retired = "registered_qwen35_9b", mixed = "registered_ternary_bonsai_2_27b"
        let cutdepModel = "registered_gpt_oss_20b", unsure = "registered_nemotron35_lightning", nobody = "registered_qwen36_35b_a3b"
        require("pipeline and compact decode are one family; the phase splits are the hand-off family",
            ClusterGenerationMode.pipeline.servingFamily == .pipeline && ClusterGenerationMode.pipelineCompactDecode.servingFamily == .pipeline
                && ClusterGenerationMode.phaseSplit.servingFamily == .handOff && ClusterGenerationMode.phaseSplitMTP.servingFamily == .handOff)
        let decisions = ClusterPairServingDecisions(records: [
            // Only hand-off records: a phase-split pass qualifies no pipeline for public traffic.
            record(handoffModel, ["Apple M3 Ultra", "Apple M5 Ultra"], cuts: [8], mode: "phase_split_mtp_v1"),
            // Pipeline passed on a retired chip, hand-off on the current pair.
            record(retired, ["Apple M3 Ultra", "Apple M5 Max"], cuts: [16], mode: "pipeline_v1"),
            record(retired, ["Apple M3 Ultra", "Apple M5 Ultra"], cuts: [8], mode: "phase_split_v1"),
            // Pipeline passed, hand-off diverged: the pipeline family stays granted.
            record(mixed, ["Apple M2 Max", "Apple M4 Max"], cuts: [12], mode: "pipeline_compact_decode_v1"),
            record(mixed, ["Apple M2 Max", "Apple M4 Max"], cuts: [12], mode: "phase_split_v1", verdicts: ["diverged"]),
            // Pipeline diverged at one cut and passed at another, hand-off passed: both granted, the diverged shape steered away from.
            record(cutdepModel, ["Apple M2 Max", "Apple M4 Max"], cuts: [4], mode: "pipeline_v1", verdicts: ["tokensEqualLogitsDiffer", "diverged"]),
            record(cutdepModel, ["Apple M2 Max", "Apple M4 Max"], cuts: [11], mode: "pipeline_v1"),
            record(cutdepModel, ["Apple M2 Max", "Apple M4 Max"], cuts: [11], mode: "phase_split_v1"),
            // An inconclusive pipeline record neither grants nor withholds.
            record(unsure, ["Apple M2 Max", "Apple M4 Max"], cuts: [12], mode: "pipeline_v1", verdicts: ["incomparable"]),
            record(unsure, ["Apple M2 Max", "Apple M4 Max"], cuts: [12], mode: "phase_split_v1"),
        ])
        func allows(_ classes: [ClusterChipClass?], _ model: String, cuts: [Int], _ mode: ClusterGenerationMode) -> Bool {
            (try? ClusterPairServingGrants.requirePlacement(classes, runtimeModelID: model, publicModelID: "p", cuts: cuts, mode: mode, decisions: decisions)) != nil
        }
        func reason(_ classes: [ClusterChipClass?], _ model: String, cuts: [Int]?, _ mode: ClusterGenerationMode?) -> String {
            do { try ClusterPairServingGrants.requirePlacement(classes, runtimeModelID: model, publicModelID: "p", cuts: cuts, mode: mode, decisions: decisions); return "allowed" }
            catch { return String(describing: error) }
        }
        func publicFamilies(_ model: String) -> [ClusterPairServingModeFamily]? {
            (try? ClusterPairServingGrants.grant(runtimeModelID: model, publicModelID: "p", decisions: decisions))?.families
        }
        require("a hand-off record qualifies the hand-off family for public traffic, and the owner is served in every mode",
            publicFamilies(handoffModel) == [.handOff] && allows([m3Ultra, m5Ultra], handoffModel, cuts: [8], .phaseSplitMTP)
                && allows([m3Ultra, m5Ultra], handoffModel, cuts: [8], .pipeline) && allows([m3Ultra, m5Ultra], handoffModel, cuts: [8], .pipelineCompactDecode))
        require("public traffic for a family no record passed is not yet qualified",
            ClusterPairServingGrants.publicTrafficLine(runtimeModelID: handoffModel, mode: .pipeline, decisions: decisions) == ClusterPairOwnerServing.notYetQualified
                && ClusterPairServingGrants.publicTrafficLine(runtimeModelID: handoffModel, mode: .phaseSplit, decisions: decisions).hasPrefix("qualified for public traffic"))
        require("a placement checked without its mode is refused", reason([m3Ultra, m5Ultra], handoffModel, cuts: [8], nil).contains("without its generation mode"))
        let handoff = try? ClusterPairServingGrants.grant(runtimeModelID: handoffModel, publicModelID: "p", decisions: decisions)
        require("a grant lists its families and no chip", handoff?.families == [.handOff] && handoff?.qualifiedChipClasses == [m3Ultra!, m5Ultra!]
            && allows([m4Max, m2Max], handoffModel, cuts: [8], .phaseSplitMTP))
        require("a record of a retired chip qualifies its own family on any chips",
            publicFamilies(retired) == [.pipeline, .handOff] && allows([m3Ultra, m5Max], retired, cuts: [16], .pipeline)
                && allows([m3Ultra, m5Ultra], retired, cuts: [16], .pipeline) && allows([m3Ultra, m5Max], retired, cuts: [8], .phaseSplit))
        require("a diverged hand-off record with no hand-off pass leaves the pipeline family granted and steers the owner from its shape",
            allows([m2Max, m4Max], mixed, cuts: [12], .pipeline) && !allows([m2Max, m4Max], mixed, cuts: [12], .phaseSplit)
                && allows([m2Max, m4Max], mixed, cuts: [16], .phaseSplit)
                && reason([m2Max, m4Max], mixed, cuts: [12], .phaseSplit).contains("diverged from its single-Mac reference")
                && decisions.withheld[mixed] == nil && publicFamilies(mixed) == [.pipeline])
        let cutdep = try? ClusterPairServingGrants.grant(runtimeModelID: cutdepModel, publicModelID: "p", decisions: decisions)
        require("a diverged pipeline record steers away from its shape only (and its rank-shape on the Mac that ran it)",
            allows([m2Max, m4Max], cutdepModel, cuts: [11], .pipeline) && !allows([m2Max, m4Max], cutdepModel, cuts: [4], .pipeline)
                && allows([m2Max, m4Max], cutdepModel, cuts: [6], .pipeline) && allows([m4Max, m4Max], cutdepModel, cuts: [6], .pipeline)
                && !allows([m4Max, m4Max], cutdepModel, cuts: [4], .pipeline) && allows([m4Max, m2Max], cutdepModel, cuts: [4], .pipeline)
                && allows([m2Max, m4Max], cutdepModel, cuts: [11], .phaseSplit)
                && cutdep?.families == [.pipeline, .handOff] && cutdep?.withheldFamilies.isEmpty == true)
        require("an inconclusive record neither grants nor withholds its family",
            publicFamilies(unsure) == [.handOff] && allows([m2Max, m4Max], unsure, cuts: [12], .pipeline) && allows([m2Max, m4Max], unsure, cuts: [12], .phaseSplit)
                && (try? ClusterPairServingGrants.grant(runtimeModelID: unsure, publicModelID: "p", decisions: decisions))?.withheldFamilies.isEmpty == true)
        // The planner keeps to the owner's rule: any mode, away from the shapes that diverged.
        func plans(_ classes: [ClusterChipClass?], _ model: String, cuts: [Int], _ mode: ClusterGenerationMode) -> Bool {
            ClusterPairServingGrants.plannable(classes, cuts: cuts, mode: mode, runtimeModelID: model, decisions: decisions)
        }
        require("the planner plans every mode on any chips for the owner",
            plans([m3Ultra, m5Ultra], handoffModel, cuts: [8], .phaseSplitMTP) && plans([m3Ultra, m5Ultra], handoffModel, cuts: [8], .pipeline)
                && plans([m5Ultra, m3Ultra], handoffModel, cuts: [], .tensorParallel)
                && plans([m3Ultra, m5Max], retired, cuts: [24], .pipelineCompactDecode) && plans([m3Ultra, m5Ultra], retired, cuts: [24], .pipeline))
        require("the planner steers away from the shapes that diverged and leaves a classless chip to the start",
            plans([m2Max, m4Max], cutdepModel, cuts: [11], .pipeline) && !plans([m2Max, m4Max], cutdepModel, cuts: [4], .pipeline)
                && plans([m4Max, m4Max], cutdepModel, cuts: [6], .pipeline) && !plans([m4Max, m4Max], cutdepModel, cuts: [4], .pipeline)
                && plans([nil, m5Ultra], handoffModel, cuts: [8], .phaseSplit) && plans([nil, m4Max], handoffModel, cuts: [8], .phaseSplit)
                && plans([nil, m4Max], cutdepModel, cuts: [6], .pipeline) && !plans([m2Max, nil], cutdepModel, cuts: [4], .pipeline)
                && plans([m2Max, m4Max], nobody, cuts: [3], .pipeline) && !plans([m2Max, m4Max], "registered_nobody", cuts: [3], .pipeline))
        // The shipped records: every model a stage adapter runs, on the M3 Ultra and the M5 Ultra in both orders, and on two M4 Max Macs.
        let m3 = m3Ultra!, m5u = m5Ultra!, m4 = m4Max!
        func servesPipeline(_ model: String, _ order: [ClusterChipClass], cut: Int? = nil) -> Bool {
            (try? ClusterPairServingGrants.requirePlacement(order, runtimeModelID: model, publicModelID: "p", cuts: cut.map { [$0] }, mode: .pipeline)) != nil
        }
        for model in ["registered_qwen35_9b", "registered_qwen38_27b", "registered_nemotron35_lightning", "registered_qwen35_35b_a3b",
                      "registered_qwen36_35b_a3b", "registered_mimo_v26_flash_mopd", "registered_ternary_bonsai_2_27b"] {
            require("shipped: \(model) pipeline in both orders and on two M4 Max Macs",
                servesPipeline(model, [m3, m5u]) && servesPipeline(model, [m5u, m3]) && servesPipeline(model, [m4, m4]))
        }
        require("shipped: Gemma 4 8-bit has no public grant (its one pass is contradicted) and is served for its owner away from that shape",
            ClusterPairServingGrants.withheld["registered_gemma4_26b_8bit"] != nil && servesPipeline("registered_gemma4_26b_8bit", [m4, m4], cut: 6)
                && !servesPipeline("registered_gemma4_26b_8bit", [m3, m5Max!], cut: 12))
        for model in ["registered_gpt_oss_20b", "registered_gemma4_26b_qat_4bit"] {
            let checks = ClusterPairServingGrants.records(runtimeModelID: model)
            let diverged = checks.failed.first { $0.chipClasses == [m3, m5u] }
            require("shipped: \(model) is steered from its diverged shape on the bench pair and served on two M4 Max Macs",
                diverged.map { !servesPipeline(model, [m3, m5u], cut: $0.cuts[0]) } == true && servesPipeline(model, [m4, m4], cut: 6)
                    && ClusterPairServingGrants.withheld[model] == nil)
        }
        // What the onboarding offers is what a start serves: at the planner's sharded shape each model starts,
        // on the bench pair and on two M4 Max Macs.
        func startRefusal(_ model: String, _ order: [ClusterChipClass?], _ cut: Int) -> ClusterPairServingRefusal? {
            ClusterPairServingGrants.startRefusal(order, cuts: [cut], mode: .pipeline, runtimeModelID: model, publicModelID: "p")
        }
        for (model, order, cut) in [("registered_qwen38_27b", [m3, m5u], 8), ("registered_qwen35_9b", [m3, m5u], 4),
                                    ("registered_nemotron35_lightning", [m3, m5u], 8), ("registered_qwen35_35b_a3b", [m5u, m3], 36),
                                    ("registered_qwen36_35b_a3b", [m5u, m3], 36), ("registered_ternary_bonsai_2_27b", [m5u, m3], 56),
                                    ("registered_mimo_v26_flash_mopd", [m5u, m3], 40), ("registered_qwen38_27b", [m5u, m3], 56),
                                    ("registered_qwen35_9b", [m4, m4], 16), ("registered_qwen38_27b", [m4, m4], 32),
                                    ("registered_mimo_v26_flash_mopd", [m4, m4], 24), ("registered_gpt_oss_20b", [m3, m5u], 6),
                                    ("registered_gemma4_26b", [m4, m4], 12)] {
            require("offered: \(model) starts at cut \(cut) on \(order.map { $0.rawValue })", startRefusal(model, order, cut) == nil)
        }
        require("not offered: GPT-OSS at a cut its bench-pair check diverged at",
            !ClusterPairServingGrants.plannable([m3, m5u], cuts: [4], mode: .pipeline, runtimeModelID: "registered_gpt_oss_20b")
                && startRefusal("registered_gpt_oss_20b", [m3, m5u], 4) != nil)
        require("not offered: a model no stage adapter runs", startRefusal("registered_unknown_model", [m3, m5u], 8)?.reason == .noStageAdapter)
        require("a rank with no class is left to its own start", startRefusal("registered_qwen38_27b", [m3, nil], 8) == nil)
    }

    /// Public grants come from qualification records only, for any chips and
    /// any number of ranks; the owner is served with or without them.
    /// Synthetic records for Macs this bench never had.
    static func syntheticQualificationRecords() {
        func record(_ model: String, _ chips: [String], cuts: [Int], mode: String = "pipeline_v1", verdicts: [String] = ["divergedAtNearTie"],
                    transport: String = "jaccl") -> ClusterPairQualificationRecord {
            .init(runtimeModelID: model, artifactSHA256: hash("a"), ranks: chips.enumerated().map { .init(rank: $0.offset, chip: $0.element, operatingSystem: "27.0") },
                cuts: cuts, generationMode: mode, prefillSchedule: "serial_v1", chunkTokens: 512, promptTokens: 4096, outputTokens: 128, transport: transport,
                pairReportSHA256: hash("b"), pairReportCreatedUTC: "2026-10-12T00:00:00Z",
                comparisons: verdicts.map { .init(referenceChip: chips.last, verdict: $0, firstDivergenceIndex: 7, gapInULPs: $0 == "diverged" ? 9 : 1,
                                                  nearTieThresholdULPs: 4, allowed: ["cut"]) }, producer: "check")
        }
        func cls(_ name: String) -> ClusterChipClass? { ClusterChipClass(chipName: name) }
        let m2Max = cls("Apple M2 Max"), m4Pro = cls("Apple M4 Pro"), m3Ultra = cls("Apple M3 Ultra")
        let m1Ultra = cls("Apple M1 Ultra"), m2Ultra = cls("Apple M2 Ultra"), m4Max = cls("Apple M4 Max")
        let dense = "registered_qwen35_9b", wideModel = "registered_qwen38_27b", split = "registered_ternary_bonsai_2_27b"
        let unsure = "registered_nemotron35_lightning", loopback = "registered_qwen35_35b_a3b", virtual = "registered_qwen36_35b_a3b"
        let decisions = ClusterPairServingDecisions(records: [
            record(dense, ["Apple M2 Max", "Apple M2 Max"], cuts: [16]),
            record(dense, ["Apple M4 Pro", "Apple M3 Ultra"], cuts: [12], mode: "phase_split_v1", verdicts: ["exact", "tokensEqualLogitsDiffer"]),
            record(wideModel, ["Apple M1 Ultra", "Apple M2 Ultra", "Apple M4 Max"], cuts: [10, 20]),
            record(split, ["Apple M2 Max", "Apple M2 Max"], cuts: [16]),
            record(split, ["Apple M2 Max", "Apple M2 Max"], cuts: [8], verdicts: ["divergedAtNearTie", "diverged"]),
            record(unsure, ["Apple M2 Max", "Apple M2 Max"], cuts: [16], verdicts: ["incomparable"]),
            // Never used: both ranks on one Mac, a chip with no class, cuts out of order.
            record(loopback, ["Apple M2 Max", "Apple M2 Max"], cuts: [16], transport: "local-socket-test"),
            record(virtual, ["Apple M1 (Virtual)", "Apple M2 Max"], cuts: [16]),
            record(wideModel, ["Apple M1 Ultra", "Apple M2 Ultra", "Apple M4 Max"], cuts: [20, 10]),
        ])
        func allows(_ classes: [ClusterChipClass?], _ model: String, _ mode: ClusterGenerationMode = .pipeline) -> Bool {
            (try? ClusterPairServingGrants.requirePlacement(classes, runtimeModelID: model, publicModelID: "p", mode: mode, decisions: decisions)) != nil
        }
        func publicFamilies(_ model: String) -> [ClusterPairServingModeFamily]? {
            (try? ClusterPairServingGrants.grant(runtimeModelID: model, publicModelID: "p", decisions: decisions))?.families
        }
        func shipped(_ classes: [ClusterChipClass?], _ model: String, _ mode: ClusterGenerationMode) -> Bool {
            (try? ClusterPairServingGrants.requirePlacement(classes, runtimeModelID: model, publicModelID: "p", cuts: [16], mode: mode)) != nil
        }
        require("two 64 GB M2 Max Macs are served and qualified for public traffic", allows([m2Max, m2Max], dense) && publicFamilies(dense) == [.pipeline, .handOff])
        require("each family is served on any chips, in any order; tensor parallel too, with no public grant",
            allows([m4Pro, m3Ultra], dense, .phaseSplit) && allows([m4Pro, m3Ultra], dense, .pipeline)
            && allows([m3Ultra, m4Pro], dense, .phaseSplit) && allows([m3Ultra, m2Max], dense, .phaseSplit)
            && allows([m3Ultra, m2Max], dense, .tensorParallel)
            && ClusterPairServingGrants.publicTrafficLine(runtimeModelID: dense, mode: .tensorParallel, decisions: decisions) == ClusterPairOwnerServing.notYetQualified)
        require("three ranks: any chips in any order, and any number of ranks", allows([m1Ultra, m2Ultra, m4Max], wideModel)
            && allows([m2Ultra, m1Ultra, m4Max], wideModel) && allows([m1Ultra, m4Max, m2Ultra], wideModel)
            && allows([m1Ultra, m4Max], wideModel) && allows([m4Max, m1Ultra], wideModel))
        let wide = try? ClusterPairServingGrants.grant(runtimeModelID: wideModel, publicModelID: "p", decisions: decisions)
        require("a three-rank grant names the chips its record ran as evidence", wide?.qualifiedChipClasses == [m1Ultra!, m2Ultra!, m4Max!]
            && wide?.qualifications.count == 1 && wide?.evidence.contains("1 passing cross-cable qualification record") == true)
        require("the shape that diverged is not served on its chips; every other shape and other chips are",
            decisions.withheld[split] == nil
            && (try? ClusterPairServingGrants.requirePlacement([m2Max, m2Max], runtimeModelID: split, publicModelID: "p", cuts: [8], mode: .pipeline, decisions: decisions)) == nil
            && (try? ClusterPairServingGrants.requirePlacement([m2Max, m2Max], runtimeModelID: split, publicModelID: "p", cuts: [16], mode: .pipeline, decisions: decisions)) != nil
            && (try? ClusterPairServingGrants.requirePlacement([m2Max, m2Max], runtimeModelID: split, publicModelID: "p", cuts: [12], mode: .pipeline, decisions: decisions)) != nil
            && (try? ClusterPairServingGrants.requirePlacement([m4Max, m4Max], runtimeModelID: split, publicModelID: "p", cuts: [8], mode: .pipeline, decisions: decisions)) != nil)
        refuses("an undecided model has no public grant", because: "not yet qualified for public traffic") {
            _ = try ClusterPairServingGrants.grant(runtimeModelID: unsure, publicModelID: "p", decisions: decisions)
        }
        require("an undecided model is served for its owner", allows([m2Max, m2Max], unsure))
        require("loopback runs, classless chips and malformed cuts are never used: no public grant, the owner is served",
            decisions.ignored == 3 && publicFamilies(loopback) == nil && publicFamilies(virtual) == nil
                && allows([m2Max, m2Max], loopback) && allows([m2Max, m2Max], virtual))
        require("the records this build ships all decode and are all used", !ClusterPairServingGrants.records.isEmpty
            && ClusterPairServingGrants.decisions.ignored == 0 && ClusterPairServingGrants.records.allSatisfy(\.isConsistent))
        // A public grant rests on records of the installed artifact: the same records, another artifact, no public grant.
        let ran = ClusterPairServingGrants.records.first { $0.runtimeModelID == "registered_qwen35_9b" }!.artifactSHA256
        require("the 9B's grant holds for the artifact its records ran", (try? ClusterPairServingGrants.grant(
            runtimeModelID: "registered_qwen35_9b", publicModelID: "p", artifactSHA256: ran)) != nil)
        refuses("another artifact of the 9B has no public grant", because: "is installed as artifact 999999999999") {
            _ = try ClusterPairServingGrants.grant(runtimeModelID: "registered_qwen35_9b", publicModelID: "p", artifactSHA256: hash("9"))
        }
        require("a rank of another artifact is served for its owner", (try? ClusterPairServingGrants.requireRank(0, of: 2, chipClass: m3Ultra,
            runtimeModelID: "registered_qwen35_9b", publicModelID: "p", artifactSHA256: hash("9"), cuts: [4], mode: .pipeline)) != nil)
        // One artifact is one model: a record labelled with one model that ran another model's artifact (the two
        // registered_gemma4_26b records that ran the 8-bit artifact) is not shipped.
        let owners = Dictionary(grouping: ClusterPairServingGrants.records, by: \.artifactSHA256).mapValues { Set($0.map(\.runtimeModelID)) }
        require("no shipped artifact is recorded under two registered models", owners.values.allSatisfy { $0.count == 1 })
        require("the shipped records serve the 9B in both orders and on Macs no check ran",
            shipped([m3Ultra, cls("Apple M5 Ultra")], "registered_qwen35_9b", .phaseSplitMTP) && shipped([cls("Apple M5 Ultra"), m3Ultra], "registered_qwen35_9b", .phaseSplitMTP)
                && shipped([m4Max, m4Max], "registered_qwen35_9b", .pipeline))
    }
}
