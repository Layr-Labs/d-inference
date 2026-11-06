import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation
import Testing

@testable import ProviderCore

/// DevNet .118, pair-2 (an M3 Ultra 256 GB and an M5 Max 128 GB, 2026-11-06): right after the update Gemma 4 26B had
/// served nothing with the new build, so the mode question compared the planner's predictions and said "Pipeline,
/// faster here", although these Macs had served its tensor parallel faster with every earlier build (pipeline 57.2 tok/s
/// on .92; tensor parallel 61.3 on .92 and 84 on .110). A plan of a new build reads no earlier build's served speeds
/// (`ClusterServedSpeedRecords.servedBy`); the mode question reads those that say how they were served
/// (`ClusterSetupPlanning.earlierFigures`) until this build has served one of the modes. Records say it from #1819 on
/// (DevNet .100, provider 0.10.11): .92's don't, and neither do 0.10.10's.
@Suite("Mode question: what these Macs served with an earlier build")
struct ClusterSetupModeEvidenceTests {
    static let current = String(repeating: "c", count: 64)
    static let build92 = String(repeating: "9", count: 64)
    static let build110 = String(repeating: "b", count: 64)
    static let model = "gemma-4-26b-qat-4bit"
    static let tp = ClusterGenerationMode.tensorParallel.rawValue
    static let pp = ClusterGenerationMode.pipeline.rawValue

    /// `count` requests both Macs served in `mode` with `build`, the way `serving` and `assisted` name (nil: not named).
    static func served(_ mode: String, build: String, serving: ClusterServedScope?, assisted: Bool? = false, decode: Double,
                       at: Double, count: Int = 3) -> [ClusterServedSpeedRecords.Entry] {
        let setup = ClusterServedSpeedRecords.Setup(modelID: model, mode: mode, cut: mode == tp ? "0-30|0-30" : "0-1|1-30",
            ranks: ["mac-a", "mac-b"], rankBuildSHA256: [build, build], serving: serving, tensorAssistant: assisted)
        return (0..<count).map { index in
            .init(setup: setup, sample: .init(route: .pair, member: nil, promptTokens: 2_391, outputTokens: 256, firstTokenSeconds: 0.6,
                                              decodeTokensPerSecond: decode, finishedAt: at + Double(index)))
        }
    }

    /// A pair whose builds all said how they served: both modes through Darkbloom with one build, tensor parallel again
    /// with a later one.
    static let history = served(pp, build: build92, serving: .darkbloom, decode: 57.2, at: 1_000)
        + served(tp, build: build92, serving: .darkbloom, decode: 61.3, at: 1_100)
        + served(tp, build: build110, serving: .darkbloom, decode: 84, at: 2_000)

    /// Pair-2's Gemma records as they were written before .118: .92 predates #1819 and names neither how it served nor
    /// the assistant; .110 names both.
    static let pair2 = served(pp, build: build92, serving: nil, assisted: nil, decode: 57.2, at: 1_000)
        + served(tp, build: build92, serving: nil, assisted: nil, decode: 61.3, at: 1_100)
        + served(tp, build: build110, serving: .darkbloom, decode: 84, at: 2_000)

    static func earlier(_ entries: [ClusterServedSpeedRecords.Entry], serving: ClusterServedScope = .darkbloom,
                        assisted: Bool = false) -> [ClusterGenerationMode: Double] {
        ClusterSetupPlanning.earlierFigures(entries, builds: ["mac-a": current, "mac-b": current], serving: serving,
                                           tensorAssistant: assisted, promptTokens: 2_391, outputTokens: 256)
    }

