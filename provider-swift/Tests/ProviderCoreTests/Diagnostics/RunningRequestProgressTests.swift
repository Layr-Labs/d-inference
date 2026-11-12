import Foundation
import Testing

@testable import ProviderCore

/// `darkbloom status` lists the answers a Mac is writing (QWEN36-STUCK §5): the
/// state file carries each one's model, elapsed time, tokens so far and
/// current rate, from counters the bridges already keep, and no request text
/// or id beyond a short hash.
@Suite("Daemon state: answers in progress")
struct RunningRequestProgressTests {
    typealias Sample = RunningRequestProgressTracker.Sample

    static let model = "qwen3.6-35b-a3b-vl-mtp-mxfp8"

    static func sample(_ id: String, admitted: Double, firstToken: Double?, tokens: Int,
                       model: String = model) -> Sample {
        Sample(id: id, model: model, sinceAdmission: .seconds(admitted),
               sinceFirstToken: firstToken.map { .seconds($0) }, outputTokens: tokens)
    }

    @Test func theRateIsTheTokensSinceTheLastSampleOverItsTime() {
        var tracker = RunningRequestProgressTracker()
        // First sight: the average since the first token.
        let first = tracker.update([Self.sample("req-a", admitted: 61, firstToken: 60, tokens: 2_400)], now: 100)
        #expect(first == [DaemonState.RunningRequest(model: Self.model, ref: RunningRequestProgressTracker.ref("req-a"),
                                                     elapsedSeconds: 61, outputTokens: 2_400, tokensPerSecond: 40)])
        // Two seconds later, 78 more tokens: 39 tok/s now, whatever the average.
        let next = tracker.update([Self.sample("req-a", admitted: 63, firstToken: 62, tokens: 2_478)], now: 102)
        #expect(next.first?.tokensPerSecond == 39)
        #expect(next.first?.outputTokens == 2_478 && next.first?.elapsedSeconds == 63)
    }

    @Test func aRequestStillReadingItsPromptHasNoRate() {
        var tracker = RunningRequestProgressTracker()
        let running = tracker.update([Self.sample("req-b", admitted: 3, firstToken: nil, tokens: 0)], now: 10)
        #expect(running.map(\.tokensPerSecond) == [nil])
        #expect(running.map(\.outputTokens) == [0])
    }

    @Test func longestFirstAndFinishedAnswersAreForgotten() {
        var tracker = RunningRequestProgressTracker()
        let two = tracker.update([
            Self.sample("short", admitted: 5, firstToken: 4, tokens: 160),
            Self.sample("long", admitted: 797, firstToken: 796, tokens: 30_875),
        ], now: 1_000)
        #expect(two.map(\.outputTokens) == [30_875, 160])
        // "long" finished; when a new request takes its id's place later, it
        // starts from its own first sample, not from the old counters.
        _ = tracker.update([Self.sample("short", admitted: 7, firstToken: 6, tokens: 240)], now: 1_002)
        let reused = tracker.update([Self.sample("long", admitted: 2, firstToken: 1, tokens: 50)], now: 1_004)
        #expect(reused.first?.tokensPerSecond == 50)
        #expect(tracker.update([], now: 1_006).isEmpty)
    }

    @Test func theRefIsAShortHashNeverTheID() throws {
        let id = "chatcmpl-7f3a9e0c-zq-private"
        let ref = RunningRequestProgressTracker.ref(id)
        #expect(ref.count == 8 && ref.allSatisfy(\.isHexDigit))
        #expect(!id.contains(ref) && ref == RunningRequestProgressTracker.ref(id))
        #expect(ref != RunningRequestProgressTracker.ref(id + "x"))
        var tracker = RunningRequestProgressTracker()
        let running = tracker.update([Self.sample(id, admitted: 1, firstToken: nil, tokens: 0)], now: 1)
        let encoded = String(decoding: try JSONEncoder().encode(running), as: UTF8.self)
        #expect(!encoded.contains(id))
    }

    @Test func atMostThirtyTwoAreListed() {
        var tracker = RunningRequestProgressTracker()
        let samples = (0..<40).map { Self.sample("r\($0)", admitted: Double($0), firstToken: nil, tokens: 0) }
        let running = tracker.update(samples, now: 1)
        #expect(running.count == RunningRequestProgressTracker.maximumListed)
        #expect(running.first?.elapsedSeconds == 39)
    }

    @Test func theStateFileCarriesThemAndOlderFilesReadAsUnreported() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("running-requests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let request = DaemonState.RunningRequest(model: Self.model, ref: "0a1b2c3d", elapsedSeconds: 834.3,
                                                 outputTokens: 32_768, tokensPerSecond: 39.3)
        DaemonStateFile.write(DaemonState(pid: 7, version: "test", writtenAt: 1, startedAt: 0,
                                          runningRequests: [request]), to: url)
        #expect(DaemonStateFile.read(from: url)?.runningRequests == [request])
        let raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let written = try #require((raw["running_requests"] as? [[String: Any]])?.first)
        #expect(Set(written.keys) == ["model", "ref", "elapsed_seconds", "output_tokens", "tokens_per_second"])

        DaemonStateFile.write(DaemonState(pid: 7, version: "test", writtenAt: 1, startedAt: 0), to: url)
        #expect(DaemonStateFile.read(from: url).map { $0.runningRequests == nil } == true)
    }

    @Test func theLoopWritesTheListEvenWhenNothingRuns() async throws {
        let hardware = HardwareInfo(machineModel: "Mac17,6", chipName: "Apple M5 Max",
            chipFamily: .m5, chipTier: .max, memoryGb: 128, memoryAvailableGb: 128,
            cpuCores: .init(total: 18, performance: 12, efficiency: 6),
            gpuCores: 40, memoryBandwidthGbs: 614)
        let loop = try ProviderLoop(config: .init(coordinatorURL: "ws://127.0.0.1:0/unused",
            hardware: hardware, models: [], config: .init(provider: .init(name: "status"),
                backend: .init(), coordinator: .init(heartbeatIntervalSecs: 60))),
            attestationSigner: nil)
        await loop.refreshRunningRequests(now: 1)
        #expect(await loop.currentDaemonState().runningRequests == [])
    }
}
