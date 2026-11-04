import DarkbloomClusterPlacement
@testable import DarkbloomClusterRuntime
import DarkbloomClusterProtocol
import Foundation
import Testing
@testable import ProviderCore

/// The width the registered Qwen3.8 27B saves on idle pairs of each size: its retained headers, LOAD's own quote at
/// every width (`ClusterPlacementArtifact.tensorBatchQuote`, as `tensor-batch-scope` derives it) and the guided step's
/// own decision (`ClusterPlacementFlow.decide`), plain (a pair served through Darkbloom) and with the depth-3 assistant
/// (a local pair). The vision tower's resident bytes are left out, as the served layout leaves them. Header metadata
/// only: no model, no GPU.
struct ClusterPlacementTensorWidthRegisteredTests {
    private struct Retained: Decodable {
        struct Tensor: Decodable { let name: String; let shape: [Int]; let sourceDType: String; let byteCount: Int }
        struct Profile: Decodable { let configuration: Data; let canonicalTensors: [Tensor] }
        let twentySeven: Profile
    }
    private struct Assistant: Decodable {
        struct Tensor: Decodable { let name: String; let shape: [Int]; let dtype: String; let byteCount: Int }
        let tensors: [Tensor]
    }
    private static let gib = 1 << 30
    private static func bound(_ bytes: Int) -> Int { ((bytes + 16_383) / 16_384) * 16_384 }
    private static func hash(_ c: Character) -> String { String(repeating: String(c), count: 64) }

    /// An idle Mac of `physicalGiB`, as the placement checks construct one (`SyntheticMac.idle`): wired 3 % (at least
    /// 2.5 GiB), other programs 4 % (at least 3 GiB), 1 GiB of file cache, the rest free.
    private static func idle(_ physicalGiB: Double) throws -> ClusterDeviceProfile {
        let page = 16_384
        func pages(_ value: Double) -> Int { Int((value * Double(gib) / Double(page)).rounded()) }
        let wiredGiB = max(2.5, physicalGiB * 0.03), otherGiB = max(3, physicalGiB * 0.04)
        let physical = pages(physicalGiB), wired = pages(wiredGiB), free = pages(physicalGiB - wiredGiB - otherGiB - 1)
        let cache = pages(1), pageable = physical - wired, anonymous = max(0, pageable - free - cache)
        let observation = QwenDenseStageLoadOSObservation(startedNanoseconds: 900, completedNanoseconds: 1_000,
            timestampUTC: "2026-11-01T00:00:00Z", physicalMemoryBytes: physical * page, pageSizeBytes: page,
            kernelFreePages: free, freePages: free, inactivePages: cache + anonymous / 2, speculativePages: 0,
            actualFreeBytes: free * page, estimatedReclaimableBytes: (free + cache + anonymous / 2) * page, pressureLevel: 1,
            swapUsedBytes: 0, activePages: anonymous - anonymous / 2, fileBackedPages: cache, anonymousPages: anonymous,
            wiredPages: wired, purgeablePages: 0, compressorPages: 0, kernelFileCacheMinimumPages: nil,
            inactiveFileBackedPages: cache, inactiveAnonymousPages: anonymous / 2, compressionPages: 0, swapoutPages: 0,
            liveCompressionPages: 0)
        let bytes = physical * page, workingSet = bytes / 4 * 3
        var profile = try ClusterDeviceProfile(chip: "Synthetic", performanceCores: 8, efficiencyCores: 4, gpuCores: nil,
            osVersion: "27.0", osBuild: "SYNTH", physicalMemoryBytes: bytes, gpuRecommendedWorkingSetBytes: workingSet,
            gpuMaximumBufferBytes: bytes / 2, allocatorLimitBytes: min(workingSet / 2 * 3, bytes / 100 * 95),
            memory: .gate(observation, now: 1_100),
            power: .init(onExternalPower: true, lowPowerMode: false, thermalState: "nominal"))
        profile.speedIndex = .init(chip: profile.chip, osBuild: profile.osBuild, benchmark: "qmm_h4096_b4_g64_x16_v1",
            prefillIndex: 1_000_000, decodeIndex: 25_000)
        return profile
    }

    private struct Registered {
        let layout: ClusterModelLayout
        let capability: ClusterRuntimeCapability
        let pair: ClusterPairDescription
        /// Each kind's quotes by width, 1 through 8.
        let plain: [Int: ClusterPlacementTensorBatchQuote]
        let assisted: [Int: ClusterPlacementTensorBatchQuote]
    }