    @Test("each mode at the rate the latest earlier build served it, served the way the plan will serve")
    func theLatestEarlierBuildServedTheWayThePlanWillServe() {
        let pair2: [ClusterGenerationMode: Double] = [.tensorParallel: 84, .pipeline: 57.2]
        #expect(Self.earlier(Self.history) == pair2)
        let few = Self.served(Self.tp, build: String(repeating: "d", count: 64), serving: .darkbloom, decode: 20, at: 3_000, count: 2)
        #expect(Self.earlier(Self.history + few) == pair2, "a build that served a mode fewer than 3 times says nothing of it")
        let thisBuild = Self.served(Self.pp, build: Self.current, serving: .darkbloom, decode: 140, at: 4_000)
        #expect(Self.earlier(Self.history + thisBuild) == pair2, "this build's own records are the plan's, not an earlier build's")
        // Served another way, or not saying how (a record written before either was recorded): not this plan's evidence.
        let otherWays = Self.served(Self.pp, build: Self.build110, serving: .local, decode: 120, at: 5_000)
            + Self.served(Self.pp, build: Self.build110, serving: nil, assisted: nil, decode: 130, at: 5_100)
            + Self.served(Self.tp, build: Self.build110, serving: .darkbloom, assisted: true, decode: 150, at: 5_200)
            + Self.served(Self.tp, build: Self.build110, serving: .darkbloom, assisted: nil, decode: 160, at: 5_300)
        #expect(Self.earlier(Self.history + otherWays) == pair2, "through Darkbloom without the assistant: only such records")
        #expect(Self.earlier(Self.history + otherWays, serving: .local) == [.pipeline: 120], "a local plan reads the local records")
        #expect(Self.earlier(Self.history + otherWays, assisted: true) == [.tensorParallel: 150, .pipeline: 57.2],
                "a plan with Qwen's tensor assistant reads its assisted tensor-parallel records")
        // Only tensor parallel must name the assistant (`ClusterServedSpeedRecords.Setup.servedAs` weighs it there alone).
        let assistantUnnamed = Self.served(Self.pp, build: Self.build110, serving: .darkbloom, assisted: nil, decode: 70, at: 6_000)
        #expect(Self.earlier(Self.history + assistantUnnamed) == [.tensorParallel: 84, .pipeline: 70],
                "a pipeline record that names its serving counts without naming the assistant")
        #expect(Self.earlier([]).isEmpty)
        // Pair-2 as its records were written: .92's say nothing of how they were served, so only .110's count. No
        // record from before #1819 (0.10.10 and earlier) ever counts: it may have been served the other way.
        #expect(Self.earlier(Self.pair2) == [.tensorParallel: 84])
        #expect(Self.earlier(Array(Self.pair2.prefix(6))).isEmpty, "only records from before #1819: nothing, the prediction decides")
    }

    @Test("pair-2 after the update: tensor parallel, as these Macs measured it, not the pipeline the planner predicts faster")
    func pair2AfterTheUpdate() throws {
        let golden = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("libs/darkbloom-cluster/Tests/PlacementChecks/Golden", isDirectory: true)
        let layout = try ClusterModelLayout.decode(Data(contentsOf: golden.appendingPathComponent("layouts/gemma-4-26b-qat-4bit.json")))
        // The recorded M3 Ultra 256 GB and M5 Max 128 GB: pair-2's Macs.
        let profiles = try ["profile-mac-a.json", "profile-mac-b.json"].map {
            try ClusterDeviceProfile.decode(Data(contentsOf: golden.appendingPathComponent($0)))
        }
        // A pair that has served tensor parallel has measured its keyed link (a pair's recorded JACCL probe), so the plan
        // places both modes.
        let link = try #require(ClusterLinkCosts(probe: ClusterWorkerLinkProbe(transport: "jaccl", keyed: true, pointToPointSmallBytes: 64,
            pointToPointSmallMicroseconds: 180, pointToPointLargeBytes: 4 << 20, pointToPointLargeMicroseconds: 2_502,
            allSumSmallBytes: 16_384, allSumSmallMicroseconds: 29, allSumLargeBytes: 32 << 20, allSumLargeMicroseconds: 3_919),
            measuredUTC: "2026-11-06T00:00:00Z"))
        let result = try ClusterPlacementPlanner.plan(devices: zip(["mac-a", "mac-b"], profiles).map {
            ClusterPlacementDevice(label: $0.0, profile: $0.1, speed: .assumedEqual)
        }, layout: layout, link: link)
        let pair = ClusterPairDescription(schema: ClusterPairDescription.schemaName, clusterID: "pair-2", publicModelID: Self.model,
            capabilitySHA256: String(repeating: "e", count: 64), chunkTokens: 512, requestTimeoutSeconds: 315, coordinatorPort: 5577,
            members: ["mac-a", "mac-b"].enumerated().map { index, id in
                .init(id: id, host: "192.0.2.\(index + 1)", port: 22, user: "fixture", ownerExecutable: "/fixture/darkbloom",
                      workerExecutable: "/fixture/worker", modelDirectory: "/fixture/model", runtimeBinarySHA256: Self.current,
                      jacclDevice: "en7", linkAddress: "192.0.2.\(index + 1)", trust: nil)
            }, tokenizerFiles: [.init(path: "tokenizer.json", sha256: String(repeating: "6", count: 64), purpose: .tokenizer)])
        func modes(_ served: [ClusterServedSpeedRecords.Entry]) throws -> [ClusterSetupPlanSummary.Mode] {
            try #require(ClusterSetupPlanning.modes(result, served: served, pair: pair, localMemberID: "mac-a", serving: .darkbloom,
                                                    tensorAssistant: false))
        }
        let afterUpdate = try modes(Self.pair2)
        #expect(Set(afterUpdate.map(\.mode)) == [Self.tp, Self.pp], "Gemma runs both ways on these Macs: \(afterUpdate.map(\.mode))")
        #expect(afterUpdate.allSatisfy { $0.servedDecodeTokensPerSecond == nil }, "nothing served with this build yet")
        #expect(afterUpdate.first { $0.mode == Self.tp }?.earlierServedDecodeTokensPerSecond == 84)
        #expect(afterUpdate.first { $0.mode == Self.pp }?.earlierServedDecodeTokensPerSecond == nil, ".92's pipeline records name no scope")
        // The question's own plans, the planner predicting the pipeline faster (pair-2's figures: 56 against 52 tok/s).
        func plan(_ mode: String, decode: Double) -> ClusterSetupPlanSummary {
            .init(cut: 0, mode: mode, prefillSchedule: "serial", leaderID: "mac-a", ranks: [], promptTokens: 2_391, outputTokens: 256,
                  firstTokenSeconds: 1, decodeTokensPerSecond: decode, absolute: true, measured: false, alone: [], aloneAsFast: [],
                  fitsNow: true, needsBytes: nil, explanation: [])
        }
        func advice(_ modes: [ClusterSetupPlanSummary.Mode]) -> ClusterOnboardingModeAdvice? {
            OnboardingLive.modeAdvice(modes, listed: plan(Self.pp, decode: 56), families: [plan(Self.tp, decode: 52)],
                                      throughDarkbloom: true, serving: true)
        }
        #expect(advice(afterUpdate) == .init(mode: Self.tp, reason: "the only one measured on these Macs so far"))
        // Both modes served with builds that said how: the faster as measured.
        #expect(advice(try modes(Self.history)) == .init(mode: Self.tp, reason: "faster here"))
        // What .118 read (no earlier build's records), and what an update from 0.10.10 reads (only records from before
        // #1819): the predictions decide.
        #expect(advice(try modes([])) == .init(mode: Self.pp, reason: "faster here"))
        #expect(advice(try modes(Array(Self.pair2.prefix(6)))) == .init(mode: Self.pp, reason: "faster here"))
        // Once tensor parallel served with this build (capture B, 09:38Z), this build's measurement decides.
        let servedNow = try modes(Self.pair2 + Self.served(Self.tp, build: Self.current, serving: .darkbloom, decode: 96.4, at: 9_000))
        #expect(servedNow.first { $0.mode == Self.tp }?.servedDecodeTokensPerSecond == 96.4)
        #expect(advice(servedNow) == .init(mode: Self.tp, reason: "the only one measured on these Macs so far"))
    }
}
