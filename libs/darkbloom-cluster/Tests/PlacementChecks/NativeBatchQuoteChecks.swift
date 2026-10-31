import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation

func checkNativeBatchQuotes(golden: URL, _ checks: PlacementChecks) throws {
    let libraries = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let fixtures = libraries.appendingPathComponent("darkbloom-cluster-worker/Tests/CapabilityChecks/Fixtures")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-batch-quote-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let bound: (Int) throws -> Int = { try QwenLongPrefillCheckedBytes.sum([$0, 16_384]) }
    for (name, layoutName) in [("gpt-oss-20b", "gpt-oss-20b-2026-05-25-r1"),
                               ("mimo-v26-flash-mopd", "mimo-v2.6-flash-mopd-2026-09-28-r1")] {
        let configuration = try Data(contentsOf: fixtures.appendingPathComponent("registered-\(name).configuration.json"))
        try configuration.write(to: directory.appendingPathComponent("config.json"))
        let layout = try ClusterModelLayout.decode(Data(contentsOf: golden.appendingPathComponent("layouts/\(layoutName).json")))
        for width in [2, 4, 8] {
            let quote = try ClusterPlacementArtifact.requestedBatchQuote(directory: directory, promptTokens: 1024,
                outputTokens: 128, chunkTokens: 512, lanes: width, allocationBound: bound)
            checks.require("\(name) batch\(width): typed round trip binds complete request, width and original chunk",
                try ClusterPlacementBatchQuote.decode(JSONEncoder().encode(quote)) == quote
                    && quote.lanes == width && quote.chunkTokens == 512
                    && quote.request.promptTokens == 1024 && quote.request.outputTokens == 128)
            var largestNative = 0, largestShared = 0
            if name == "gpt-oss-20b" {
                let family = try GPTOSSPlacementFamily(configuration: configuration)
                for cut in family.admittedCuts {
                    for stage in family.plans[cut]!.stages {
                        let state = try GPTOSSRequestStateBudget.estimate(specification: family.specification, layers: stage.layers,
                            rank: stage.index, maximumTokens: 1152, chunkSize: 512, bound: bound)
                        let prefill = try QwenGenerationPrefillAllowance.derive(rank: stage.index, promptCount: 1024,
                            chunkSize: 512, hiddenSize: family.specification.hidden, elementBytes: 4, bound: bound)
                        let work = try GPTOSSBatchWorkspace.estimate(spec: family.specification, localLayers: stage.layers.count,
                            rank: stage.index, lanes: width, bound: bound)
                        largestNative = max(largestNative, try QwenLongPrefillCheckedBytes.sum([state.reservedBytes, prefill.reservedBytes]))
                        largestShared = max(largestShared, try QwenLongPrefillCheckedBytes.sum([work.native, work.host]))
                    }
                }
            } else {
                let family = try MiMoPlacementFamily(configuration: configuration)
                for cut in family.admittedCuts {
                    for stage in family.plans[cut]!.stages {
                        let state = try MiMoRequestStateBudget.estimate(specification: family.specification, layers: stage.sourceRange,
                            rank: stage.index, maximumTokens: 1152, chunkSize: 512, bound: bound)
                        let pages = try MiMoPagedKVAllowance.pages(spec: family.specification, layers: stage.sourceRange,
                            maximumTokens: 1152, chunkSize: 512, bound: bound)
                        let history = try MiMoBatchMemory.historyBytes(maximumTokens: 1152)
                        let work = try MiMoBatchMemory.workspace(spec: family.specification, localLayers: stage.layers.count,
                            rank: stage.index, lanes: width, bound: bound)
                        largestNative = max(largestNative, try QwenLongPrefillCheckedBytes.sum([state.reservedBytes, pages, history]))
                        largestShared = max(largestShared, try QwenLongPrefillCheckedBytes.sum([work.native, work.host]))
                    }
                }
            }
            checks.require("\(name) batch\(width): covers every admitted native stage without sharing lane state",
                quote.request.requestChargeEveryRankBytes >= largestNative && quote.sharedWorkspaceEveryRankBytes == largestShared)
            let scope = try ClusterPlacementBatchScope(quote: quote)
            try quote.requireRequest(promptTokens: 1024, outputTokens: 128, lanes: width, chunkTokens: 512)
            for (prompt, output, lanes, chunk) in [(2048,128,width,512), (1024,256,width,512),
                                                   (512,128,width,512), (1024,64,width,512),
                                                   (1024,128,width == 2 ? 4 : 2,512), (1024,128,width,256)] {
                checks.refuses("\(name) batch\(width): mismatched helper demand cannot reuse a valid quote", because: "requested scope") {
                    try quote.requireRequest(promptTokens: prompt, outputTokens: output, lanes: lanes, chunkTokens: chunk)
                }
            }
            try scope.requireChunk(512, derived: false)
            checks.refuses("\(name) batch\(width): changed original chunk cannot reuse quote", because: "original chunk") {
                try scope.requireChunk(256, derived: false)
            }
            checks.refuses("\(name) batch\(width): derived chunk cannot reuse pinned quote", because: "original chunk") {
                try scope.requireChunk(512, derived: true)
            }
            checks.require("\(name) batch\(width): shared owner workspace counted once beside all histories",
                scope.requestChargeEveryRankBytes == width * quote.request.requestChargeEveryRankBytes + largestShared)
            var policy = ClusterPlacementPolicy(); policy.promptTokens = 1024; policy.outputTokens = 128
            try scope.apply(to: &policy, layout: layout)
            let devices = try [SyntheticMac.idle(1024).device("a"), SyntheticMac.idle(1024).device("b")]
            let result = try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: policy)
            checks.require("\(name) batch\(width): actual planner keeps full quote on both ranks and selects plain pipeline",
                result.chosen?.mode == .pipeline && result.chosen?.ranks.allSatisfy { $0.requestNeedBytes >= scope.requestChargeEveryRankBytes } == true)
        }
        for (prompt, output, chunk, width) in [(0,1,512,2), (1,0,512,2), (Int.max,1,512,2),
                                              (1,Int.max,512,2), (1024,128,0,2), (1024,128,513,2),
                                              (1024,128,512,1), (1024,128,512,3), (1024,128,512,9)] {
            checks.refuses("\(name): invalid native quote scope refuses before any allocator work", because: "registered request scope") {
                _ = try ClusterPlacementArtifact.requestedBatchQuote(directory: directory, promptTokens: prompt,
                    outputTokens: output, chunkTokens: chunk, lanes: width,
                    allocationBound: { _ in throw ProbeError("allocator must not be consulted") })
            }
        }
        checks.refuses("\(name): native allocator underbound cannot discount independent pages", because: "allocator bound") {
            _ = try ClusterPlacementArtifact.requestedBatchQuote(directory: directory, promptTokens: 1024,
                outputTokens: 128, chunkTokens: 512, lanes: 2, allocationBound: { max(0, $0 - 1) })
        }
        let full = try ClusterPlacementArtifact.requestedBatchQuote(directory: directory, promptTokens: 32768,
            outputTokens: 32768, chunkTokens: 512, lanes: 8, allocationBound: bound)
        let shorter = try ClusterPlacementArtifact.requestedBatchQuote(directory: directory, promptTokens: 1024,
            outputTokens: 128, chunkTokens: 512, lanes: 8, allocationBound: bound)
        checks.require("\(name): full advertised history is charged above the small test shape",
            full.request.requestChargeEveryRankBytes > shorter.request.requestChargeEveryRankBytes)
        var malformed = try JSONSerialization.jsonObject(with: JSONEncoder().encode(shorter)) as! [String: Any]
        malformed["lanes"] = 3
        checks.refuses("\(name): malformed typed width is not a valid new quote", because: "batch quote") {
            _ = try ClusterPlacementBatchQuote.decode(JSONSerialization.data(withJSONObject: malformed))
        }
    }
}
