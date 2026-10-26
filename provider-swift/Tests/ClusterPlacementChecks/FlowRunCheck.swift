import Darwin
import DarkbloomClusterPlacement
import DarkbloomClusterProcess
import DarkbloomClusterProtocol
import Foundation
@testable import InstalledContract

/// The whole guided step on one Mac, with a stand-in for the installed plan
/// tool: the two child commands, the decision and the files it writes.
@main @MainActor struct FlowRunCheck {
    static func hash(_ character: Character) -> String { String(repeating: String(character), count: 64) }
    static let gib = 1_073_741_824
    static func profile(physicalGiB: Int, freeGiB: Int) throws -> ClusterDeviceProfile {
        let physical = physicalGiB * gib, free = freeGiB * gib
        return try .init(chip: "Check chip \(physicalGiB)", performanceCores: 8, efficiencyCores: 4, gpuCores: nil, osVersion: "27.0",
            osBuild: "CHECK", physicalMemoryBytes: physical, gpuRecommendedWorkingSetBytes: physical / 4 * 3,
            gpuMaximumBufferBytes: physical / 2, allocatorLimitBytes: physical / 10 * 9,
            memory: .init(gatePolicy: "check", sampledUTC: "2026-10-09T00:00:00Z", judged: true, unjudgedReason: nil,
                physicalMemoryBytes: physical, actualFreeBytes: free, countedFileCacheBytes: 0, admissibleNowBytes: free,
                fileBackedBytes: 0, fileCacheReserveBytes: 0, fileCacheAboveReserveBytes: 0, anonymousBytes: physical - free - 4 * gib,
                wiredBytes: 4 * gib, compressorBytes: 0, pageableBytes: physical - 4 * gib, pressureLevel: 1, swapUsedBytes: 0,
                minimumAdmissibleBytes: 6 * gib, minimumTrulyFreeBytes: 16 * 1_048_576, loadingHeadroomBytes: 4 * gib,
                allocatorHeadroomBytes: 2 * gib, loadScratchBytes: 8 * 1_048_576, pageSizeBytes: 16_384),
            power: .init(onExternalPower: true, lowPowerMode: false, thermalState: "nominal"))
    }

