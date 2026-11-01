import Foundation
import Testing
import DarkbloomClusterPlacement
import DarkbloomClusterProtocol

@Suite("Automatic exact-quote placement: synthetic CPU contracts, not hardware evidence")
struct GLM5NextAutomaticPlacementTests {
    typealias P = ClusterGLMCalibrationPlacement
    private let hash = String(repeating: "a", count: 64)
    private let binary = String(repeating: "b", count: 64)
    private let now: Int64 = 1000

    private func profile(_ chip: String) throws -> ClusterDeviceProfile {
        let physical = 1 << 40, free = 1 << 39
        return try .init(chip: chip, performanceCores: 1, efficiencyCores: 0, gpuCores: 1,
            osVersion: "test", osBuild: "test", physicalMemoryBytes: physical,
            gpuRecommendedWorkingSetBytes: free, gpuMaximumBufferBytes: 1 << 30,
            allocatorLimitBytes: free,
            memory: .init(gatePolicy: "synthetic", sampledUTC: "test", judged: true, unjudgedReason: nil,
                physicalMemoryBytes: physical, actualFreeBytes: free, countedFileCacheBytes: 0,
                admissibleNowBytes: free, fileBackedBytes: 0, fileCacheReserveBytes: 0, fileCacheAboveReserveBytes: 0,
                anonymousBytes: 0, wiredBytes: 0, compressorBytes: 0, pageableBytes: free,
                pressureLevel: 0, swapUsedBytes: 0, minimumAdmissibleBytes: 1, minimumTrulyFreeBytes: 1,
                loadingHeadroomBytes: 1, allocatorHeadroomBytes: 1, loadScratchBytes: 1, pageSizeBytes: 4096),
            power: .init(onExternalPower: true, lowPowerMode: false, thermalState: "nominal"))
    }
    private var layout: ClusterModelLayout {
        .init(runtimeModelID: "synthetic-adapter", artifactSHA256: hash, configurationSHA256: hash,
            layers: (0..<8).map { .init(index: $0, kind: "layer", weights: .init(storedBytes: 1 << 20,
                loadedBytes: 1 << 20, largestTensorBytes: 1 << 20, tensorCount: 1),
                stateFixedBytes: 0, stateBytesPerToken: 0, cost: 1) },
            ingress: .init(), egress: .init(), excluded: .init(), admittedCuts: [], structuralCuts: Array(1..<8),
            generationModes: [.pipeline], prefillSchedules: [.serial], maximumPromptTokens: 64,
            maximumOutputTokens: 4, maximumChunkTokens: 32, boundaryBytesPerToken: 8, requestChargeEveryRankBytes: 0)
    }
    private func snapshot(rank: Int, rate: Double?, cuts: [Int] = Array(1..<8), common: String? = nil) throws -> P.Snapshot {
        let device = try profile("synthetic-\(rank)")
        let measurements: [ClusterSpeedMeasurement] = try rate.map { rate in
            [try ClusterSpeedMeasurement(key: .init(artifactSHA256: hash, chip: device.chip,
                osBuild: device.osBuild, runtimeBinarySHA256: binary, probe: "synthetic-stage"),
                promptTokens: 64, chunkTokens: 32, probedLayers: 1, layerCount: 8,
                rested: .init(prefillTokensPerSecond: rate, decodeTokensPerSecond: rate), sustained: nil,
                measuredUTC: "synthetic", provenance: "constructed test inputs, no hardware measurement")]
        } ?? []
        return .init(rank: rank, inputSHA256: hash, commonSHA256: common ?? hash, runtimeBinarySHA256: binary,
            sampledUnixSeconds: now, expiresUnixSeconds: now + 600, profile: device, layout: layout,
            nativeAvailableBytes: 1 << 35, hostAvailableBytes: 1 << 30, combinedAvailableBytes: 1 << 36,
            quotes: cuts.map { cut in
                let native = (rank == 0 ? cut : 8 - cut) * (1 << 20)
                return .init(cut: cut, nativeBytes: native, hostBytes: 1024, combinedBytes: native + 1024)
            }, refusals: [], measurements: measurements)
    }

