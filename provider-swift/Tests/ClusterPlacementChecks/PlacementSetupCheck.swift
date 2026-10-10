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

    static func main() throws {
        if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "flow" {
            do { try flow(Array(CommandLine.arguments.dropFirst(2))) } catch {
                FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1)
            }
            return
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
            arithmeticPolicyID: "qwen_cbv2_query128_bf16_tf32_default_v1", arithmeticPolicySHA256: hash("5"), maxLifetimeSeconds: 300,
            maxRequests: 16, supportedPrefillSchedules: [.serial, .oneChunkLookahead], supportedGenerationModes: ClusterGenerationMode.allCases)
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
        require("each setup carries its own member's trust files", one.trust.identityFile.hasSuffix("mac-one") && two.trust.identityFile.hasSuffix("mac-two"))
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
        guard failures.isEmpty else {
            for failure in failures { FileHandle.standardError.write(Data("FAIL: \(failure)\n".utf8)) }
            exit(1)
        }
        print("placement setup checks passed: \(passed)")
    }
}
