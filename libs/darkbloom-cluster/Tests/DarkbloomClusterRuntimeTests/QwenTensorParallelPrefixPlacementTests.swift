import DarkbloomClusterPlacement
@testable import DarkbloomClusterProtocol
import Foundation
import Testing
@testable import DarkbloomClusterRuntime

/// Where the registered 27B still places tensor parallel once every lane's
/// quote charges its prompt-prefix capture at the profile's longest prompt
/// (`QwenTensorParallelBatchPrefixBudget`) instead of one 4,096-token capture
/// and two such banks: the actual planner, the real retained headers and
/// LOAD's own quote, on idle constructed Macs of each size (the vision tower's
/// resident bytes aside, as the served layout). No model, no GPU.
struct QwenTensorParallelPrefixPlacementTests {
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
    private func bound(_ bytes: Int) -> Int { ((bytes + 16_383) / 16_384) * 16_384 }

    /// An idle Mac of `physicalGiB`, as the placement checks construct one
    /// (`SyntheticMac.idle`): wired 3 % (at least 2.5 GiB), other programs 4 %
    /// (at least 3 GiB), 1 GiB of file cache, the rest free.
    private func idle(_ label: String, _ physicalGiB: Double) throws -> ClusterPlacementDevice {
        let page = 16_384
        func pages(_ value: Double) -> Int { Int((value * Double(Self.gib) / Double(page)).rounded()) }
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
        let profile = try ClusterDeviceProfile(chip: "Synthetic", performanceCores: 8, efficiencyCores: 4, gpuCores: nil,
            osVersion: "27.0", osBuild: "SYNTH", physicalMemoryBytes: bytes, gpuRecommendedWorkingSetBytes: workingSet,
            gpuMaximumBufferBytes: bytes / 2, allocatorLimitBytes: min(workingSet / 2 * 3, bytes / 100 * 95),
            memory: .gate(observation, now: 1_100),
            power: .init(onExternalPower: true, lowPowerMode: false, thermalState: "nominal"))
        return .init(label: label, profile: profile, speed: .init(source: .measured, absolute: true,
            rested: .init(prefillTokensPerSecond: 1000, decodeTokensPerSecond: 60,
                tensorShardPrefillTokensPerSecond: 1500, tensorShardDecodeTokensPerSecond: 200),
            sustained: nil, explanation: "constructed rates"))
    }

