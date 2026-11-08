import Foundation
import Testing

@testable import ProviderCore

/// Journey 2a on pair-2 (DevNet `.144`, `validation-evidence/journey-2a.md`, steps 3 and 5): what the status both Macs
/// read says while the pair starts, and while it serves Both, me first and is paused for its owner.
@Suite("journey 2a: the pair's status while it starts and while it is paused")
struct ClusterPairStatusWordsTests {
    typealias Apple = ClusterOnboardingAppleCheck
    /// 2026-11-06 14:12:00 UTC.
    static let now: Double = 1_793_974_320
    static let other = "the other Mac (Apple M5 Max, 128 GB)"

    static func mac(_ name: String, _ verified: Bool?, ranFor seconds: Double? = 20, retryAt: Double? = nil) -> Apple.Mac {
        Apple.Mac(name: name, verified: verified, retryAt: retryAt, startedAt: seconds.map { now - $0 })
    }

    /// J2-c: every healthy 45-second start said "This Mac isn't verified by Apple yet; Darkbloom retries by itself within
    /// minutes. Don't restart either Mac until then.", for both Macs. A part's App Attest authorization lands about a
    /// minute after it registers, so the coordinator's first trust status for a new part carries none: the check is
    /// under way. The warning is for a check that is slow or held back.
    @Test("Apple's check of new parts is progress; the warning waits until a Mac's check is slow or held back")
    func appleCheckIsProgressUntilSlow() {
        #expect(Apple.look([Self.mac("this Mac", false), Self.mac(Self.other, false)], now: Self.now)
            == .checking("checking both Macs with Apple"))
        #expect(Apple.look([Self.mac("this Mac", true), Self.mac(Self.other, false)], now: Self.now)
            == .checking("checking \(Self.other) with Apple"))
        #expect(Apple.look([Self.mac("this Mac", false, ranFor: 119), Self.mac(Self.other, true)], now: Self.now)
            == .checking("checking this Mac with Apple"))
        // Slow: two minutes without it, the usual minute twice over. That Mac is named, even while the other is new.
        #expect(Apple.look([Self.mac("this Mac", true), Self.mac(Self.other, false, ranFor: 121)], now: Self.now)
            == .slow(ClusterOnboardingNotServing.notVerified(Self.other)))
        #expect(Apple.look([Self.mac("this Mac", false), Self.mac(Self.other, false, ranFor: 300)], now: Self.now)
            == .slow(ClusterOnboardingNotServing.notVerified(Self.other)))
        // Held back: this Mac's key-generation safeguard says when it may try again.
        let retry = Self.now + 600
        #expect(Apple.look([Self.mac("this Mac", false, retryAt: retry), Self.mac(Self.other, false)], now: Self.now)
            == .slow(ClusterOnboardingNotServing.notVerified("this Mac", retryAt: Date(timeIntervalSince1970: retry))))
        // When its part started is unknown (an older build's status), as before: the warning.
        #expect(Apple.look([Self.mac("this Mac", false, ranFor: nil), Self.mac(Self.other, true)], now: Self.now)
            == .slow(ClusterOnboardingNotServing.notVerified("this Mac")))
        // Verified, or no trust status sent yet: nothing to say.
        #expect(Apple.look([Self.mac("this Mac", true), Self.mac(Self.other, nil)], now: Self.now) == .verified)
        #expect(Apple.look([], now: Self.now) == .verified)
    }

    /// The progress takes the status line's reason place, as the coordinator's pairing does; `cluster status` reads it
    /// as loading on both Macs, and the Mac that joined, following the leading Mac's start, says it as it is.
    @Test("the check's words in the status, on the Mac that joined, and never read as the warning")
    func appleCheckWordsAreRead() {
        let line = ClusterOnboardingNotServing.statusLine(model: "Qwen 3.8 27B", reason: "checking both Macs with Apple")
        #expect(line == "Qwen 3.8 27B is not serving yet: checking both Macs with Apple.")
        #expect(Apple.isChecking("checking both Macs with Apple") && Apple.isChecking("checking \(Self.other) with Apple"))
        #expect(!Apple.isChecking(ClusterOnboardingNotServing.notVerified("this Mac")))
        #expect(!Apple.isChecking("waiting for the coordinator to pair both Macs"))
        #expect(ClusterOnboardingDriver.offeredWaitingWords("checking both Macs with Apple") == "Checking both Macs with Apple")
        #expect(ClusterOnboardingDriver.offeredWaitingWords("checking this Mac with Apple") == "Checking this Mac with Apple")
        #expect(ClusterOnboardingNotServing.remedy(forReason: "checking both Macs with Apple") == nil)
    }

    /// J2-h: while the pair was paused for its owner, the Mac that follows said only "✓ Serving … through Darkbloom". The
    /// status every Mac reads is the leading Mac's (`OnboardingLive.localStatus`); it carries me first, read from this
    /// Mac's part when it runs the pair's API (rank 0): one read of that part's state file per status, nothing per request.
    @Test("the status of the Mac whose part runs the pair's API carries the pause; nothing elsewhere or for the other ways to serve")
    func statusCarriesThePause() {
        let paused = MeFirstSnapshot(idleMs: 120_000, paused: true, sinceMs: Int64(Self.now - 60) * 1_000,
                                     lastUseMs: Int64(Self.now - 5) * 1_000, resumesAtMs: Int64(Self.now + 115) * 1_000)
        let both = ClusterServingScope.publicServingWithLocalAPI(bind: "127.0.0.1")
        func own(rankZero: Bool = true, pid: Int32? = 4_242, running: Bool = true) -> ClusterServiceStatus {
            ClusterServiceStatus(role: "leader", serving: true, modelName: "m", sessionLeader: rankZero, localRank: rankZero ? 0 : 1,
                                 setup: nil, child: .init(running: running, starts: 1, pid: pid), session: nil)
        }
        let state = DaemonState(pid: 4_242, version: "test", writtenAt: 0, startedAt: 0, meFirst: paused)
        let now = Date(timeIntervalSince1970: Self.now)
        #expect(OnboardingLive.pauseLines(scope: both, own: own(), state: state, now: now) == [
            "Pair: you first — Darkbloom paused for 1 minute (your last request under a minute ago; back in about 2 minutes "
                + "if you stay idle)",
        ])
        #expect(OnboardingLive.pauseLines(scope: .publicServing, own: own(), state: state, now: now).isEmpty, "Darkbloom network")
        #expect(OnboardingLive.pauseLines(scope: .localOnly(bind: "0.0.0.0"), own: own(), state: state, now: now).isEmpty, "Only me")
        #expect(OnboardingLive.pauseLines(scope: nil, own: own(), state: state, now: now).isEmpty, "no saved setup")
        #expect(OnboardingLive.pauseLines(scope: both, own: own(rankZero: false), state: state, now: now).isEmpty, "the other part")
        #expect(OnboardingLive.pauseLines(scope: both, own: own(pid: 7), state: state, now: now).isEmpty, "another process's state")
        #expect(OnboardingLive.pauseLines(scope: both, own: own(running: false), state: state, now: now).isEmpty, "no part running")
        #expect(OnboardingLive.pauseLines(scope: both, own: nil, state: state, now: now).isEmpty)
        #expect(OnboardingLive.pauseLines(scope: both, own: own(), state: nil, now: now).isEmpty)
        // `[local] me_first = false` on the leading Mac: Darkbloom keeps serving, and every Mac says so too.
        var off = state
        off.meFirst = nil
        #expect(OnboardingLive.pauseLines(scope: both, own: own(), state: off, now: now) == [
            "Pair: Darkbloom and you, shared — Darkbloom keeps serving while you use the pair (me first is off)",
        ])
    }
}
