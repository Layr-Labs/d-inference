import Foundation
import Testing

@testable import ProviderCore

/// Me first in words (`MeFirstWords`): `darkbloom status` on one Mac ("Serving: …") and a pair's line ("Pair: …"), which
/// the leading Mac's status carries to both Macs. Times are said from now. Journey 2a on pair-2 (J2-i) read "paused
/// since 21:41" over SSH at 05:41 UTC: a clock time in the Mac's own zone, which no line names.
@Suite("Me first in words")
struct MeFirstWordsTests {
    /// 2026-11-06 14:12:00 UTC.
    static let now = Date(timeIntervalSince1970: 1_793_974_320)
    static func ms(_ hour: Int, _ minute: Int, _ second: Int = 0) -> Int64 {
        Int64(1_793_923_200 + hour * 3_600 + minute * 60 + second) * 1_000
    }

    @Test("how long Darkbloom has been paused and when it comes back, from now, for one Mac and for a pair")
    func linesSayHowLongAndUntilWhen() {
        let paused = MeFirstSnapshot(idleMs: 120_000, paused: true, sinceMs: Self.ms(14, 2), lastUseMs: Self.ms(14, 11),
                                     resumesAtMs: Self.ms(14, 13))
        #expect(MeFirstWords.lines(paused, prefix: "Serving: ", now: Self.now) == [
            "Serving: you first — Darkbloom paused for 10 minutes (your last request 1 minute ago; back in about 1 minute if "
                + "you stay idle)",
        ])
        #expect(MeFirstWords.lines(paused, prefix: MeFirstWords.pairPrefix, now: Self.now) == [
            "Pair: you first — Darkbloom paused for 10 minutes (your last request 1 minute ago; back in about 1 minute if "
                + "you stay idle)",
        ])
        // The line under it keeps its words under the first one's.
        let running = MeFirstSnapshot(idleMs: 120_000, paused: true, sinceMs: Self.ms(14, 11, 30), lastUseMs: Self.ms(14, 11, 30),
                                      localRequestsInFlight: 1, darkbloomRequestsFinishing: 2)
        #expect(MeFirstWords.lines(running, prefix: MeFirstWords.pairPrefix, now: Self.now) == [
            "Pair: you first — Darkbloom paused for under a minute (your request is running; back 2 minutes after it ends)",
            "      2 Darkbloom requests are finishing",
        ])
        let open = MeFirstSnapshot(idleMs: 120_000, paused: false, lastUseMs: Self.ms(13, 50))
        #expect(MeFirstWords.lines(open, prefix: MeFirstWords.pairPrefix, now: Self.now) == [
            "Pair: Darkbloom and you, me first — open to Darkbloom (none of your requests in the last 2 minutes)",
        ])
        #expect(MeFirstWords.pairLines(nil, now: Self.now) == [
            "Pair: Darkbloom and you, shared — Darkbloom keeps serving while you use the pair (me first is off)",
        ])
        #expect(MeFirstWords.pairLines(paused, now: Self.now) == MeFirstWords.lines(paused, prefix: "Pair: ", now: Self.now))
    }

    @Test("spans in minutes and hours, how long ago, and the way back")
    func spansAndTheWayBack() {
        #expect(MeFirstWords.span(milliseconds: -5) == "under a minute")
        #expect(MeFirstWords.span(milliseconds: 59_999) == "under a minute")
        #expect(MeFirstWords.span(milliseconds: 60_000) == "1 minute")
        #expect(MeFirstWords.span(milliseconds: 600_000) == "10 minutes")
        #expect(MeFirstWords.span(milliseconds: 3_600_000) == "1 hour")
        #expect(MeFirstWords.span(milliseconds: 3_900_000) == "1 hour 5 minutes")
        #expect(MeFirstWords.span(milliseconds: 7_260_000) == "2 hours 1 minute")
        #expect(MeFirstWords.ago(milliseconds: 59_999) == "under a minute ago")
        #expect(MeFirstWords.ago(milliseconds: 60_000) == "1 minute ago")
        #expect(MeFirstWords.ago(milliseconds: 600_000) == "10 minutes ago")
        #expect(MeFirstWords.back(inMilliseconds: -1_000) == "back any moment now")
        #expect(MeFirstWords.back(inMilliseconds: 0) == "back any moment now")
        #expect(MeFirstWords.back(inMilliseconds: 30_000) == "back in under a minute if you stay idle")
        #expect(MeFirstWords.back(inMilliseconds: 60_000) == "back in about 1 minute if you stay idle")
        #expect(MeFirstWords.back(inMilliseconds: 115_000) == "back in about 2 minutes if you stay idle")
        #expect(MeFirstWords.back(inMilliseconds: 5_400_000) == "back in about 1 hour 30 minutes if you stay idle")
        #expect(MeFirstWords.minutes(1) == "1 minute" && MeFirstWords.minutes(2) == "2 minutes")
        #expect(MeFirstWords.idleMinutes(milliseconds: 1) == 1 && MeFirstWords.idleMinutes(milliseconds: 120_000) == 2)
    }

    /// Owner rule: no speed; and no clock time, which another Mac or an SSH session would read in a zone it doesn't see.
    @Test("no line says a speed or a clock time")
    func noSpeedAndNoClockTime() {
        var lines: [String] = []
        for prefix in ["Serving: ", MeFirstWords.pairPrefix] {
            for running in [0, 1, 3] {
                for finishing in [0, 1, 4] {
                    let snapshot = MeFirstSnapshot(idleMs: 120_000, paused: true, sinceMs: Self.ms(13, 2), lastUseMs: Self.ms(14, 11),
                                                   resumesAtMs: running == 0 ? Self.ms(14, 13) : nil,
                                                   localRequestsInFlight: running, darkbloomRequestsFinishing: finishing)
                    lines += MeFirstWords.lines(snapshot, prefix: prefix, now: Self.now)
                }
            }
            lines += MeFirstWords.lines(MeFirstSnapshot(idleMs: 60_000, paused: false), prefix: prefix, now: Self.now)
        }
        let text = lines.joined(separator: "\n")
        #expect(text.contains("paused for 1 hour 10 minutes"), "\(text)")
        #expect(text.range(of: #"\b[0-9]{1,2}:[0-9]{2}\b"#, options: .regularExpression) == nil, "\(text)")
        #expect(text.range(of: #"/s\b|tok"#, options: .regularExpression) == nil, "\(text)")
    }
}