    @Test func everyPairThatPlacedTensorParallelStillPlacesIt() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("StageMetadataChecks/Inputs/qwen-retained-inputs.json")
        let retained = try JSONDecoder().decode(Retained.self, from: Data(contentsOf: url)).twentySeven
        let family = try QwenDensePlacementFamily(configuration: retained.configuration), p = family.profile
        let plan = try #require(family.tensorParallel)
        let text = retained.canonicalTensors.map {
            ClusterPlacementStoredTensor(name: $0.name, byteCount: $0.byteCount, dtype: $0.sourceDType, shape: $0.shape)
        }
        // The artifact's speculative head, which its layout names (`Inputs/qwen27-tp-mtp-inventory.json`).
        let head = try JSONDecoder().decode(Assistant.self, from: Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Inputs/qwen27-tp-mtp-inventory.json"))).tensors.map {
            ClusterPlacementStoredTensor(name: $0.name, byteCount: $0.byteCount, dtype: $0.dtype, shape: $0.shape)
        }
        let stored = text + head
        // The served layout's planning facts, without the vision tower's
        // resident bytes (the retained headers name the text model only).
        var planning = family
        planning.tensorParallelRequestAllowance = try QwenTensorParallelRequestBudget.derive(geometry: family.geometry,
            plan: plan, tensors: family.requireRegisteredInventory(text), maximumTokens: family.largestContextTokens,
            chunkSize: family.maximumChunkTokens, allocationBound: bound).allowance
        let specification = family.definition.specification
        var layoutObject = try JSONSerialization.jsonObject(with: ClusterModelLayoutBuilder.build(family: planning,
            tensors: stored, artifactSHA256: specification.artifactSHA256,
            configurationSHA256: specification.configurationSHA256).encoded()) as! [String: Any]
        let listed = (layoutObject["generationModes"] as? [String] ?? []) + [ClusterGenerationMode.tensorParallel.rawValue]
        layoutObject["generationModes"] = ClusterGenerationMode.allCases.map(\.rawValue).filter(listed.contains)
        let layout = try ClusterModelLayout.decode(JSONSerialization.data(withJSONObject: layoutObject, options: [.sortedKeys]))
        let request = try ClusterPlacementRequestScope(runtimeModelID: family.runtimeModelID,
            artifactSHA256: family.definition.specification.artifactSHA256,
            configurationSHA256: family.definition.specification.configurationSHA256,
            promptTokens: 1024, outputTokens: 128, maximumPromptTokens: p.maximumPromptTokens,
            maximumOutputTokens: p.maximumOutputTokens, maximumContextTokens: p.maximumContextTokens,
            requestChargeEveryRankBytes: family.requestChargeEveryRankBytes(contextTokens: 1152))
        let link = ClusterLinkCosts(measured: true, perChunkSeconds: 0.002, perDecodeStepSeconds: [:],
            handoffSecondsPerByte: 1 / 2e9, provenance: "constructed for a check",
            reduction: .init(fixedSeconds: 1e-6, secondsPerByte: 1 / 5e9, keyed: true, provenance: "constructed for a check"))
        // One 4,096-token capture of `geometry` and its two resident banks: the earlier per-lane and shared terms.
        func earlier(_ geometry: QwenLongPrefillBudgetGeometry) throws -> Int {
            let b = try QwenLongPrefillTensorBudget.estimate(geometry: geometry, maximumTokens: 4096, chunkSize: 1)
            return geometry.recurrentLayers * (bound(b.convolutionBytesPerLayer) + bound(b.ssmBytesPerLayer))
                + 2 * geometry.attentionLayers * bound(4096 * geometry.kvHeads * geometry.headDimension * 2)
        }
        func now(_ geometry: QwenLongPrefillBudgetGeometry) throws -> Int {
            try QwenTensorParallelBatchPrefixBudget.captureBytes(geometry: geometry, promptCount: p.maximumPromptTokens,
                chunkSize: p.maximumChunkTokens, allocationBound: bound)
        }
        for lanes in [1, 8] {
            let after = try ClusterPlacementArtifact.tensorBatchQuote(configuration: retained.configuration, stored: text,
                request: request, chunkTokens: 512, lanes: lanes, allocationBound: bound)
            // The same quote with the earlier prefix terms, rank by rank.
            func shifted(_ bytes: Int, _ geometry: QwenLongPrefillBudgetGeometry) throws -> Int {
                bytes - lanes * (try now(geometry)) + lanes * (try earlier(geometry)) + 2 * (try earlier(geometry))
            }
            let whole = family.geometry
            let before = try ClusterPlacementTensorBatchQuote(request: request, lanes: lanes, chunkTokens: 512,
                perLaneStateBytes: after.perLaneStateBytes - (try now(whole)) + (try earlier(whole)),
                sharedBytesExcludingCollectives: after.sharedBytesExcludingCollectives + 2 * (try earlier(whole)),
                allowance: .init(maximumContextTokens: after.allowance.maximumContextTokens,
                    maximumChunkTokens: after.allowance.maximumChunkTokens,
                    requestBytesExcludingCollectives: try shifted(after.allowance.requestBytesExcludingCollectives, whole),
                    maximumCollectivePayloadBytes: after.allowance.maximumCollectivePayloadBytes,
                    maximumCollectiveFrameBytes: after.allowance.maximumCollectiveFrameBytes, allocationBound: bound),
                rankQuotes: try after.rankQuotes.map { quotes in
                    try quotes.map { entry in
                        let split = try QwenTensorParallelPlan(textConfiguration: try Self.text(retained.configuration),
                            quantization: try Self.quantization(retained.configuration), size: 2, shares: entry.shares)
                        return .init(shares: entry.shares, requestBytesExcludingCollectives: try entry.requestBytesExcludingCollectives
                            .enumerated().map { rank, bytes in
                                try shifted(bytes, try family.geometry.tensorParallelShard(plan: split, rank: rank))
                            })
                    }
                })
            for size in [24.0, 32, 36, 48, 64, 96, 128, 192, 256] {
                let devices = try [idle("a", size), idle("b", size)]
                func evaluate(_ quote: ClusterPlacementTensorBatchQuote) throws -> (fits: Bool, need: Int, gpu: Int) {
                    var policy = ClusterPlacementPolicy(); policy.leader = "a"
                    policy.promptTokens = request.promptTokens; policy.outputTokens = request.outputTokens
                    if lanes == 1 { try quote.applySingleton(to: &policy, layout: layout) }
                    else { try ClusterPlacementBatchScope(request: request, lanes: lanes, tensorParallelQuote: quote).apply(to: &policy, layout: layout) }
                    let candidate = try ClusterPlacementPlanner.evaluate(devices: devices, cuts: [], mode: .tensorParallel,
                        prefillSchedule: .serial, layout: layout, policy: policy, link: link)
                    return (candidate.ranks.allSatisfy { $0.hardwareFits == true }, candidate.ranks.map(\.needBytes).max() ?? 0,
                            candidate.ranks.compactMap(\.gpuResidentBytes).max() ?? 0)
                }
                let then = try evaluate(before), today = try evaluate(after), mac = devices[0].profile
                print("qwen27-tp-prefix-placement lanes=\(lanes) mac_gib=\(Int(size)) before_fits=\(then.fits)"
                    + " before_need=\(then.need) after_fits=\(today.fits) after_need=\(today.need) delta=\(today.need - then.need)"
                    + " before_gpu=\(then.gpu) after_gpu=\(today.gpu) at_rest=\(mac.atRestAdmissibleBytes) gpu_limit=\(mac.residentCapacityBytes)")
                if size >= 256 { #expect(today.fits, "2 x \(Int(size)) GiB, \(lanes) lanes") }
                // One lane keeps tensor parallel wherever the earlier terms placed it and the Mac has room for today's
                // terms. Two 24 GiB Macs have none: a rank's whole need (20.12 GiB) passes what a 24 GiB Mac admits at
                // rest (`ClusterDeviceProfile.atRestAdmissibleBytes`, physical memory less the 4 GiB macOS keeps: 20 GiB),
                // though its GPU part is within the GPU limit. The earlier terms fitted only by leaving out 1.05 GiB of
                // the lane's prefix capture.
                if lanes == 1 && then.fits && size > 24 { #expect(today.fits, "2 x \(Int(size)) GiB placed tensor parallel before") }
                if lanes == 1 && size == 24 {
                    #expect(then.fits && !today.fits && today.need > mac.atRestAdmissibleBytes && today.gpu <= mac.residentCapacityBytes,
                            "2 x 24 GiB, one lane: refused by the at-rest ceiling, not the GPU limit")
                }
            }
        }
    }

    private static func text(_ configuration: Data) throws -> [String: Any] {
        let root = try JSONSerialization.jsonObject(with: configuration) as! [String: Any]
        return root["text_config"] as! [String: Any]
    }
    private static func quantization(_ configuration: Data) throws -> [String: Any] {
        let root = try JSONSerialization.jsonObject(with: configuration) as! [String: Any]
        return root["quantization"] as! [String: Any]
    }
}