    static func main() throws {
        var failures: [String] = [], passed = 0
        func require(_ name: String, _ value: Bool) { if value { passed += 1 } else { failures.append(name) } }
        // The strict readers refuse symlinked path components, so the fixture lives under the checkout.
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("placement-flow-check-" + UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ name: String, _ data: Data, mode: Int = 0o600) throws -> URL {
            let url = root.appendingPathComponent(name)
            try data.write(to: url); try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
            return url
        }
        let part = ClusterModelLayout.Part(storedBytes: gib / 8, loadedBytes: gib / 8, largestTensorBytes: gib / 16, tensorCount: 30)
        let layout = ClusterModelLayout(runtimeModelID: "registered_qwen35_9b", artifactSHA256: hash("b"), configurationSHA256: hash("c"),
            layers: (0..<32).map { .init(index: $0, kind: "block", weights: part, stateFixedBytes: 1_000_000, stateBytesPerToken: 1024, cost: 1) },
            ingress: .init(storedBytes: gib / 2, loadedBytes: gib / 2, largestTensorBytes: gib / 2, tensorCount: 3),
            egress: .init(storedBytes: gib / 2, loadedBytes: gib / 2, largestTensorBytes: gib / 2, tensorCount: 3),
            excluded: .init(), admittedCuts: [4, 8, 12, 16], structuralCuts: [4, 8, 12, 16, 20, 24, 28],
            generationModes: [.pipeline], prefillSchedules: [.serial], maximumPromptTokens: 8192, maximumOutputTokens: 128,
            maximumChunkTokens: 512, boundaryBytesPerToken: 8192, requestChargeEveryRankBytes: 700_000_000)
        func partition(_ cut: Int, _ id: Character) -> ClusterRuntimePartition {
            .init(planSHA256: hash(id), stages: [
                .init(rank: 0, sourceLayerStart: 0, sourceLayerEnd: cut, stagePlanSHA256: String(repeating: "1", count: 62) + String(format: "%02d", cut),
                      constructionConfigurationSHA256: hash("2")),
                .init(rank: 1, sourceLayerStart: cut, sourceLayerEnd: 32, stagePlanSHA256: String(repeating: "3", count: 62) + String(format: "%02d", cut),
                      constructionConfigurationSHA256: hash("4"))])
        }
        let capability = try ClusterRuntimeCapability(runtimeBinarySHA256: hash("a"), adapterID: "qwen35-dense-layer-stage", adapterVersion: 1,
            runtimeModelID: "registered_qwen35_9b", artifactSHA256: hash("b"), configurationSHA256: hash("c"), manifestSHA256: hash("d"),
            profile: .init(id: "registered_qwen35_9b_greedy_generation_v1", vocabularySize: 248320, maximumPromptTokens: 32768,
                maximumOutputTokens: 32768, maximumChunkTokens: 512, maximumContextTokens: 65536),
            profileFingerprint: hash("e"), partitions: [partition(4, "6"), partition(8, "7"), partition(12, "8"), partition(16, "9")],
            arithmeticPolicyID: "qwen_cbv2_query128_bf16_tf32_default_v1", arithmeticPolicySHA256: hash("5"))
        let capabilityData = try ClusterRuntimeCapabilityCodec.encode(capability)
        let capabilityURL = try write("capability.json", capabilityData)
        let capabilityHash = ClusterConfigurationCodec.sha256(capabilityData)
        // The stand-in for the installed tool prints this Mac's profile and the layout, as the real one does.
        _ = try write("local-profile.json", try profile(physicalGiB: 256, freeGiB: 200).encoded())
        _ = try write("layout.json", try layout.encoded())
        for (prompt, output) in [(1024, 2048), (16384, 128)] {
            let scope = try ClusterPlacementRequestScope(runtimeModelID: layout.runtimeModelID,
                artifactSHA256: layout.artifactSHA256, configurationSHA256: layout.configurationSHA256,
                promptTokens: prompt, outputTokens: output, maximumPromptTokens: 32768,
                maximumOutputTokens: 32768, maximumContextTokens: 65536, requestChargeEveryRankBytes: 900_000_000)
            _ = try write("scope-\(prompt)-\(output).json", JSONEncoder().encode(scope))
        }
        let tool = """
            #!/bin/sh
            case "$1" in
              device) echo "$*" >> "\(root.path)/device-calls.txt"; exec /bin/cat "\(root.path)/local-profile.json" ;;
              layout) [ "$3" = /Users/fixture/model ] && exec /bin/cat "\(root.path)/layout.json" ;;
              request-scope) [ "$3" = /Users/fixture/model ] && [ "$4" = --prompt-tokens ] && [ "$6" = --output-tokens ] && exec /bin/cat "\(root.path)/scope-$5-$7.json" ;;
            esac
            exit 9

            """
        _ = try write(ClusterPlacementFlow.toolName, Data(tool.utf8), mode: 0o700)
        let peerProfile = try write("peer-profile.json", try profile(physicalGiB: 16, freeGiB: 9).encoded())
        func member(_ id: String, _ address: String, worker: String) -> [String: Any] {
            ["id": id, "host": id + ".local", "port": 22, "user": "fixture", "ownerExecutable": "/Users/fixture/bin/darkbloom",
             "workerExecutable": worker, "modelDirectory": "/Users/fixture/model", "runtimeBinarySHA256": hash("a"),
             "jacclDevice": "rdma_en1", "linkAddress": address,
             "trust": ["identityFile": "/Users/fixture/keys/\(id)", "knownHostsFile": "/Users/fixture/keys/\(id).hosts", "knownHostsSHA256": hash("f")]]
        }
        let description: [String: Any] = ["schema": ClusterPairDescription.schemaName, "clusterID": "fixture", "publicModelID": "fixture/qwen",
            "capabilitySHA256": capabilityHash, "chunkTokens": 512, "requestTimeoutSeconds": 300, "coordinatorPort": 12345,
            "members": [member("mac-one", "192.0.2.1", worker: root.appendingPathComponent("darkbloom-cluster-worker").path),
                        member("mac-two", "192.0.2.2", worker: "/Users/fixture/bin/darkbloom-cluster-worker")],
            "tokenizerFiles": [["path": "tokenizer.json", "sha256": hash("6"), "purpose": "tokenizer"]]]
        let pair = try write("pair.json", JSONSerialization.data(withJSONObject: description))
        func deadline() -> UInt64 { DispatchTime.now().uptimeNanoseconds + 20_000_000_000 }

        let output = root.appendingPathComponent("out", isDirectory: true)
        let outcome = try ClusterPlacementFlow.run(.init(pairDescription: pair, capability: capabilityURL, capabilitySHA256: capabilityHash,
            localMemberID: "mac-one", peerProfile: peerProfile, output: output), deadline: deadline())
        require("the step detects through the installed tool, plans and writes a setup per Mac and the plan",
            outcome.setup != nil && Set(outcome.written.map(\.lastPathComponent)) == ["mac-one.setup.json", "mac-two.setup.json", "plan.txt"])
        var information = stat()
        require("the output directory and its files are the owner's alone",
            stat(output.path, &information) == 0 && information.st_mode & 0o777 == 0o700
                && stat(output.appendingPathComponent("mac-one.setup.json").path, &information) == 0 && information.st_mode & 0o777 == 0o600)
        let one = try ClusterConfigurationCodec.decode(Data(contentsOf: output.appendingPathComponent("mac-one.setup.json")),
            capability: capability, capabilitySHA256: capabilityHash)
        // The peer admits 9 GiB: it takes a range it can hold, whichever that makes the leader.
        require("each written setup is one the strict codec accepts, and the Mac that admits little holds what it can",
            one.memberID == "mac-one" && (outcome.result.chosen?.ranks.allSatisfy { $0.fit == .now } ?? false)
                && (outcome.result.chosen?.ranks.first { $0.device == "mac-two" }?.needBytes ?? .max) <= 9 * gib)
        require("the printed lines say what was detected, what each Mac holds and what happens next",
            outcome.lines.contains("What each Mac detected") && outcome.lines.contains { $0.contains("While the session is up") }
                && outcome.lines.contains("What happens next") && outcome.lines.contains { $0.contains("Wrote a setup for each Mac") })
        func deviceCalls() -> [String] {
            ((try? String(contentsOf: root.appendingPathComponent("device-calls.txt"), encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }
        require("with no model loaded here, this Mac's profile measures its speed index", deviceCalls() == ["device --json --index"])
        var beside = ClusterPlacementFlow.Inputs(pairDescription: pair, capability: capabilityURL, capabilitySHA256: capabilityHash,
            localMemberID: "mac-one", peerProfile: peerProfile, output: root.appendingPathComponent("beside-out"))
        beside.modelLoaded = true
        let besideOutcome = try ClusterPlacementFlow.run(beside, deadline: deadline())
        require("beside a loaded model the step plans the same and runs no GPU benchmark",
            besideOutcome.setup != nil && besideOutcome.result.chosen?.cuts == outcome.result.chosen?.cuts
                && deviceCalls() == ["device --json --index", "device --json"])

        // The leader's served-speed file, as the product writes it: records of this pair and model from before builds
        // were recorded (no `rankBuildSHA256`), from another worker build, and from the build the pair description
        // names (hash "a", the capability's). Only the last are calibrated; the plan counts the others in one line.
        // What clients sent is no build's: every record's lengths make the plan's request.
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cluster = home.appendingPathComponent(".darkbloom/cluster", isDirectory: true)
        try FileManager.default.createDirectory(at: cluster, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        func served(_ id: String, prompt: Int, output: Int, builds: [String]?) -> [String: Any] {
            var record: [String: Any] = ["requestID": id, "finishedAt": 1_792_900_000, "modelID": "fixture/qwen", "mode": "pipeline_v1",
                "cut": "0-8|8-32", "promptTokens": prompt, "cachedTokens": 0, "completionTokens": output, "firstTokenMilliseconds": 500,
                "decodeTokensPerSecond": 40, "outcome": "length", "ranks": ["mac-one", "mac-two"], "concurrentRequests": 0]
            if let builds { record["rankBuildSHA256"] = builds }
            return record
        }
        let stale = (0..<3).map { served("old-\($0)", prompt: 4_000, output: 64, builds: nil) }
            + (0..<2).map { served("other-\($0)", prompt: 4_000, output: 64, builds: [hash("9"), hash("9")]) }
        let current = [(64, 100), (128, 120), (96, 110)].enumerated().map { served("now-\($0.offset)", prompt: $0.element.0,
            output: $0.element.1, builds: [hash("a"), hash("a")]) }
        // Darkbloom's own checks of the pair (the warm-up canary's 8 tokens, the onboarding's 48-token test answer), as
        // an earlier build kept them: probe-sized (`ClusterServedSpeedRule`), so neither a speed nor a request length.
        let probes = [8, 48].map { served("probe-\($0)", prompt: 30, output: $0, builds: [hash("a"), hash("a")]) }
        let servedFile = cluster.appendingPathComponent("served-speed.json")
        func writeServed(_ records: [[String: Any]]) throws {
            try JSONSerialization.data(withJSONObject: ["schema": "darkbloom_served_speed_v1", "updatedAt": 1_792_900_001,
                "records": records], options: [.sortedKeys]).write(to: servedFile)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: servedFile.path)
        }
        func planned(_ name: String) throws -> ClusterPlacementFlow.Outcome {
            try ClusterPlacementFlow.run(.init(pairDescription: pair, capability: capabilityURL, capabilitySHA256: capabilityHash,
                localMemberID: "mac-one", peerProfile: peerProfile, output: root.appendingPathComponent(name)), deadline: deadline())
        }
        try writeServed(stale + current + probes)
        let scoped = try planned("served-out")
        let ignoredLine = "  5 record(s) from other worker builds ignored: a served speed counts only for the build that served it (this plan is for worker build aaaaaaaaaaaa)"
        require("the step reads the leader's served-speed file and calibrates this build's three records only",
            scoped.lines.contains { $0.contains("pipeline_v1 cut 0-8|8-32 (mac-one, mac-two): 3 pair and 0 alone request(s) ->") }
                && !scoped.lines.contains { $0.contains("8 pair and 0 alone request(s)") })
        require("the plan says in one line that the records of other worker builds (and from before builds were recorded) were ignored, and writes it to plan.txt",
            scoped.lines.contains("Speed records from served requests") && scoped.lines.contains(ignoredLine)
                && (try? String(contentsOf: root.appendingPathComponent("served-out/plan.txt"), encoding: .utf8))?.contains(ignoredLine) == true)
        require("every build's records make the plan's request, what clients sent (median 4000-token prompt, 64-token answer; got \(scoped.result.promptTokens)/\(scoped.result.outputTokens), \(outcome.result.promptTokens)/\(outcome.result.outputTokens) unserved)",
            scoped.result.promptTokens == 4_000 && scoped.result.outputTokens == 64 && outcome.result.promptTokens == layout.maximumPromptTokens)
        try writeServed(stale)
        let staleOnly = try planned("stale-out")
        require("with only other builds' records nothing is calibrated, the request is still theirs, and the plan says why",
            !staleOnly.lines.contains { $0.contains("request(s) ->") } && staleOnly.lines.contains { $0.hasPrefix("  5 record(s) from other worker builds ignored") }
                && staleOnly.result.promptTokens == 4_000 && staleOnly.result.outputTokens == 64)
        try FileManager.default.removeItem(at: servedFile)
        func refused(_ name: String, because reason: String, _ body: () throws -> Void) {
            do { try body(); failures.append("accepted: " + name) } catch {
                if String(describing: error).contains(reason) { passed += 1 } else { failures.append("\(name): \(error)") }
            }
        }
        let pairValue = try ClusterPairDescription.decode(JSONSerialization.data(withJSONObject: description))
        for (prompt, generated) in [(1024, 2048), (16384, 128)] {
            var inputs = ClusterPlacementFlow.Inputs(pairDescription: pair, capability: capabilityURL, capabilitySHA256: capabilityHash,
                localMemberID: "mac-one", peerProfile: peerProfile, output: root.appendingPathComponent("extended-\(prompt)-\(generated)"))
            inputs.promptTokens = prompt; inputs.outputTokens = generated
            let extended = try ClusterPlacementFlow.run(inputs, deadline: deadline())
            require("run requests and applies exact family quote for \(prompt)/\(generated)", extended.setup != nil
                && extended.result.chosen?.ranks.allSatisfy { $0.requestNeedBytes >= 900_000_000 } == true)
            let quoteURL = root.appendingPathComponent("scope-\(prompt)-\(generated).json")
            let quote = try ClusterPlacementRequestScope.decode(Data(contentsOf: quoteURL))
            let local = try profile(physicalGiB: 256, freeGiB: 200), peer = try profile(physicalGiB: 16, freeGiB: 9)
            refused("pure decision cannot extend an unquoted layout", because: "profile's limits") {
                _ = try ClusterPlacementFlow.decide(description: pairValue, capability: capability, localMemberID: "mac-one",
                    localProfile: local, peerProfile: peer, layout: layout, promptTokens: prompt, outputTokens: generated)
            }
            let direct = try ClusterPlacementFlow.decide(description: pairValue, capability: capability, localMemberID: "mac-one",
                localProfile: local, peerProfile: peer, layout: layout, promptTokens: prompt, outputTokens: generated, requestScope: quote)
            require("pure decision and installed helper flow agree on the quote", direct.result.chosen?.cuts == extended.result.chosen?.cuts
                && direct.result.chosen?.ranks.map(\.requestNeedBytes) == extended.result.chosen?.ranks.map(\.requestNeedBytes))
            refused("quote for another output shape is refused before writing setup", because: "another model or request") {
                _ = try ClusterPlacementFlow.decide(description: pairValue, capability: capability, localMemberID: "mac-one",
                    localProfile: local, peerProfile: peer, layout: layout, promptTokens: prompt, outputTokens: generated + 1, requestScope: quote)
            }
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(quote)) as! [String: Any]
            object["maximumOutputTokens"] = 16384
            let mismatched = try ClusterPlacementRequestScope.decode(JSONSerialization.data(withJSONObject: object))
            refused("helper quote must match pinned worker family bounds", because: "different profile limits") {
                _ = try ClusterPlacementFlow.decide(description: pairValue, capability: capability, localMemberID: "mac-one",
                    localProfile: local, peerProfile: peer, layout: layout, promptTokens: prompt, outputTokens: generated, requestScope: mismatched)
            }
            // Prove the whole child-process route also refuses mismatched metadata
            // before creating output, rather than trusting a helper's bounds.
            try JSONEncoder().encode(mismatched).write(to: quoteURL)
            inputs.output = root.appendingPathComponent("mismatched-\(prompt)")
            refused("run rejects a mismatched quote", because: "different profile limits") {
                _ = try ClusterPlacementFlow.run(inputs, deadline: deadline())
            }
            require("refused quote produces no output directory", !FileManager.default.fileExists(atPath: inputs.output.path))
            try JSONEncoder().encode(quote).write(to: quoteURL)
        }
        refused("an output directory that exists is not written into", because: "must not exist yet") {
            _ = try ClusterPlacementFlow.run(.init(pairDescription: pair, capability: capabilityURL, capabilitySHA256: capabilityHash,
                localMemberID: "mac-one", peerProfile: peerProfile, output: output), deadline: deadline())
        }
        refused("a Mac without the tool beside its worker is told so", because: "is not installed beside this Mac's worker") {
            _ = try ClusterPlacementFlow.run(.init(pairDescription: pair, capability: capabilityURL, capabilitySHA256: capabilityHash,
                localMemberID: "mac-two", peerProfile: peerProfile, output: root.appendingPathComponent("out2")), deadline: deadline())
        }
        refused("a capability record other than the pinned one is refused", because: "digest differs") {
            _ = try ClusterPlacementFlow.run(.init(pairDescription: pair, capability: capabilityURL, capabilitySHA256: hash("0"),
                localMemberID: "mac-one", peerProfile: peerProfile, output: root.appendingPathComponent("out3")), deadline: deadline())
        }
        // The other Mac's profile over the pinned route: the command line, without running it.
        let identity = try write("identity", Data("not a key".utf8)), hosts = try write("known-hosts", Data("not a host key\n".utf8))
        func routed(peerWorker: String, identityFile: String = identity.path) throws -> ClusterPairDescription {
            var one = member("mac-one", "192.0.2.1", worker: root.appendingPathComponent("darkbloom-cluster-worker").path)
            one["trust"] = ["identityFile": identityFile, "knownHostsFile": hosts.path, "knownHostsSHA256": hash("f")]
            var value = description
            value["members"] = [one, member("mac-two", "192.0.2.2", worker: peerWorker)]
            return try ClusterPairDescription.decode(JSONSerialization.data(withJSONObject: value))
        }
        let route = try routed(peerWorker: "/Users/fixture/bin/darkbloom-cluster-worker")
        let command = try ClusterPlacementFlow.peerProfileCommand(local: route.members[0], peer: route.members[1])
        func option(_ value: String) -> Bool {
            zip(command.arguments, command.arguments.dropFirst()).contains { $0 == "-o" && $1 == value }
        }
        require("the other Mac is asked by OpenSSH for its plan tool's device profile and nothing else",
            command.executable.path == "/usr/bin/ssh" && command.arguments.last == "exec /Users/fixture/bin/darkbloom-cluster-plan device --json"
                && command.arguments.suffix(3).first == "--" && command.arguments.suffix(2).first == "mac-two.local")
        require("the route is the installed session's pinned one: this member's identity and known-hosts file, no agent, no prompt",
            option("BatchMode=yes") && option("StrictHostKeyChecking=yes") && option("UserKnownHostsFile=\(hosts.path)")
                && option("IdentitiesOnly=yes") && option("IdentityAgent=none") && option("PasswordAuthentication=no")
                && option("GlobalKnownHostsFile=/dev/null") && command.arguments.prefix(2) == ["-F", "/dev/null"]
                && zip(command.arguments, command.arguments.dropFirst()).contains { $0 == "-i" && $1 == identity.path }
                && zip(command.arguments, command.arguments.dropFirst()).contains { $0 == "-l" && $1 == "fixture" })
        refused("a peer installation path a remote shell could read as more than a path is refused", because: "Unsafe SSH configuration") {
            let unsafe = try routed(peerWorker: "/Users/fixture/bin; touch x/darkbloom-cluster-worker")
            _ = try ClusterPlacementFlow.peerProfileCommand(local: unsafe.members[0], peer: unsafe.members[1])
        }
        refused("an identity file that is not this user's own regular file is refused before anything connects", because: "Unsafe configured SSH trust file") {
            let missing = try routed(peerWorker: "/Users/fixture/bin/darkbloom-cluster-worker", identityFile: root.appendingPathComponent("absent").path)
            _ = try ClusterPlacementFlow.peerProfileCommand(local: missing.members[0], peer: missing.members[1])
        }
        refused("without a profile file the step asks the other Mac, and says so when the trust files are not usable", because: "Unsafe configured SSH trust file") {
            _ = try ClusterPlacementFlow.run(.init(pairDescription: pair, capability: capabilityURL, capabilitySHA256: capabilityHash,
                localMemberID: "mac-one", output: root.appendingPathComponent("out4")), deadline: deadline())
        }
        guard failures.isEmpty else {
            for failure in failures { FileHandle.standardError.write(Data("FAIL: \(failure)\n".utf8)) }
            exit(1)
        }
        print("placement flow run checks passed: \(passed)")
    }
}
