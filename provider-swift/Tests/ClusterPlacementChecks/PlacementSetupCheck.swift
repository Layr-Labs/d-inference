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

    /// MTP on by default on a planner-built setup (PERF-BACKLOG item 2): with
    /// the row's credit and the head in the layout (as the plan tool now reads
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
                localProfile: local, peerProfile: peer, layout: headed)
            let configurations = try decided.setup.map { setup in
                try setup.configurations.values.map {
                    try ClusterConfigurationCodec.decode($0, capability: capability, capabilitySHA256: capabilityHash)
                }
            } ?? []
            require("planned from \(who): the head by default, the M3 Ultra leading and the M5 decoding, saved by name in both setups",
                decided.result.chosen?.mode == .phaseSplitMTP && decided.setup?.leaderID == "mac-two"
                    && configurations.count == 2 && configurations.allSatisfy { $0.generationMode == .phaseSplitMTP }
                    && decided.lines.contains { $0.contains("It decodes with the model's speculative (MTP) head") })
        }
        // The other order is asked for: this model's pair-serving grant (owner decision D4) lets only the M3 Ultra
        // lead it, so the mirrored order is refused at plan time instead of being saved without the head.
        refuses("led by the M5, the 9B fixture's grant refuses the order", because: "pipeline-only rank on apple_m3_ultra") {
            _ = try ClusterPlacementFlow.decide(description: description, capability: capability, localMemberID: "mac-one",
                localProfile: m5, peerProfile: m3, layout: headed, leader: "mac-one")
        }
        // Two Macs of no known generation: nothing prefers the head, the setup is what it was.
        let unknown = try ClusterPlacementFlow.decide(description: description, capability: capability, localMemberID: "mac-one",
            localProfile: slowTwo[0].profile, peerProfile: slowTwo[1].profile, layout: headed)
        require("chips of no known generation keep the plain plan", unknown.result.chosen.map { !$0.mode.usesSpeculativeHead } == true)
    }

    /// The universal rule of qualification records (`ClusterPairQualificationRecords`): a model with a failed
    /// cross-cable check on record is planned and started only at shapes a check passed in. Synthetic records of
    /// two to four ranks on several chips; then the registered GPT-OSS records through the guided step's own
    /// decision, on an M3 Ultra with an M5 Ultra (passed at cut 12, diverged at cut 4) and with a chip no check ran.
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
        require("records: one failed check restricts every shape of the model", three.restrictsShapes)
        require("records: a passed shape of three ranks is admitted whole", three.admits(chipClasses: [m2, m4, m5u], cuts: [8, 20], mode: .pipeline))
        require("records: another cut, mode or order of the same chips is not",
            !three.admits(chipClasses: [m2, m4, m5u], cuts: [10, 20], mode: .pipeline)
                && !three.admits(chipClasses: [m2, m4, m5u], cuts: [8, 20], mode: .pipelineCompactDecode)
                && !three.admits(chipClasses: [m5u, m4, m2], cuts: [8, 20], mode: .pipeline)
                && !three.admits(chipClasses: [m2, nil, m5u], cuts: [8, 20], mode: .pipeline))
        // Mode-bound (O9): a failed pipeline check restricts the pipeline family's shapes; another family is
        // restricted by its own records and its grant, not by these.
        require("records: a failed check restricts its own mode family only", three.restrictedFamilies == [.pipeline]
            && three.admits(chipClasses: [m2, m4, m5u], cuts: [8, 20], mode: .phaseSplit))
        require("records: each rank decides its own half with its own class",
            three.admitsRank(1, of: 3, chipClass: m4, cuts: [8, 20], mode: .pipeline)
                && !three.admitsRank(1, of: 3, chipClass: m2, cuts: [8, 20], mode: .pipeline)
                && !three.admitsRank(1, of: 2, chipClass: m4, cuts: [8, 20], mode: .pipeline)
                && three.admitsRank(1, of: 2, chipClass: m2, cuts: [12], mode: .pipelineCompactDecode))
        let four = ClusterPairQualificationRecords(runtimeModelID: "x", passed: [], failed: [.init(chipClasses: [m4, m4, m4, m4], cuts: [6, 12, 18], mode: .pipeline)])
        require("records: a model whose every check failed admits no shape", four.restrictsShapes
            && !four.admits(chipClasses: [m4, m4, m4, m4], cuts: [6, 12, 18], mode: .pipeline) && four.passedShapesText == "none")

        // The registered records: GPT-OSS diverged at cut 4 with the M3 Ultra leading the M5 Ultra and passed at 12.
        let gpt = ClusterPairServingGrants.records(runtimeModelID: "registered_gpt_oss_20b")
        require("GPT-OSS: its failed checks restrict its shapes", gpt.restrictsShapes
            && gpt.admits(chipClasses: [m3, m5u], cuts: [12], mode: .pipeline)
            && gpt.admits(chipClasses: [m3, m5u], cuts: [11], mode: .pipeline)
            && !gpt.admits(chipClasses: [m3, m5u], cuts: [10], mode: .pipeline)
            && !gpt.admits(chipClasses: [m3, m5u], cuts: [12], mode: .pipelineCompactDecode)
            && !gpt.admits(chipClasses: [m3, m5u], cuts: [4], mode: .pipeline)
            && !gpt.admits(chipClasses: [m5u, m3], cuts: [12], mode: .pipeline))
        require("a model with no failed check keeps its grant by role and class",
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
        // Passed at cuts 11, 12 and 16: the fastest of those, 11, gives the faster M5 Ultra the most layers.
        require("GPT-OSS on an M3 Ultra leading an M5 Ultra is planned only at its passed shapes, the fastest first",
            decided.result.chosen?.cut == 11 && decided.result.chosen?.mode == .pipeline
                && decided.result.alternatives.allSatisfy { [11, 12, 16].contains($0.cut) && $0.mode == .pipeline }
                && (decided.result.unqualifiedPossible ?? 0) > 0)
        require("the plan says why, with the passed placements",
            decided.lines.contains("Qualified placements")
                && decided.lines.contains { $0.contains("apple_m3_ultra then apple_m5_ultra at cut 12 (pipeline_v1)") })
        let elsewhere = try ClusterPlacementFlow.decide(description: description, capability: capability, localMemberID: "mac-one",
            localProfile: ultra3, peerProfile: try profile(slowTwo[1], "Apple M4 Pro"), layout: layout, leader: "mac-one")
        require("GPT-OSS on chips no check passed is planned nowhere, and the plan says so",
            elsewhere.result.chosen == nil && elsewhere.setup == nil && (elsewhere.result.unqualifiedPossible ?? 0) > 0
                && elsewhere.lines.contains("Refused: no placement these Macs can hold is qualified for this model"))
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
            var policy = ClusterPlacementPolicy(); policy.modes = modes
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
            require("the 9B on an M3 Ultra and an M5 Max is planned with the M3 Ultra leading, asked from \(who)",
                held.setup?.leaderID == "mac-one" && held.result.chosen?.ranks.first?.device == "mac-one"
                    && held.lines.contains("Pair-serving grant") && held.lines.contains { $0.contains("so mac-one leads") })
        }
        let swapped = try ClusterPlacementFlow.decide(description: description, capability: capability, localMemberID: "mac-one",
            localProfile: m5, peerProfile: m3, layout: layout)
        require("with the chips the other way round the other Mac leads", swapped.setup?.leaderID == "mac-two")
        require("an order the grant allows is planned as asked", try ClusterPlacementFlow.decide(description: description, capability: capability,
            localMemberID: "mac-one", localProfile: m3, peerProfile: m5, layout: layout, leader: "mac-one").setup?.leaderID == "mac-one")
        refuses("the 9B led by the M5 Max is refused at plan time", because: "pipeline-only rank on apple_m3_ultra") {
            _ = try ClusterPlacementFlow.decide(description: description, capability: capability, localMemberID: "mac-one",
                localProfile: m3, peerProfile: m5, layout: layout, leader: "mac-two")
        }
        refuses("two M5 Max Macs have no order the 9B's grant allows", because: "runs on apple_m5_max") {
            _ = try ClusterPlacementFlow.decide(description: description, capability: capability, localMemberID: "mac-one",
                localProfile: m5, peerProfile: m5, layout: layout)
        }
        refuses("a chip the grant lists for no rank is refused", because: "runs on apple_m4_max") {
            _ = try ClusterPlacementFlow.decide(description: description, capability: capability, localMemberID: "mac-one",
                localProfile: m3, peerProfile: try chip(slowTwo[1], "Apple M4 Max"), layout: layout, leader: "mac-one")
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
        func run(_ model: String, chunk: Int, _ outcome: [String] = ["divergedAtNearTie"]) -> ClusterPairQualificationRecord {
            .init(runtimeModelID: model, artifactSHA256: hash("a"), ranks: [.init(rank: 0, chip: "Apple M2 Max", operatingSystem: nil), .init(rank: 1, chip: "Apple M2 Max", operatingSystem: nil)],
                cuts: [8], generationMode: "pipeline_v1", prefillSchedule: "serial_v1", chunkTokens: chunk, promptTokens: 64, outputTokens: 8, transport: "jaccl",
                pairReportSHA256: hash("b"), pairReportCreatedUTC: "t", comparisons: outcome.map { .init(referenceChip: nil, verdict: $0, firstDivergenceIndex: nil,
                gapInULPs: nil, nearTieThresholdULPs: 4, allowed: []) }, producer: "check")
        }
        let chunkRecords = [run("m", chunk: 256), run("m", chunk: 256), run("m", chunk: 512), run("m", chunk: 128, ["diverged"]), run("m", chunk: 4096)]
        require("the prefill chunk is the one the model's passing qualification runs used, within its limits",
            ClusterPlacementRequestLimits.chunkTokens(runtimeModelID: "m", layoutMaximum: 2048, capabilityMaximum: 1024, records: chunkRecords).tokens == 256
            && ClusterPlacementRequestLimits.chunkTokens(runtimeModelID: "other", layoutMaximum: 2048, capabilityMaximum: 1024, records: chunkRecords).tokens == 1024
            && ClusterPlacementRequestLimits.chunkTokens(runtimeModelID: "registered_qwen35_9b", layoutMaximum: 512, capabilityMaximum: 512).tokens == 512)
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
        // Pure decisions of the rule itself. The 27B is granted on both chips for both ranks: no order is ruled out.
        let pair = [(id: "a", chip: "Apple M3 Ultra"), (id: "b", chip: "Apple M5 Max")]
        let free = try ClusterPlacementFlow.leaderUnderGrant(requested: nil, members: pair, runtimeModelID: "registered_qwen38_27b", publicModelID: "p")
        require("the 27B leaves the planner free on an M3 Ultra and an M5 Max", free.leader == nil && free.note == nil)
        for model in ["registered_qwen35_35b_a3b", "registered_qwen36_35b_a3b", "registered_ternary_bonsai_2_27b", "registered_nemotron35_lightning"] {
            let one = try ClusterPlacementFlow.leaderUnderGrant(requested: nil, members: pair.reversed(), runtimeModelID: model, publicModelID: "p")
            // Every granted family lists the M5 Max as a decoding rank and never as rank 0 (mode-bound: the M5 Ultra's
            // pipeline records may add other classes to the words, not this order).
            require("\(model) is planned with the M3 Ultra leading", one.leader == "a" && one.note?.contains("decoding rank (the last) on") == true
                && one.note?.contains("apple_m5_max") == true)
        }
        // A withheld model is still planned, and the plan says a start refuses it; a chip name with no class is left to the start.
        let withheld = try ClusterPlacementFlow.leaderUnderGrant(requested: nil, members: pair, runtimeModelID: "registered_gpt_oss_20b", publicModelID: "p")
        require("a withheld model's plan carries the refusal", withheld.leader == nil && withheld.note?.contains("is not granted pair serving") == true
            && withheld.note?.contains("refused when it is started") == true)
        let unknown = try ClusterPlacementFlow.leaderUnderGrant(requested: "b", members: [(id: "a", chip: "Check chip"), (id: "b", chip: "Check chip")],
            runtimeModelID: "registered_qwen35_9b", publicModelID: "p")
        require("a chip name with no class decides nothing at plan time", unknown.leader == "b" && unknown.note == nil)
        syntheticQualificationRecords()
        modeBoundGrants()
        // Leader-first onboarding: the Mac where `darkbloom cluster` started leads the cluster (model, sync, start),
        // but which Mac runs rank 0 and which decodes is the planner's, from detected hardware and the model's grant.
        // Synthetic hardware, each pair planned from both Macs: the placement must not follow who asks.
        let m5u = try chip(slowTwo[1], "Apple M5 Ultra"), m3u = try chip(slowTwo[0], "Apple M3 Ultra")
        let fromM3 = try ClusterPlacementFlow.decide(description: description, capability: capability, localMemberID: "mac-one",
            localProfile: m3u, peerProfile: m5u, layout: layout)
        let fromM5 = try ClusterPlacementFlow.decide(description: description, capability: capability, localMemberID: "mac-two",
            localProfile: m5u, peerProfile: m3u, layout: layout)
        require("onboarding on an M3 Ultra and an M5 Ultra: the 9B's rank 0 is the M3 Ultra and the M5 Ultra decodes, whichever Mac leads",
            fromM3.setup == fromM5.setup && fromM3.setup?.leaderID == "mac-one" && fromM3.result.chosen?.ranks.last?.device == "mac-two")
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

    /// Mode-bound grants (owner sign-off O9): a record grants only its own mode
    /// family (pipeline variants, pipeline MTP, tensor parallel, the hand-off
    /// modes) and only the chip classes in the roles it ran; a diverged record
    /// withholds its own family; an inconclusive one neither grants nor
    /// withholds. Synthetic records on chips this bench never had.
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
        require("pipeline and compact decode are one family; the phase splits are the hand-off family",
            ClusterGenerationMode.pipeline.servingFamily == .pipeline && ClusterGenerationMode.pipelineCompactDecode.servingFamily == .pipeline
                && ClusterGenerationMode.phaseSplit.servingFamily == .handOff && ClusterGenerationMode.phaseSplitMTP.servingFamily == .handOff)
        let decisions = ClusterPairServingDecisions(records: [
            // Only hand-off records: a phase-split pass opens no pipeline shape.
            record("registered_handoff", ["Apple M3 Ultra", "Apple M5 Ultra"], cuts: [8], mode: "phase_split_mtp_v1"),
            // Pipeline passed on a retired chip, hand-off on the current pair.
            record("registered_retired", ["Apple M3 Ultra", "Apple M5 Max"], cuts: [16], mode: "pipeline_v1"),
            record("registered_retired", ["Apple M3 Ultra", "Apple M5 Ultra"], cuts: [8], mode: "phase_split_v1"),
            // Pipeline passed, hand-off diverged: the pipeline family stays granted.
            record("registered_mixed", ["Apple M2 Max", "Apple M4 Max"], cuts: [12], mode: "pipeline_compact_decode_v1"),
            record("registered_mixed", ["Apple M2 Max", "Apple M4 Max"], cuts: [12], mode: "phase_split_v1", verdicts: ["diverged"]),
            // Pipeline diverged at one cut and passed at another, hand-off passed: pipeline withheld, hand-off granted.
            record("registered_cutdep", ["Apple M2 Max", "Apple M4 Max"], cuts: [4], mode: "pipeline_v1", verdicts: ["tokensEqualLogitsDiffer", "diverged"]),
            record("registered_cutdep", ["Apple M2 Max", "Apple M4 Max"], cuts: [11], mode: "pipeline_v1"),
            record("registered_cutdep", ["Apple M2 Max", "Apple M4 Max"], cuts: [11], mode: "phase_split_v1"),
            // An inconclusive pipeline record neither grants nor withholds.
            record("registered_unsure", ["Apple M2 Max", "Apple M4 Max"], cuts: [12], mode: "pipeline_v1", verdicts: ["incomparable"]),
            record("registered_unsure", ["Apple M2 Max", "Apple M4 Max"], cuts: [12], mode: "phase_split_v1"),
        ])
        func allows(_ classes: [ClusterChipClass?], _ model: String, cuts: [Int], _ mode: ClusterGenerationMode) -> Bool {
            (try? ClusterPairServingGrants.requirePlacement(classes, runtimeModelID: model, publicModelID: "p", cuts: cuts, mode: mode, decisions: decisions)) != nil
        }
        func reason(_ classes: [ClusterChipClass?], _ model: String, cuts: [Int]?, _ mode: ClusterGenerationMode?) -> String {
            do { try ClusterPairServingGrants.requirePlacement(classes, runtimeModelID: model, publicModelID: "p", cuts: cuts, mode: mode, decisions: decisions); return "allowed" }
            catch { return String(describing: error) }
        }
        require("a hand-off record grants the hand-off family", allows([m3Ultra, m5Ultra], "registered_handoff", cuts: [8], .phaseSplitMTP)
            && allows([m3Ultra, m5Ultra], "registered_handoff", cuts: [20], .phaseSplit))
        require("a hand-off record grants no pipeline shape", !allows([m3Ultra, m5Ultra], "registered_handoff", cuts: [8], .pipeline)
            && !allows([m3Ultra, m5Ultra], "registered_handoff", cuts: [8], .pipelineCompactDecode))
        require("the refusal names the mode and the families the records ran",
            reason([m3Ultra, m5Ultra], "registered_handoff", cuts: [8], .pipeline).contains("pipeline_v1")
                && reason([m3Ultra, m5Ultra], "registered_handoff", cuts: [8], .pipeline).contains("hand-off"))
        require("a placement checked without its mode is refused", reason([m3Ultra, m5Ultra], "registered_handoff", cuts: [8], nil) != "allowed")
        let handoff = try? ClusterPairServingGrants.grant(runtimeModelID: "registered_handoff", publicModelID: "p", decisions: decisions)
        require("a grant lists its families and its classes per family", handoff?.families == [.handOff]
            && handoff?.chipClasses(for: .decodingRank, family: .pipeline) == [] && handoff?.chipClasses(for: .decodingRank, family: .handOff) == [m5Ultra!])
        require("a record of a retired chip grants that chip only, in its own family",
            allows([m3Ultra, m5Max], "registered_retired", cuts: [16], .pipeline) && !allows([m3Ultra, m5Ultra], "registered_retired", cuts: [16], .pipeline)
                && allows([m3Ultra, m5Ultra], "registered_retired", cuts: [8], .phaseSplit) && !allows([m3Ultra, m5Max], "registered_retired", cuts: [8], .phaseSplit))
        require("a diverged hand-off record leaves the pipeline family granted and withholds its own",
            allows([m2Max, m4Max], "registered_mixed", cuts: [12], .pipeline) && !allows([m2Max, m4Max], "registered_mixed", cuts: [12], .phaseSplit)
                && reason([m2Max, m4Max], "registered_mixed", cuts: [12], .phaseSplit).contains("not granted pair serving")
                && decisions.withheld["registered_mixed"] == nil && decisions.granted.contains { $0.runtimeModelID == "registered_mixed" })
        let cutdep = try? ClusterPairServingGrants.grant(runtimeModelID: "registered_cutdep", publicModelID: "p", decisions: decisions)
        require("a diverged pipeline record withholds the pipeline family at every cut, and only it",
            !allows([m2Max, m4Max], "registered_cutdep", cuts: [11], .pipeline) && !allows([m2Max, m4Max], "registered_cutdep", cuts: [4], .pipeline)
                && allows([m2Max, m4Max], "registered_cutdep", cuts: [11], .phaseSplit)
                && cutdep?.families == [.handOff] && cutdep?.withheldFamilies[.pipeline]?.contains("diverged at cut 4") == true)
        require("an inconclusive record neither grants nor withholds its family",
            !allows([m2Max, m4Max], "registered_unsure", cuts: [12], .pipeline) && allows([m2Max, m4Max], "registered_unsure", cuts: [12], .phaseSplit)
                && (try? ClusterPairServingGrants.grant(runtimeModelID: "registered_unsure", publicModelID: "p", decisions: decisions))?.withheldFamilies.isEmpty == true)
        // The planner keeps to the same rule: it never plans a mode family the records did not grant on these chips.
        func plans(_ classes: [ClusterChipClass?], _ model: String, cuts: [Int], _ mode: ClusterGenerationMode) -> Bool {
            ClusterPairServingGrants.plannable(classes, cuts: cuts, mode: mode, runtimeModelID: model, decisions: decisions)
        }
        require("the planner plans only granted families on granted classes",
            plans([m3Ultra, m5Ultra], "registered_handoff", cuts: [8], .phaseSplitMTP) && !plans([m3Ultra, m5Ultra], "registered_handoff", cuts: [8], .pipeline)
                && !plans([m5Ultra, m3Ultra], "registered_handoff", cuts: [8], .phaseSplitMTP)
                && plans([m3Ultra, m5Max], "registered_retired", cuts: [24], .pipelineCompactDecode) && !plans([m3Ultra, m5Ultra], "registered_retired", cuts: [24], .pipeline))
        require("the planner keeps a withheld family to its passed shapes and leaves a classless chip to the start",
            plans([m2Max, m4Max], "registered_cutdep", cuts: [11], .pipeline) && !plans([m2Max, m4Max], "registered_cutdep", cuts: [4], .pipeline)
                && plans([nil, m5Ultra], "registered_handoff", cuts: [8], .phaseSplit) && !plans([nil, m4Max], "registered_handoff", cuts: [8], .phaseSplit) && plans([m2Max, m4Max], "registered_nobody", cuts: [3], .pipeline))
        // The shipped records: a phase-split pass on the M3 Ultra and the M5 Ultra opens no pipeline there; the 27B's
        // pipeline records on the retired M5 Max grant that chip only.
        let m3 = m3Ultra!, m5u = m5Ultra!
        let shipped27 = try? ClusterPairServingGrants.grant(runtimeModelID: "registered_qwen38_27b", publicModelID: "p")
        let pipelineOnPair = ClusterPairServingGrants.records.contains { $0.runtimeModelID == "registered_qwen38_27b" && $0.mode?.servingFamily == .pipeline
            && $0.ranks.map(\.chip) == ["Apple M3 Ultra", "Apple M5 Ultra"] && $0.passesNearTieRule }
        require("the shipped 27B grant binds each mode family to the chips its records ran",
            shipped27?.chipClasses(for: .decodingRank, family: .handOff).contains(m5u) == true
                && shipped27?.chipClasses(for: .decodingRank, family: .pipeline).contains(m5u) == pipelineOnPair
                && shipped27?.chipClasses(for: .pipelineRank, family: .pipeline).contains(m3) == true)
        // The pipeline on the M3 Ultra and the M5 Ultra, in the order each family's check ran at the planner's cut
        // (records of 2026-10-14; MiMo's of 2026-10-13); GPT-OSS and the Gemma 4 artifacts stay withheld in the pipeline.
        func servesPipeline(_ model: String, _ order: [ClusterChipClass]) -> Bool {
            (try? ClusterPairServingGrants.requirePlacement(order, runtimeModelID: model, publicModelID: "p", mode: .pipeline)) != nil
        }
        for model in ["registered_qwen35_9b", "registered_qwen38_27b", "registered_nemotron35_lightning"] {
            require("shipped: \(model) pipeline with the M3 Ultra leading the M5 Ultra only", servesPipeline(model, [m3, m5u]) && !servesPipeline(model, [m5u, m3]))
        }
        for model in ["registered_qwen35_35b_a3b", "registered_qwen36_35b_a3b", "registered_mimo_v26_flash_mopd"] {
            require("shipped: \(model) pipeline with the M5 Ultra leading the M3 Ultra only", servesPipeline(model, [m5u, m3]) && !servesPipeline(model, [m3, m5u]))
        }
        require("shipped: Bonsai pipeline in both orders (cut 32 led by the M3 Ultra, cut 56 by the M5 Ultra)",
            servesPipeline("registered_ternary_bonsai_2_27b", [m3, m5u]) && servesPipeline("registered_ternary_bonsai_2_27b", [m5u, m3]))
        for model in ["registered_gpt_oss_20b", "registered_gemma4_26b_qat_4bit", "registered_gemma4_26b_8bit"] {
            require("shipped: \(model) stays withheld", !servesPipeline(model, [m3, m5u]) && !servesPipeline(model, [m5u, m3])
                && ClusterPairServingGrants.withheld[model] != nil)
        }
    }

    /// Grants come from qualification records only, for any chips and any
    /// number of ranks: synthetic records for Macs this bench never had.
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
        let decisions = ClusterPairServingDecisions(records: [
            record("registered_dense", ["Apple M2 Max", "Apple M2 Max"], cuts: [16]),
            record("registered_dense", ["Apple M4 Pro", "Apple M3 Ultra"], cuts: [12], mode: "phase_split_v1", verdicts: ["exact", "tokensEqualLogitsDiffer"]),
            record("registered_wide", ["Apple M1 Ultra", "Apple M2 Ultra", "Apple M4 Max"], cuts: [10, 20]),
            record("registered_split", ["Apple M2 Max", "Apple M2 Max"], cuts: [16]),
            record("registered_split", ["Apple M2 Max", "Apple M2 Max"], cuts: [8], verdicts: ["divergedAtNearTie", "diverged"]),
            record("registered_unsure", ["Apple M2 Max", "Apple M2 Max"], cuts: [16], verdicts: ["incomparable"]),
            // Never used: both ranks on one Mac, a chip with no class, cuts out of order.
            record("registered_loopback", ["Apple M2 Max", "Apple M2 Max"], cuts: [16], transport: "local-socket-test"),
            record("registered_virtual", ["Apple M1 (Virtual)", "Apple M2 Max"], cuts: [16]),
            record("registered_wide", ["Apple M1 Ultra", "Apple M2 Ultra", "Apple M4 Max"], cuts: [20, 10]),
        ])
        func allows(_ classes: [ClusterChipClass?], _ model: String, _ mode: ClusterGenerationMode = .pipeline) -> Bool {
            (try? ClusterPairServingGrants.requirePlacement(classes, runtimeModelID: model, publicModelID: "p", mode: mode, decisions: decisions)) != nil
        }
        func shipped(_ classes: [ClusterChipClass?], _ model: String, _ mode: ClusterGenerationMode) -> Bool {
            (try? ClusterPairServingGrants.requirePlacement(classes, runtimeModelID: model, publicModelID: "p", cuts: [16], mode: mode)) != nil
        }
        require("two 64 GB M2 Max Macs are granted as their record ran", allows([m2Max, m2Max], "registered_dense"))
        require("an M4 Pro leading an M3 Ultra is granted in the mode family it ran, and that order only", allows([m4Pro, m3Ultra], "registered_dense", .phaseSplit)
            && !allows([m4Pro, m3Ultra], "registered_dense", .pipeline)
            && !allows([m3Ultra, m4Pro], "registered_dense", .phaseSplit) && !allows([m3Ultra, m2Max], "registered_dense", .phaseSplit))
        require("three ranks: each class reaches the role its record ran it in", allows([m1Ultra, m2Ultra, m4Max], "registered_wide")
            && allows([m2Ultra, m1Ultra, m4Max], "registered_wide") && !allows([m1Ultra, m4Max, m2Ultra], "registered_wide")
            // A grant restricts roles, not the number of ranks (cuts and modes are the coordinator's parity qualification).
            && allows([m1Ultra, m4Max], "registered_wide") && !allows([m4Max, m1Ultra], "registered_wide"))
        let wide = try? ClusterPairServingGrants.grant(runtimeModelID: "registered_wide", publicModelID: "p", decisions: decisions)
        require("a three-rank grant lists its classes per role", wide?.pipelineRankChipClasses == [m1Ultra!, m2Ultra!] && wide?.decodingRankChipClasses == [m4Max!]
            && wide?.qualifications.count == 1 && wide?.evidence.contains("1 passing cross-cable qualification record") == true)
        let split = decisions.withheld["registered_split"] ?? ""
        require("one cut that diverged withholds the model at every cut", !allows([m2Max, m2Max], "registered_split")
            && split.contains("diverged at cut 8") && split.contains("9.0 ulp") && split.contains("Apple M2 Max"))
        refuses("an undecided model is refused as having no grant", because: "has no grant") {
            try ClusterPairServingGrants.requirePlacement([m2Max, m2Max], runtimeModelID: "registered_unsure", publicModelID: "p", decisions: decisions)
        }
        require("loopback runs, classless chips and malformed cuts are never used", decisions.ignored == 3
            && !allows([m2Max, m2Max], "registered_loopback") && !allows([m2Max, m2Max], "registered_virtual"))
        require("the records this build ships all decode and are all used", !ClusterPairServingGrants.records.isEmpty
            && ClusterPairServingGrants.decisions.ignored == 0 && ClusterPairServingGrants.records.allSatisfy(\.isConsistent))
        // A grant rests on records of the installed artifact: the same records, another artifact, no grant.
        let ran = ClusterPairServingGrants.records.first { $0.runtimeModelID == "registered_qwen35_9b" }!.artifactSHA256
        require("the 9B's grant holds for the artifact its records ran", (try? ClusterPairServingGrants.grant(
            runtimeModelID: "registered_qwen35_9b", publicModelID: "p", artifactSHA256: ran)) != nil)
        refuses("another artifact of the 9B has no grant", because: "is installed as artifact 999999999999") {
            _ = try ClusterPairServingGrants.grant(runtimeModelID: "registered_qwen35_9b", publicModelID: "p", artifactSHA256: hash("9"))
        }
        refuses("a rank of another artifact is refused", because: "its cross-cable qualification records ran only") {
            try ClusterPairServingGrants.requireRank(0, of: 2, chipClass: m3Ultra, runtimeModelID: "registered_qwen35_9b",
                publicModelID: "p", artifactSHA256: hash("9"), cuts: [4], mode: .pipeline)
        }
        // One artifact is one model: a record labelled with one model that ran another model's artifact (the two
        // registered_gemma4_26b records that ran the 8-bit artifact) is not shipped.
        let owners = Dictionary(grouping: ClusterPairServingGrants.records, by: \.artifactSHA256).mapValues { Set($0.map(\.runtimeModelID)) }
        require("no shipped artifact is recorded under two registered models", owners.values.allSatisfy { $0.count == 1 })
        require("the shipped records grant the 9B with the M3 Ultra leading, from records only",
            shipped([m3Ultra, cls("Apple M5 Ultra")], "registered_qwen35_9b", .phaseSplitMTP) && !shipped([cls("Apple M5 Ultra"), m3Ultra], "registered_qwen35_9b", .phaseSplitMTP))
    }
}
