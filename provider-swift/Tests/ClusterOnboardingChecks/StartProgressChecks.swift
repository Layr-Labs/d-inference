import Foundation
import Darwin

/// The start's progress both Macs show (owner, 2026-11-04: "The member should show progress throughout each step so it's
/// not just in the dark, maybe a progress bar and so on"): the published fields, the bar, the step rows, the per-Mac
/// rows, and the leading Mac's own screen. Every live row fits its room (the window less 6 columns); a plain window
/// says each change once.
extension OnboardingChecks {
    static func startProgressFieldsAndComponents() {
        typealias P = ClusterOnboardingStartProgress
        typealias W = ClusterOnboardingStartWords
        // The fields: a later build's phase and state read as unknown; unknown keys are ignored; all but the phase optional.
        let later = try? JSONDecoder().decode(P.self, from: Data(#"{"phase":"warming","since":1,"future":true,"parts":[{"rank":0,"state":"cooling","later":1}]}"#.utf8))
        expect(later?.phase == .unknown && later?.parts?.first?.state == .unknown, "fields: later values read as unknown: \(String(describing: later))")
        let bare = try? JSONDecoder().decode(P.self, from: Data(#"{"phase":"copying"}"#.utf8))
        expect(bare == P(.copying), "fields: only the phase is needed")
        let full = P(.loading, parts: [.init(rank: 0, state: .ready, layers: "0–46"), .init(rank: 1, state: .ended, end: "exit 1", restartIn: 5)], since: 10)
        let again = (try? JSONEncoder().encode(full)).flatMap { try? JSONDecoder().decode(P.self, from: $0) }
        expect(again == full, "fields: round trip")
        expect(full.readyParts.map { "\($0.ready)/\($0.of)" } == "1/2", "fields: parts ready, 1 of 2")
        expect(P(.loading).continuing(P(.loading, since: 5), now: 9).since == 5, "fields: the same phase keeps its start")
        expect(P(.testing).continuing(P(.loading, since: 5), now: 9).since == 9, "fields: a new phase starts now")

        // The mark: its process must run; a copy's or load's figures must be fresh; a test's last as long as the process.
        let mark = ClusterOnboardingStartProgressMark(progress: P(.loading), pid: 42, started: 7, at: 100)
        expect(mark.current(now: 110, started: { _ in 7 }) != nil, "mark: fresh, its process runs")
        expect(mark.current(now: 140, started: { _ in 7 }) == nil, "mark: a load not refreshed for 30 s is gone")
        expect(mark.current(now: 110, started: { _ in 8 }) == nil, "mark: another process with that pid")
        let test = ClusterOnboardingStartProgressMark(progress: P(.testing), pid: 42, started: 7, at: 100)
        expect(test.current(now: 400, started: { _ in 7 }) != nil, "mark: a test lasts while its process runs")

        // The bar: real bytes, never 100% before the last byte, fitted to the room.
        expect(W.percent(68_199_999_999, of: 68_200_000_000) == 99 && W.percent(5, of: 5) == 100 && W.percent(1, of: 0) == 0, "bar: percent")
        let wide = W.bar(label: "Copying", done: 29_400_000_000, total: 68_200_000_000, width: 74)
        expect(wide.count <= 74 && wide.hasPrefix("Copying [") && wide.hasSuffix(" 43%  29.4/68.2 GB"), "bar at 80 columns: \(wide)")
        let narrow = W.bar(label: "Copying", done: 29_400_000_000, total: 68_200_000_000, width: 34)
        expect(narrow.count <= 34 && narrow.contains("[") && narrow.contains("43%"), "bar at 40 columns: \(narrow)")
        expect(W.bar(label: "Copying", done: 29_400_000_000, total: 68_200_000_000, width: nil) == "Copying  43%  29.4/68.2 GB", "bar: plain")

        // The rows: from each Mac's side, the same facts; every row fits.
        let parts: [P.Part] = [.init(rank: 0, state: .ready, layers: "0–46"), .init(rank: 1, state: .loading, layers: "47–93")]
        expect(W.partRows(parts, viewerRank: 1, width: nil) == ["This Mac: loading its share (layers 47–93)", "The other Mac: ready (layers 0–46)"],
               "rows: the Mac that joined: \(W.partRows(parts, viewerRank: 1, width: nil))")
        expect(W.partRows(parts, viewerRank: 0, width: nil) == ["This Mac: ready (layers 0–46)", "The other Mac: loading its share (layers 47–93)"],
               "rows: the leading Mac")
        let loading = P(.loading, parts: parts)
        for (columns, viewer) in [(80, 0), (80, 1), (40, 0), (40, 1)] {
            let rows = W.liveRows(loading, viewerLeads: viewer == 0, viewerRank: viewer, darkbloom: true, elapsed: 72, width: columns - 6)
            expect(rows.allSatisfy { $0.count <= columns - 6 }, "rows at \(columns): fit: \(rows)")
            expect(rows.first?.hasPrefix("Load") == true && rows.first?.hasSuffix("1 min 12 s") == true && rows.last == "Next: test, Darkbloom",
                   "rows at \(columns): step, time and next: \(rows)")
        }
        let ended = W.partRow(.init(rank: 1, state: .ended, end: "exit 1", restartIn: 5), viewerRank: 1, width: nil)
        expect(ended == "This Mac: part ended (exit 1); starts again in 5 s", "rows: an ended part: \(ended)")
        let copy = W.liveRows(P(.copying, done: 29_400_000_000, total: 68_200_000_000), viewerLeads: false, viewerRank: 1, darkbloom: false,
                              elapsed: 221, width: 74)
        expect(copy == ["Files: copying from the other Mac \u{00B7} 3 min 41 s",
                        W.bar(label: "Copying", done: 29_400_000_000, total: 68_200_000_000, width: 74), "Next: setup, load, test"],
               "rows: the copy, from the Mac that joined: \(copy)")
        expect(W.liveRows(P(.copying, done: 1, total: 2), viewerLeads: true, viewerRank: 0, darkbloom: false, elapsed: 1, width: nil).first?
                .hasPrefix("Files: copying to the other Mac") == true, "rows: the copy, from the leading Mac")
        expect(W.liveRows(P(.testing), viewerLeads: false, viewerRank: 1, darkbloom: false, elapsed: 3, width: 34)
               == ["Test \u{00B7} 3 s"], "rows: the last step has no next")

        // Plain: each change once; bytes about every 10% and 30 s.
        var log = ClusterOnboardingStartLog(viewerLeads: false, viewerRank: 1)
        var said = log.update(P(.copying, done: 1_000_000_000, total: 10_000_000_000, since: 0), now: 0, plain: true)
        expect(said == ["Files: copying from the other Mac", "Copying  10%  1.0/10.0 GB"], "plain: the copy begins: \(said)")
        said = log.update(P(.copying, done: 2_500_000_000, total: 10_000_000_000), now: 10, plain: true)
        expect(said.isEmpty, "plain: no line before 10% more and 30 s: \(said)")
        said = log.update(P(.copying, done: 2_500_000_000, total: 10_000_000_000), now: 40, plain: true)
        expect(said == ["Copying  25%  2.5/10.0 GB"], "plain: then one: \(said)")
        said = log.update(P(.loading, parts: [.init(rank: 0, state: .loading), .init(rank: 1, state: .starting)]), now: 100, plain: true)
        expect(said == ["\u{2713} Files (1 min 40 s)", "Load: both Macs (0 of 2 parts ready)", "This Mac: starting its part",
                        "The other Mac: loading its share"], "plain: the load begins: \(said)")
        said = log.update(P(.loading, parts: [.init(rank: 0, state: .loading), .init(rank: 1, state: .starting)]), now: 101, plain: true)
        expect(said.isEmpty, "plain: nothing new, nothing said: \(said)")
        said = log.update(P(.loading, parts: [.init(rank: 0, state: .ready), .init(rank: 1, state: .starting)]), now: 130, plain: true)
        expect(said == ["The other Mac: ready"], "plain: a part's change: \(said)")
        var live = ClusterOnboardingStartLog(viewerLeads: false, viewerRank: 1)
        _ = live.update(P(.loading, parts: parts, since: 0), now: 0, plain: false)
        said = live.update(P(.testing), now: 100, plain: false)
        expect(said == ["\u{2713} Load (1 min 40 s)"], "live window: only the steps done are said: \(said)")
        expect(live.finish(succeeded: true, now: 103) == ["\u{2713} Test (3 s)"], "live window: the last step done")
    }

    /// The leading Mac's screen during the load: one row per Mac, fitted at 80 and 40 columns; plain says each row once.
    static func leaderShowsEachMacsPartFitted() {
        let report = "1 of 2 parts ready\nThis Mac: ready (layers 0–46)\nThe other Mac: loading its share (layers 47–93)"
        for columns in [80, 40] as [UInt16] {
            let run = TerminalRun(operations(Recorder(), resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [],
                pairResult: .failed([]), readyReports: [report], readyReportPause: 900_000), environment: colourTerminal, columns: columns)
            expect(run.waitFor(arrowHint), "\(columns) columns: the list"); run.type("\r")
            expect(run.waitFor(columns == 80 ? "The other Mac: loading its share (layers 47–93) \u{00B7} " : "\u{1B}[2mOther Mac: loading its share \u{00B7} "),
                   "\(columns) columns: the other Mac's row")
            _ = run.finish()
            let dim = run.text.components(separatedBy: "\u{1B}[2m").dropFirst().compactMap { $0.components(separatedBy: "\u{1B}[0m").first }
            let rows = dim.filter { $0.contains("Mac: ") }
            expect(!rows.isEmpty && rows.allSatisfy { !$0.contains("\u{2026}") && $0.count <= Int(columns) - 6 },
                   "\(columns) columns: each Mac's row fits its room, shortened rather than cut: \(rows)")
        }
        let plain = TerminalRun(operations(Recorder(), resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [],
            pairResult: .failed([]), readyReports: [report, report, "2 of 2 parts ready\nThis Mac: ready (layers 0–46)\nThe other Mac: ready (layers 47–93)"],
            readyReportPause: 200_000))
        expect(plain.waitFor(prompt(2)), "plain: the list"); plain.type("\r")
        _ = plain.finish()
        // Each wait says each row once: the parts' first load, and their restart as cluster members after the registration.
        let waits = plain.text.components(separatedBy: "Starting both Macs' parts again")
        for row in ["  The other Mac: loading its share (layers 47–93)\n", "  This Mac: ready (layers 0–46)\n", "  The other Mac: ready (layers 47–93)\n"] {
            expect(waits.allSatisfy { $0.components(separatedBy: row).count == 2 }, "plain: said once per wait: \(row) in \(plain.text)")
        }
    }

    /// The Mac that joined an M5 Max leader whose status publishes the start: a copy of 68.2 GB, then the load.
    static func followingTheStart(followSeconds: Double = 900) -> ClusterOnboardingOperations {
        typealias P = ClusterOnboardingStartProgress
        let parts: [P.Part] = [.init(rank: 0, state: .ready, layers: "0–46"), .init(rank: 1, state: .loading, layers: "47–93")]
        let starts: [P?] = [nil, nil] + (0..<15).map { P(.copying, done: Int64(25 + $0) * 1_000_000_000, total: 68_200_000_000) }
            + [P(.loading, parts: [.init(rank: 0, state: .loading, layers: "0–46"), .init(rank: 1, state: .starting, layers: "47–93")])]
            + Array(repeating: P(.loading, parts: parts), count: 400)
        var made = operations(Recorder(), pairEvents: memberEvents, pairResult: .paired(role: .member, peerName: m5Max),
                              statusSequence: [["Stopped."], ["Loading Qwen 3.6 235B: 1 of 2 parts ready."]], followSeconds: followSeconds)
        let looks = Recorder(), status = made.status
        made.leaderStatus = {
            looks.note("look")
            return .init(lines: status(), step: .init(.starting), start: starts[min(looks.all.count, starts.count) - 1])
        }
        made.thisRank = { 1 }
        return made
    }

    /// The Mac that joined shows the start under its own heading: the step and its time, a bar of the real bytes during
    /// the copy, then each Mac's part, this Mac first; every live row fits at 80 and 40 columns; plain says each change once.
    static func theJoinedMacShowsTheStartsProgress() {
        for columns: UInt16 in [80, 40] {
            let run = TerminalRun(followingTheStart(), environment: colourTerminal, columns: columns)
            defer { run.release() }
            expect(run.waitFor(codeQuestion), "joined, \(columns) columns: the code"); run.type("y")
            expect(run.waitFor("4/4 Start"), "joined, \(columns) columns: the start's heading")
            expect(run.waitFor("%"), "joined, \(columns) columns: the copy's bar")
            expect(run.waitFor(columns == 80 ? "This Mac: loading its share (layers 47–93)" : "This Mac: loading its share", seconds: 20),
                   "joined, \(columns) columns: this Mac's part")
            _ = run.waitFor("never shown", seconds: 0.4)
            run.type("q")
            _ = run.finish()
            let rows = visible(run.text)
            let live = liveRows(run.text)
            expect(!live.isEmpty && live.allSatisfy { $0.count <= Int(columns) - 1 }, "joined, \(columns) columns: every live row fits: \(live.filter { $0.count > Int(columns) - 1 })")
            let text = run.text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
            expect(text.contains("Files: copying from the other Mac") || text.contains("Files: copying"), "joined, \(columns) columns: the copy's step")
            expect(text.contains("[\u{2588}"), "joined, \(columns) columns: a bar of the bytes")
            expect(rows.contains { $0.hasPrefix("  \u{2713} Files (") }, "joined, \(columns) columns: the copy done, said once: \(rows)")
            expect(text.contains("The other Mac: ready") || text.contains("Other Mac: ready"), "joined, \(columns) columns: the other Mac's part")
            transcript("joined-start-\(columns)-columns", rows.joined(separator: "\n"), keys: run.keys)
        }
        let plain = PipeRun(followingTheStart(followSeconds: 4), environment: ["TERM": "dumb"])
        plain.type("y")
        _ = plain.finish(seconds: 30)
        let lines = plain.text.components(separatedBy: "\n")
        for line in ["4/4 Start", "  Files: copying from the other Mac", "  \u{2713} Files", "  This Mac: loading its share (layers 47–93)",
                     "  The other Mac: ready (layers 0–46)"] {
            expect(lines.filter { $0.hasPrefix(line) }.count == 1, "joined, plain: said once: \(line) in \(plain.text)")
        }
        expect(lines.contains { $0.hasPrefix("  Copying  ") && $0.contains("/68.2 GB") }, "joined, plain: the copy's bytes")
        expect(!plain.text.contains("\u{1B}") && !plain.text.contains("\u{2588}"), "joined, plain: no live rows, no bar")
        transcript("joined-start-plain", plain.text, keys: 1)
    }
}