    private static func registered() throws -> Registered {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("libs/darkbloom-cluster/Tests", isDirectory: true)
        let retained = try JSONDecoder().decode(Retained.self, from: Data(contentsOf: tests
            .appendingPathComponent("StageMetadataChecks/Inputs/qwen-retained-inputs.json"))).twentySeven
        let family = try QwenDensePlacementFamily(configuration: retained.configuration), p = family.profile
        let plan = try #require(family.tensorParallel)
        let text = retained.canonicalTensors.map {
            ClusterPlacementStoredTensor(name: $0.name, byteCount: $0.byteCount, dtype: $0.sourceDType, shape: $0.shape)
        }
        let head = try JSONDecoder().decode(Assistant.self, from: Data(contentsOf: tests
            .appendingPathComponent("DarkbloomClusterRuntimeTests/Inputs/qwen27-tp-mtp-inventory.json"))).tensors.map {
            ClusterPlacementStoredTensor(name: $0.name, byteCount: $0.byteCount, dtype: $0.dtype, shape: $0.shape)
        }
        var planning = family
        planning.tensorParallelRequestAllowance = try QwenTensorParallelRequestBudget.derive(geometry: family.geometry,
            plan: plan, tensors: family.requireRegisteredInventory(text), maximumTokens: family.largestContextTokens,
            chunkSize: family.maximumChunkTokens, allocationBound: bound).allowance
        let specification = family.definition.specification
        var object = try JSONSerialization.jsonObject(with: ClusterModelLayoutBuilder.build(family: planning,
            tensors: text + head, artifactSHA256: specification.artifactSHA256,
            configurationSHA256: specification.configurationSHA256).encoded()) as! [String: Any]
        let listed = (object["generationModes"] as? [String] ?? []) + [ClusterGenerationMode.tensorParallel.rawValue]
        object["generationModes"] = ClusterGenerationMode.allCases.map(\.rawValue).filter(listed.contains)
        let layout = try ClusterModelLayout.decode(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
        let request = try ClusterPlacementRequestScope(runtimeModelID: family.runtimeModelID,
            artifactSHA256: specification.artifactSHA256, configurationSHA256: specification.configurationSHA256,
            promptTokens: p.maximumPromptTokens, outputTokens: p.maximumOutputTokens, maximumPromptTokens: p.maximumPromptTokens,
            maximumOutputTokens: p.maximumOutputTokens, maximumContextTokens: p.maximumContextTokens,
            requestChargeEveryRankBytes: family.requestChargeEveryRankBytes(contextTokens: p.maximumPromptTokens + p.maximumOutputTokens))
        func quotes(_ depth: Int?) throws -> [Int: ClusterPlacementTensorBatchQuote] {
            try Dictionary(uniqueKeysWithValues: [1, 2, 4, 6, 8].map { lanes in
                (lanes, try ClusterPlacementArtifact.tensorBatchQuote(configuration: retained.configuration, stored: text + head,
                    request: request, chunkTokens: p.maximumChunkTokens, lanes: lanes, assistantDepth: depth,
                    assistantVerification: depth == nil ? .singleton : .admittedCohort, allocationBound: bound))
            })
        }
        let partitions = layout.admittedCuts.enumerated().map { index, cut in
            ClusterRuntimePartition(planSHA256: String(format: "%064lx", index + 1), stages: [
                .init(rank: 0, sourceLayerStart: 0, sourceLayerEnd: cut, stagePlanSHA256: String(format: "%064lx", 100 + index),
                      constructionConfigurationSHA256: hash("2")),
                .init(rank: 1, sourceLayerStart: cut, sourceLayerEnd: layout.layerCount, stagePlanSHA256: String(format: "%064lx", 200 + index),
                      constructionConfigurationSHA256: hash("4"))])
        }
        let capability = try ClusterRuntimeCapability(runtimeBinarySHA256: hash("a"), adapterID: "qwen35-dense-layer-stage",
            adapterVersion: 1, runtimeModelID: layout.runtimeModelID, artifactSHA256: layout.artifactSHA256,
            configurationSHA256: layout.configurationSHA256, manifestSHA256: hash("d"),
            profile: .init(id: "registered_qwen38_27b_greedy_generation_v1", vocabularySize: 248320,
                maximumPromptTokens: p.maximumPromptTokens, maximumOutputTokens: p.maximumOutputTokens,
                maximumChunkTokens: p.maximumChunkTokens, maximumContextTokens: p.maximumContextTokens),
            profileFingerprint: hash("e"), partitions: partitions, arithmeticPolicyID: "qwen_cbv2_query128_bf16_tf32_default_v1",
            arithmeticPolicySHA256: hash("5"), supportedGenerationModes: [.pipeline, .tensorParallel])
        let pair = ClusterPairDescription(schema: ClusterPairDescription.schemaName, clusterID: "fixture-cluster",
            publicModelID: "EigenLabs/Qwen3.8-27B-4bit-mtp",
            capabilitySHA256: ClusterConfigurationCodec.sha256(try ClusterRuntimeCapabilityCodec.encode(capability)),
            chunkTokens: p.maximumChunkTokens, requestTimeoutSeconds: 315, coordinatorPort: 5577,
            members: ["a", "b"].enumerated().map { index, id in
                .init(id: id, host: "192.0.2.\(index + 1)", port: 22, user: "fixture",
                    ownerExecutable: "/fixture/darkbloom", workerExecutable: "/fixture/worker", modelDirectory: "/fixture/model",
                    runtimeBinarySHA256: hash("a"), jacclDevice: "en7", linkAddress: "192.0.2.\(index + 1)", trust: nil,
                    linkSecretFile: "/fixture/\(id).secret")
            }, tokenizerFiles: [.init(path: "tokenizer.json", sha256: hash("6"), purpose: .tokenizer)],
            linkControl: .init(port: 5578, linkEpoch: UUID().uuidString.lowercased(), edgeID: UUID().uuidString.lowercased()))
        return .init(layout: layout, capability: capability, pair: pair, plain: try quotes(nil), assisted: try quotes(3))
    }

    @Test func twoM5UltrasSaveEightAndSmallerPairsTheWidestTheirQuoteAdmits() throws {
        let model = try Self.registered()
        let link = ClusterLinkCosts(measured: true, perChunkSeconds: 0.002, perDecodeStepSeconds: [:],
            handoffSecondsPerByte: 1 / 2e9, provenance: "constructed for a check",
            reduction: .init(fixedSeconds: 1e-6, secondsPerByte: 1 / 5e9, keyed: true, provenance: "constructed for a check"))
        for (kind, quotes) in [("plain", model.plain), ("assistant", model.assisted)] {
            let singleton: ClusterPlacementTensorBatchQuote = try #require(quotes[1])
            for lanes in [1, 2, 4, 6, 8] {
                let quote: ClusterPlacementTensorBatchQuote = try #require(quotes[lanes])
                print("qwen27-tp-width-quote kind=\(kind) lanes=\(lanes) request_bytes=\(quote.allowance.requestBytesExcludingCollectives)"
                    + " reserved_bytes=\(quote.allowance.reservedBytes) per_lane_bytes=\(quote.perLaneStateBytes)"
                    + " rank0_equal_bytes=\(quote.rankReservedBytes(rank: 0, shares: nil) ?? -1)"
                    + " rank1_equal_bytes=\(quote.rankReservedBytes(rank: 1, shares: nil) ?? -1)")
            }
            /// The width a pair of these two idle Macs saves (1: none), or nil when tensor parallel is not placed.
            func saved(_ localGiB: Double, _ peerGiB: Double) throws -> Int? {
                let decided = try ClusterPlacementFlow.decide(description: model.pair, capability: model.capability,
                    localMemberID: "a", localProfile: try Self.idle(localGiB), peerProfile: try Self.idle(peerGiB), layout: model.layout,
                    tensorAssistantQuote: singleton, tensorWidthQuotes: [2, 4, 6, 8].compactMap { quotes[$0] },
                    leader: "a", link: link, environment: [:], benchDebugBuild: false)
                guard let chosen = decided.result.chosen, chosen.mode == .tensorParallel, let setup = decided.setup else {
                    print("qwen27-tp-width kind=\(kind) mac_gib=\(Int(localGiB))+\(Int(peerGiB)) placed=false")
                    return nil
                }
                let lanes = try ClusterConfigurationCodec.decode(try #require(setup.configurations["a"]),
                    capability: model.capability, capabilitySHA256: model.pair.capabilitySHA256).batchLanes ?? 1
                print("qwen27-tp-width kind=\(kind) mac_gib=\(Int(localGiB))+\(Int(peerGiB)) lanes=\(lanes) shares=\(chosen.tensorShares ?? [1, 1])"
                    + chosen.ranks.map { " rank\($0.rank)_need_bytes=\($0.needBytes) rank\($0.rank)_admissible_now_bytes=\($0.admissibleNowBytes)" }.joined())
                // Within what each Mac admits now, under the saved width's own quote.
                #expect(chosen.ranks.allSatisfy { $0.needBytes <= $0.admissibleNowBytes && $0.fit == .now })
                return lanes
            }
            var widths: [Int] = []
            for size in [32.0, 36, 48, 64, 96, 128, 192, 256] {
                guard let lanes = try saved(size, size) else { continue }
                #expect(lanes >= (widths.last ?? 1), "\(kind) 2 x \(Int(size)) GiB: a larger pair never saves a narrower width")
                widths.append(lanes)
            }
            #expect(widths.last == 8, "2 x 256 GiB, \(kind)")
            #expect(widths.contains { $0 < 8 }, "\(kind): a smaller pair saves a narrower width")
            for (local, peer) in [(256.0, 36.0), (256.0, 48.0), (256.0, 128.0)] { _ = try saved(local, peer) }
        }
    }

    /// The owner (2026-11-04): tensor parallel and pipeline both offered and choosable where the model allows both. A
    /// person's choice reaches the placement as `chosenMode`, as the developer setting does (the candidate, 2026-11-04:
    /// "Planning failed (Singleton tensor placement requires its complete serial tensor quote)" for either). On the two
    /// recorded pairs' sizes (2 x 256 GB, as two M5 Ultras; 256 + 128 GB, as the M3 Ultra and the M5 Max), with the plain
    /// quote and with the assistant's: Qwen 3.8 27B plans in tensor parallel when it is chosen; pipeline is refused in
    /// the words of its feature contract (images, video and committed-token logprobs only in tensor parallel), never the
    /// quote's internal error.
    @Test func qwenPlansInTheChosenModeOnBothPairs() throws {
        let model = try Self.registered()
        let link = ClusterLinkCosts(measured: true, perChunkSeconds: 0.002, perDecodeStepSeconds: [:],
            handoffSecondsPerByte: 1 / 2e9, provenance: "constructed for a check",
            reduction: .init(fixedSeconds: 1e-6, secondsPerByte: 1 / 5e9, keyed: true, provenance: "constructed for a check"))
        for (kind, quotes) in [("plain", model.plain), ("assistant", model.assisted)] {
            let singleton: ClusterPlacementTensorBatchQuote = try #require(quotes[1])
            for (local, peer) in [(256.0, 256.0), (256.0, 128.0)] {
                for chosen in [ClusterForcedMode.tensorParallel, .pipeline] {
                    let decide = { () throws in
                        try ClusterPlacementFlow.decide(description: model.pair, capability: model.capability,
                            localMemberID: "a", localProfile: try Self.idle(local), peerProfile: try Self.idle(peer), layout: model.layout,
                            tensorAssistantQuote: singleton, tensorWidthQuotes: [2, 4, 6, 8].compactMap { quotes[$0] },
                            leader: "a", link: link, chosenMode: chosen, environment: [:], benchDebugBuild: false)
                    }
                    guard chosen == .tensorParallel else {
                        do {
                            _ = try decide()
                            Issue.record("\(kind) \(Int(local))+\(Int(peer)): pipeline placed for Qwen 3.8 27B, whose contract is tensor parallel only")
                        } catch {
                            print("qwen27-chosen kind=\(kind) macs=\(Int(local))+\(Int(peer)) chosen=pipeline refused=\"\(error)\"")
                            #expect("\(error)".contains("only in tensor parallel") && !"\(error)".contains("Singleton"),
                                    "\(kind) \(Int(local))+\(Int(peer)) pipeline: the contract's words: \(error)")
                        }
                        continue
                    }
                    let decided = try decide()
                    let placed: ClusterPlacementCandidate = try #require(decided.result.chosen, "\(kind) \(Int(local))+\(Int(peer)) \(chosen.rawValue): placed")
                    print("qwen27-chosen kind=\(kind) macs=\(Int(local))+\(Int(peer)) chosen=\(chosen.rawValue) mode=\(placed.mode.rawValue)"
                        + " shares=\(placed.tensorShares.map { "\($0)" } ?? "-")"
                        + placed.ranks.map { " rank\($0.rank)=layers \($0.firstLayer)..<\($0.endLayer) need_bytes=\($0.needBytes)" }.joined())
                    #expect(chosen.admits(placed.mode) && decided.setup != nil, "\(kind) \(Int(local))+\(Int(peer)) \(chosen.rawValue): \(placed.mode)")
                    #expect(placed.ranks.allSatisfy { $0.needBytes <= $0.admissibleNowBytes }, "\(kind) \(Int(local))+\(Int(peer)) \(chosen.rawValue): fits now")
                }
            }
        }
    }
}
