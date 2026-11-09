import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation
import Testing
@testable import ProviderCore

// The pair's setup screen where pair-2 found it unclear or false (journey 3 and its deltas).

@Suite("The pair's setup screen: what each mode serves, and a stopped pair whose other Mac is gone")
struct ClusterSetupRealMacWordsTests {
    private static let tp = ClusterGenerationMode.tensorParallel.rawValue
    private static let pp = ClusterGenerationMode.pipeline.rawValue
    private typealias Option = ClusterOnboardingModeAdvice.Option

    // MARK: - D8: the split question names each mode's context, and recommends by it

    private static func gemmaModes() -> [ClusterOnboardingMode] {
        [ClusterOnboardingMode(mode: tp, split: "this Mac 50% / the other Mac 50%", measuredTokensPerSecond: nil, concurrentRequests: 1,
                               contextTokens: 262_144, promptTokens: 262_143),
         ClusterOnboardingMode(mode: pp, split: "this Mac 1 layer / the other Mac 29 layers", measuredTokensPerSecond: nil,
                               concurrentRequests: 1, contextTokens: 65_536, promptTokens: 32_768)]
    }

    /// Journey 3's second delta: after the update, Gemma 4's question read "Recommended …: Pipeline, faster here", and
    /// Enter took the pipeline, which serves 65,536 tokens against tensor parallel's 262,144, without the screen saying
    /// so. Each mode's line now says the context it serves, and a prompt limit below it.
    @Test("each mode's line says the context it serves, and its prompt limit when that is lower")
    func eachModeSaysItsContext() {
        let modes = Self.gemmaModes()
        #expect(ClusterOnboardingDriver.modeLine(modes[0]) == ClusterOnboardingDriver.menuLine("Tensor parallel",
            "both Macs work on every layer, each holding a share of it (this Mac 50% / the other Mac 50%) · serves one request "
                + "at a time · context 262,144 tokens"))
        #expect(ClusterOnboardingDriver.modeLine(modes[1], recommended: true) == ClusterOnboardingDriver.menuLine("Pipeline",
            "each Mac runs its share of the layers (this Mac 1 layer / the other Mac 29 layers) · serves one request at a time · "
                + "context 65,536 tokens, prompts up to 32,768 · recommended for these Macs"))
        // A narrow window keeps the context: it is what a long request needs to know.
        for room in [72, 48, 30] {
            #expect(ClusterOnboardingDriver.modeLine(modes[1], room: room).contains("65,536"), "\(room)")
        }
        // A mode whose context isn't known (an older leading Mac's list) says none.
        let older = ClusterOnboardingMode(mode: Self.pp, split: nil, measuredTokensPerSecond: nil)
        #expect(!ClusterOnboardingDriver.modeLine(older).contains("context"))
    }

    /// The recommendation weighs context before speed: a mode that serves less of the model's context is recommended
    /// only when no mode serving more fits these Macs now.
    @Test("the longest context is recommended over a faster mode that serves less")
    func theLongestContextIsRecommended() {
        let both = [Option(mode: Self.tp, planned: true, fitsNow: true, predictedTokensPerSecond: 60, concurrentRequests: 1,
                           contextTokens: 262_144),
                    Option(mode: Self.pp, planned: true, fitsNow: true, predictedTokensPerSecond: 90, concurrentRequests: 1,
                           contextTokens: 65_536)]
        let advice = ClusterOnboardingModeAdvice.advise(both, throughDarkbloom: true, serving: false)
        #expect(advice == ClusterOnboardingModeAdvice(mode: Self.tp,
            reason: "the longest context here (262,144 tokens; the other serves 65,536)"))
        #expect(advice?.plainLine(model: "Gemma 4 26B") == "Recommended for Gemma 4 26B on these two Macs: Tensor parallel, "
            + "the longest context here (262,144 tokens; the other serves 65,536).")
        #expect(advice?.brief == "longest context")
        // Only the shorter one fits now: it is recommended, as before.
        var tight = both
        tight[0].fitsNow = false
        #expect(ClusterOnboardingModeAdvice.advise(tight, throughDarkbloom: true, serving: false)?.mode == Self.pp)
        // The same context: speed decides, as before.
        var same = both
        same[1].contextTokens = 262_144
        #expect(ClusterOnboardingModeAdvice.advise(same, throughDarkbloom: true, serving: false)
            == ClusterOnboardingModeAdvice(mode: Self.pp, reason: "faster here"))
        // A context not known for every mode (an older leading Mac): speed decides, as before.
        var unknown = both
        unknown[0].contextTokens = nil
        #expect(ClusterOnboardingModeAdvice.advise(unknown, throughDarkbloom: true, serving: false)?.mode == Self.pp)
    }

    /// The question's modes carry what each serves from the plan that loads it, and the recommendation reads it.
    @Test("each offered mode carries the context its plan serves, and the recommendation reads it")
    func theOfferedModesCarryTheirContext() {
        typealias Share = ClusterSetupPlanSummary.Mode.Share
        let tensor = [Share(local: true, firstLayer: 0, endLayer: 30, share: 0.5), Share(local: false, firstLayer: 0, endLayer: 30, share: 0.5)]
        let layers = [Share(local: true, firstLayer: 0, endLayer: 1, share: nil), Share(local: false, firstLayer: 1, endLayer: 30, share: nil)]
        let listed = [ClusterSetupPlanSummary.Mode(mode: Self.tp, shares: tensor, servedDecodeTokensPerSecond: nil),
                      ClusterSetupPlanSummary.Mode(mode: Self.pp, shares: layers, servedDecodeTokensPerSecond: nil)]
        let offered = ClusterSetupPlanning.offered(listed,
            listed: .init(shares: tensor, concurrentRequests: 1, contextTokens: 262_144, promptTokens: 262_143), listedMode: .tensorParallel,
            families: [.pipeline: .init(shares: layers, concurrentRequests: 1, contextTokens: 65_536, promptTokens: 32_768)])
        #expect(offered.map(\.contextTokens) == [262_144, 65_536])
        #expect(offered.map(\.promptTokens) == [262_143, 32_768])
        func plan(_ mode: String, decode: Double) -> ClusterSetupPlanSummary {
            .init(cut: 0, mode: mode, prefillSchedule: "serial", leaderID: "local", ranks: [], promptTokens: 1024, outputTokens: 256,
                  firstTokenSeconds: 1, decodeTokensPerSecond: decode, absolute: true, measured: false, alone: [], aloneAsFast: [],
                  fitsNow: true, needsBytes: nil, explanation: [])
        }
        // The planner predicts the pipeline faster here (pair-2's Gemma right after an update).
        let advice = OnboardingLive.modeAdvice(offered, listed: plan(Self.tp, decode: 60), families: [plan(Self.pp, decode: 90)],
                                               throughDarkbloom: true, serving: false)
        #expect(advice?.mode == Self.tp)
    }

    // MARK: - D3: the Mac left behind by `cluster leave` on the leading Mac

    /// Journey 3: once the Studio left the pair, the MacBook's screen said "degraded: serving on this Mac alone (the
    /// other Mac … is gone; …) (its solo server is still loading)" though nothing ran there: the leave had stopped the
    /// pair. A stopped pair never serves alone, so the screen says what `cluster status` says.
    @Test("a stopped pair whose other Mac is gone says it is stopped, never that it serves alone")
    func aStoppedPairNeverServesAlone() {
        let control = ClusterServiceStatus.Control(leaderID: "macbook", leaderName: "Jonathan's MacBook Pro", term: 4, reason: "",
            leads: true, line: "degraded: serving on this Mac alone (the other Mac (Apple M3 Ultra, 256 GB) is gone; the cluster "
                + "re-forms by itself when it is back)", mode: "alone")
        let stopped = OnboardingLive.awayLines(control, started: false, stopped: "Stopped; last model Qwen 3.8 27B.",
                                               there: "the other Mac (Apple M3 Ultra, 256 GB)", prefix: "", soloNote: { nil })
        #expect(stopped == ["Stopped; last model Qwen 3.8 27B.", "The other Mac (Apple M3 Ultra, 256 GB) isn't answering over the cable."])
        var waiting = control
        waiting.mode = "waiting"
        waiting.line = "the other Mac (Apple M3 Ultra, 256 GB) is gone; this Mac serves Qwen 3.8 27B alone in 9 min unless it returns first"
        #expect(OnboardingLive.awayLines(waiting, started: false, stopped: "Stopped; last model Qwen 3.8 27B.",
                                         there: "the other Mac (Apple M3 Ultra, 256 GB)", prefix: "", soloNote: { nil }) == stopped)
        // A started pair serving alone says so, with its solo server's readiness, as before.
        let alone = OnboardingLive.awayLines(control, started: true, stopped: "Stopped.", there: "the other Mac (Apple M3 Ultra, 256 GB)",
                                             prefix: "", soloNote: { " (its solo server is still loading)" })
        #expect(alone == [control.line + " (its solo server is still loading)."])
    }
}