    @Test func fasterPeerWinsWithOneLayerOnSlowerRank() throws {
        let slow = try snapshot(rank: 0, rate: 10), fast = try snapshot(rank: 1, rate: 100)
        let decision = try P.select([fast, slow], now: now)
        #expect(decision.cut == 1)
        #expect(decision.feasibleCuts == Array(1..<8))
        #expect(decision.rankedCuts.first == 1)
        #expect(decision.speedSources == [.measured, .measured])
        #expect(!decision.measuredBestSpeed && !decision.calibratedEligible)
        #expect(decision.mode == .pipeline && decision.unsupportedModes.contains("tensor_parallel_v1"))
        // Existing decision interface independently prices both valid shapes.
        let devices = [ClusterPlacementDevice(label: "rank0", profile: slow.profile,
            speed: .init(source: .measured, absolute: true,
                rested: .init(prefillTokensPerSecond: 10, decodeTokensPerSecond: 10), sustained: nil, explanation: "synthetic")),
            ClusterPlacementDevice(label: "rank1", profile: fast.profile,
                speed: .init(source: .measured, absolute: true,
                    rested: .init(prefillTokensPerSecond: 100, decodeTokensPerSecond: 100), sustained: nil, explanation: "synthetic"))]
        let one = try ClusterPlacementPlanner.evaluate(devices: devices, cuts: [1], mode: .pipeline, prefillSchedule: .serial, layout: layout)
        let balanced = try ClusterPlacementPlanner.evaluate(devices: devices, cuts: [4], mode: .pipeline, prefillSchedule: .serial, layout: layout)
        #expect(one.rested.requestSeconds < balanced.rested.requestSeconds)
        #expect(decision.prediction == one.rested)
    }
    @Test func reversingSpeedReversesSkewWithoutMachineNameRules() throws {
        #expect(try P.select([snapshot(rank: 0, rate: 100), snapshot(rank: 1, rate: 10)], now: now).cut == 7)
    }
    @Test func exactFitRemovesFastestCutBeforePerformanceRanking() throws {
        let result = try P.select([snapshot(rank: 0, rate: 10), snapshot(rank: 1, rate: 100, cuts: Array(2..<8))], now: now)
        #expect(result.cut == 2 && !result.feasibleCuts.contains(1))
    }
    @Test func missingSpeedIsAPriorNotMeasuredThroughput() throws {
        let result = try P.select([snapshot(rank: 0, rate: nil), snapshot(rank: 1, rate: nil)], now: now)
        #expect(result.speedSources == [.assumedEqual, .assumedEqual])
        #expect(!result.absolutePrediction && !result.measuredBestSpeed && !result.calibratedEligible)
    }
    @Test func noCommonFitStaleAndMismatchedScopeRefuse() throws {
        let a = try snapshot(rank: 0, rate: 10, cuts: [1])
        let b = try snapshot(rank: 1, rate: 100, cuts: [2])
        #expect(throws: (any Error).self) { try P.select([a, b], now: now) }
        #expect(throws: (any Error).self) { try P.select([a, snapshot(rank: 1, rate: 100)], now: now + 121) }
        #expect(throws: (any Error).self) { try P.select([a, snapshot(rank: 1, rate: 100, common: binary)], now: now) }
    }
    @Test func sharedPlannerRejectsUnsupportedModeAndSeparateHostOverflow() throws {
        let devices = try (0...1).map { ClusterPlacementDevice(label: "rank\($0)", profile: try profile("synthetic-\($0)"), speed: .assumedEqual) }
        let good = ClusterPlacementResourceQuote(nativeBytes: 1024, hostBytes: 1024,
            nativeAvailableBytes: 4096, hostAvailableBytes: 4096, combinedAvailableBytes: 8192)
        let hostOverflow = ClusterPlacementResourceQuote(nativeBytes: 1024, hostBytes: 4097,
            nativeAvailableBytes: 8192, hostAvailableBytes: 4096, combinedAvailableBytes: 16384)
        let shapes = [ClusterPlacementQuotedShape(cuts: [], mode: .tensorParallel, schedule: .serial, ranks: [good, good]),
                      .init(cuts: [1], mode: .pipeline, schedule: .serial, ranks: [good, hostOverflow])]
        #expect(try ClusterPlacementPlanner.rankQuoted(devices: devices, layout: layout, shapes: shapes).isEmpty)
    }
    @Test func automaticCutInsertionPreservesEveryOtherBoundAndDoesNotRequireManualCut() throws {
        let template: [String: Any] = ["clusterID": "synthetic", "modelDirectory": "/synthetic",
            "request": ["selection": ["rank": 0, "environment": ["binarySHA256": binary]],
                        "authorization": ["requestID": "test", "promptTokenIDs": [1], "outputCount": 1,
                                          "chunkSize": 1, "nativeHardCapBytes": 123]]]
        let data = try JSONSerialization.data(withJSONObject: template, options: [.sortedKeys])
        let selected = try P.selecting(cut: 1, in: data)
        #expect(try P.bindings(data).local == P.bindings(selected).local)
        #expect(try P.bindings(data).common == P.bindings(selected).common)
        let changed = try JSONSerialization.jsonObject(with: selected) as! [String: Any]
        let request = changed["request"] as! [String: Any]
        #expect((request["selection"] as! [String: Any])["cut"] as? Int == 1)
        #expect((request["authorization"] as! [String: Any])["nativeHardCapBytes"] as? Int == 123)
    }
}
