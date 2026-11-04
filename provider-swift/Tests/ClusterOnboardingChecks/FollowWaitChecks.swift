import Foundation
import Darwin

/// The joining Mac's wait for the leading Mac (a user's report, 2026-11-04: "an infinite loop of waiting for the other
/// Mac, Apple M5 Max 128 GB"): it says what the leading Mac waits on and how long of the bound, its live line never
/// wraps (a wrapped redraw left a new line each time), a plain transcript says each state once, a leader that refused
/// every model ends the wait at once with its ✗, and every end is a ✗ with what to do. The leader's own Local Network
/// wait has a bound too.
extension OnboardingChecks {
    static func followWaitChecks() {
        theFollowLineFitsEveryWidthAndKeepsItsTimer()
        theLeaderStepReadsAndCountsAsPublished()
        theJoinedMacSaysWhatTheLeaderWaitsOnAtEachWidth()
        aNarrowedWindowNeverWrapsTheLiveLine()
        aPlainTranscriptSaysEachStateOnce()
        aLeaderThatRefusesEveryModelEndsTheWaitAtOnce()
        anOlderLeaderKeepsTheGenericWordsAndTheWaitEndsWithACross()
        theLeadersLocalNetworkWaitIsBoundedAndSaysWhereToTurnItOn()
        theLeaderPublishesEachStepAndItsRefusal()
    }

    static let m5Max = "Apple M5 Max, 128 GB"
    static let m5MaxNamed = ClusterOnboardingMacName.other(named: m5Max)
    static let localNetworkSaid = "  The other Mac (Apple M5 Max, 128 GB): it's waiting for Allow on its Local Network prompt."
    static let modelListSaid = "  The other Mac (Apple M5 Max, 128 GB): it's waiting for a model to be chosen on its screen."

    /// The Mac that joined an M5 Max leader whose status publishes `steps` in turn (the last one repeats; empty: an older
    /// leader that publishes none).
    static func followingTheM5Max(steps: [ClusterOnboardingLeaderStep?], status: [[String]] = [["Stopped."]], followSeconds: Double = 900,
                                  thisVersion: String? = nil) -> ClusterOnboardingOperations {
        var made = operations(Recorder(), pairEvents: memberEvents, pairResult: .paired(role: .member, peerName: m5Max),
                              statusSequence: status, followSeconds: followSeconds)
        let looks = Recorder(), status = made.status
        if !steps.isEmpty {
            made.leaderStatus = {
                looks.note("look")
                return .init(lines: status(), step: steps[min(looks.all.count, steps.count) - 1])
            }
        }
        made.thisVersion = thisVersion
        return made
    }

    /// The live rows a terminal drew (each redraw's text after its return), escapes removed.
    static func liveRows(_ raw: String) -> [String] {
        raw.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
            .map { $0.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression) }
            .filter { row in ClusterOnboardingBrand.spinner.contains { row.contains($0) } }
    }

    static func theFollowLineFitsEveryWidthAndKeepsItsTimer() {
        let steps: [ClusterOnboardingLeaderStep?] = [nil, .init(.localNetwork), .init(.reading), .init(.tryAgain), .init(.modelList),
            .init(.copy), .init(.login), .init(.starting), .init(.refused, reason: ClusterOnboardingLeaderStep.differentBuildsReason), .init(.unknown)]
        for step in steps {
            for width in 1...160 {
                let line = ClusterOnboardingDriver.followWaitingLine(m5Max, step: step, waited: 754, bound: 900, width: width)
                if line.count > width { expect(false, "follow line \(String(describing: step?.kind)) at \(width): \(line)"); break }
                if width >= 24, !line.hasSuffix("12 of 15 min") && !line.hasSuffix("(q leaves)") {
                    expect(false, "follow line keeps its timer at \(width): \(line)"); break
                }
            }
        }
        expect(ClusterOnboardingDriver.followWaitingLine(m5Max, step: .init(.localNetwork), waited: 130, bound: 900, width: nil)
            == "Waiting for the other Mac (Apple M5 Max, 128 GB): it's waiting for Allow on its Local Network prompt · 2 of 15 min (q leaves)",
               "follow line, whole: who, what it waits on, how long of the bound")
        expect(ClusterOnboardingDriver.followWaitingLine(m5Max, step: nil, waited: 40, bound: 900, width: nil)
            == "Waiting for the other Mac (Apple M5 Max, 128 GB) to choose the model and start · 40 s of 15 min (q leaves)",
               "follow line, an older leader: the generic words")
        expect(ClusterOnboardingDriver.followWaitingLine(m5Max, step: .init(.localNetwork), waited: 130, bound: 900, width: 74)
            == "Waiting for the other Mac: Allow on its screen · 2 of 15 min", "follow line at 80 columns: short words, the timer kept")
        expect(ClusterOnboardingDriver.followWaitingLine(m5Max, step: .init(.localNetwork), waited: 130, bound: 900, width: 34)
            == "Waiting · 2 of 15 min", "follow line at 40 columns: the timer alone")
    }

    static func theLeaderStepReadsAndCountsAsPublished() {
        let decoded = try? JSONDecoder().decode(ClusterOnboardingLeaderStep.self, from: Data(#"{"kind":"aLaterStep","version":"0.11.0"}"#.utf8))
        expect(decoded?.kind == .unknown && decoded?.words == nil, "a step a later build adds reads as unknown, said as nothing")
        let older = ClusterOnboardingLeaderStep.isOlder
        expect(older("0.10.8", "0.10.9") == true && older("0.10.10", "0.10.9") == false && older("0.10.9", "0.10.9") == false
               && older("0.10", "0.10.1") == true && older("dev", "0.10.9") == nil, "versions compare as numbers")
        let step = ClusterOnboardingLeaderStepMark(step: .init(.modelList), pid: 42, started: 7, at: 1_000)
        expect(step.current(now: 9_999, started: { $0 == 42 ? 7 : nil }) == .init(.modelList), "a step counts while its screen runs")
        expect(step.current(now: 1_001, started: { _ in 8 }) == nil, "a pid another process has never counts")
        expect(step.current(now: 1_001, started: { _ in nil }) == nil, "a closed screen's step never counts")
        let refused = ClusterOnboardingLeaderStepMark(step: .init(.refused, reason: "x"), pid: 42, started: 7, at: 1_000)
        expect(refused.current(now: 2_000, started: { _ in nil })?.kind == .refused, "a refusal outlives the screen that ended with it")
        expect(refused.current(now: 1_000 + ClusterOnboardingLeaderStepMark.refusalSeconds, started: { _ in nil }) == nil, "for a while only")
    }

    static func theJoinedMacSaysWhatTheLeaderWaitsOnAtEachWidth() {
        // One look per turn of the wait (its key poll is 120 ms): about 2 s at Allow, then the model list.
        let steps: [ClusterOnboardingLeaderStep?] = [nil] + Array(repeating: .init(.localNetwork), count: 15) + [.init(.modelList)]
        for columns: UInt16 in [132, 80, 40] {
            let run = TerminalRun(followingTheM5Max(steps: steps), environment: colourTerminal, columns: columns)
            defer { run.release() }
            expect(run.waitFor(codeQuestion), "\(columns) columns: the code"); run.type("y")
            expect(run.waitFor("it's waiting for a model to be chosen on its screen.", seconds: 20), "\(columns) columns: the model list said")
            _ = run.waitFor("never shown", seconds: 0.4)
            run.type("q")
            expect(run.finish() == 0, "\(columns) columns: q leaves")
            let screen = visible(run.text)
            expect(screen.filter { $0 == localNetworkSaid }.count == 1 && screen.filter { $0 == modelListSaid }.count == 1,
                   "\(columns) columns: each step said once: \(screen)")
            let rows = liveRows(run.text)
            let wide = rows.filter { $0.count > Int(columns) - 1 }
            expect(!rows.isEmpty && wide.isEmpty, "\(columns) columns: every live row fits the window: \(wide)")
            expect(rows.contains { $0.contains("of 15 min") }, "\(columns) columns: the live row says how long of the bound: \(rows.suffix(3))")
            if columns == 132 {
                expect(rows.contains { $0.contains("Waiting for the other Mac (Apple M5 Max, 128 GB): it's waiting for Allow on its Local Network prompt") },
                       "132 columns: the whole line: \(rows.suffix(3))")
            }
            transcript("follow-wait-\(columns)-columns", screen.joined(separator: "\n"), keys: run.keys)
        }
    }

    static func aNarrowedWindowNeverWrapsTheLiveLine() {
        let run = TerminalRun(followingTheM5Max(steps: [nil, .init(.localNetwork)]), environment: colourTerminal, columns: 132)
        defer { run.release() }
        expect(run.waitFor(codeQuestion), "narrowed: the code"); run.type("y")
        expect(run.waitFor(localNetworkSaid), "narrowed: the step said")
        _ = run.waitFor("never shown", seconds: 0.3)
        let before = run.text.count
        var window = winsize(ws_row: 50, ws_col: 40, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(run.master, TIOCSWINSZ, &window)
        _ = run.waitFor("never shown", seconds: 0.6)
        run.type("q")
        expect(run.finish() == 0, "narrowed: q leaves")
        let after = liveRows(String(run.text.dropFirst(before)))
        expect(!after.isEmpty && after.allSatisfy { $0.count <= 39 }, "narrowed: the live rows fit the new width: \(after.suffix(3))")
    }

    static func aPlainTranscriptSaysEachStateOnce() {
        // The status goes back and forth (P2-7's alternating lines); the steps too.
        let flapping: [ClusterOnboardingLeaderStep?] = [nil] + Array(repeating: [.init(.localNetwork), .init(.modelList)], count: 30).flatMap { $0 }
        for environment in [["TERM": "dumb"], ["NO_COLOR": "1", "TERM": "xterm-256color"]] {
            let run = PipeRun(followingTheM5Max(steps: flapping, followSeconds: 1.5), environment: environment)
            run.type("y")
            expect(run.finish(seconds: 20) == 1, "plain \(environment): the bound ends with ✗")
            let lines = run.text.components(separatedBy: "\n")
            expect(lines.filter { $0 == localNetworkSaid }.count == 1 && lines.filter { $0 == modelListSaid }.count == 1,
                   "plain \(environment): each state said once, never per tick: \(run.text)")
            expect(!run.text.contains("\u{1B}") && !run.text.contains("Waiting for the other Mac (Apple M5 Max, 128 GB): it's"),
                   "plain \(environment): no live line, no escapes: \(run.text)")
            transcript("follow-wait-plain-\(environment["TERM"] ?? "")", run.text, keys: 1)
        }
        let ending = "Loading Qwen 3.8 27B: 1 of 2 parts ready (this Mac's part ended (exit 1: boom) and starts again by itself)."
        let loading = "Loading Qwen 3.8 27B: 1 of 2 parts ready."
        let back = PipeRun(followingTheM5Max(steps: [], status: [["Stopped."]] + Array(repeating: [[loading], [ending]], count: 20).flatMap { $0 },
                                             followSeconds: 1), environment: ["TERM": "dumb"])
        back.type("y")
        _ = back.finish(seconds: 20)
        let said = back.text.components(separatedBy: "\n")
        expect(said.filter { $0 == "  The other Mac: " + String(ending.dropLast()) + "." }.count == 1
               && said.filter { $0 == "  The other Mac: " + String(loading.dropLast()) + "." }.count == 1,
               "plain: a status that goes back and forth is said once per line: \(back.text)")
    }

    static func aLeaderThatRefusesEveryModelEndsTheWaitAtOnce() {
        func refused(_ version: String?) -> [ClusterOnboardingLeaderStep?] {
            [nil, .init(.reading, version: version), .init(.refused, reason: ClusterOnboardingLeaderStep.differentBuildsReason, version: version)]
        }
        let behind = TerminalRun(followingTheM5Max(steps: refused("0.10.10"), thisVersion: "0.10.9"))
        defer { behind.release() }
        expect(behind.waitFor(codeQuestion), "builds: the code"); behind.type("y")
        let began = Date()
        expect(behind.finish() == 1, "builds: not success")
        expect(Date().timeIntervalSince(began) < 5, "builds: at once, not after the bound")
        expect(behind.text.hasSuffix(block("\u{2717}", "Not serving: The two Macs run different Darkbloom builds.",
            ["This Mac runs Darkbloom 0.10.9; the other Mac (Apple M5 Max, 128 GB) runs 0.10.10.", "On this Mac, run `darkbloom update`.",
             "Then run `darkbloom cluster` on the other Mac (Apple M5 Max, 128 GB) again; this Mac follows it by itself."])),
               "builds: the ✗, both versions, and the Mac to update: \(behind.text)")
        transcript("follow-wait-different-builds", behind.text, keys: behind.keys)
        let ahead = TerminalRun(followingTheM5Max(steps: refused("0.10.9"), thisVersion: "0.10.10"))
        defer { ahead.release() }
        expect(ahead.waitFor(codeQuestion), "builds, leader behind: the code"); ahead.type("y")
        expect(ahead.finish() == 1 && ahead.text.contains("  On the other Mac (Apple M5 Max, 128 GB), run `darkbloom update`.\n"),
               "builds, leader behind: update that Mac: \(ahead.text)")
        let unknown = TerminalRun(followingTheM5Max(steps: refused(nil)))
        defer { unknown.release() }
        expect(unknown.waitFor(codeQuestion), "builds, no versions: the code"); unknown.type("y")
        expect(unknown.finish() == 1 && unknown.text.contains("  Run `darkbloom --version` on both Macs, and `darkbloom update` on the one that's behind.\n"),
               "builds, no versions: check both: \(unknown.text)")
        let other = TerminalRun(followingTheM5Max(steps: [nil, .init(.refused, reason: "not supported on a cluster yet")]))
        defer { other.release() }
        expect(other.waitFor(codeQuestion), "refused: the code"); other.type("y")
        expect(other.finish() == 1 && other.text.contains("\u{2717} Not serving: The other Mac (Apple M5 Max, 128 GB) can't start a model: not supported on a cluster yet.\n"),
               "refused: the leader's reason: \(other.text)")
    }

    static func anOlderLeaderKeepsTheGenericWordsAndTheWaitEndsWithACross() {
        let run = TerminalRun(followingTheM5Max(steps: [], followSeconds: 1.2), environment: colourTerminal, columns: 132)
        defer { run.release() }
        expect(run.waitFor(codeQuestion), "older leader: the code"); run.type("y")
        expect(run.finish() == 1, "older leader: the bound ends, not success")
        let rows = liveRows(run.text)
        expect(rows.contains { $0.contains("Waiting for the other Mac (Apple M5 Max, 128 GB) to choose the model and start \u{00B7} ") && $0.contains("(q leaves)") },
               "older leader: the generic words with the timer: \(rows.suffix(2))")
        let screen = visible(run.text).joined(separator: "\n")
        expect(screen.contains("\u{2717} Not serving: The other Mac (Apple M5 Max, 128 GB) didn't start a model within 0 minutes.\n"
            + "  Last: Stopped.\n"
            + "  On the other Mac (Apple M5 Max, 128 GB): look at its screen and answer what it asks (Allow, the model list, a login), or run `darkbloom cluster` there again.\n"
            + "  If it still doesn't start, run `darkbloom --version` on both Macs; if they differ, run `darkbloom update` on the one that's behind.\n"),
               "older leader: ✗, the last status and what to do: \(screen)")
        expect(screen.hasSuffix(ClusterOnboardingDriver.notStartedAfterLine + "\n"), "older leader: nothing stops here: \(screen)")
        transcript("follow-wait-older-leader", screen, keys: run.keys)
    }

    static func theLeadersLocalNetworkWaitIsBoundedAndSaysWhereToTurnItOn() {
        let published = Recorder()
        var made = operations(Recorder(), pairEvents: leaderEvents, pairResult: .paired(role: .leader, peerName: "Apple M3 Ultra, 256 GB"),
                              localNetwork: { $0 == .service ? .blocked : .allowed })
        made.localNetworkWaitSeconds = 1.5
        made.publishStep = { published.note($0?.kind.rawValue ?? "none") }
        let run = TerminalRun(made, environment: colourTerminal, columns: 80)
        defer { run.release() }
        expect(run.waitFor(codeQuestion), "Allow bound: the code"); run.type("y")
        expect(run.finish() == 1, "Allow bound: ends, not success")
        let screen = visible(run.text).joined(separator: "\n")
        expect(screen.contains("\u{2717} Local Network access is off for Darkbloom: no Allow within 0 minutes.\n"
            + "  On this Mac: System Settings → Privacy & Security → Local Network → turn on “Darkbloom” (on a Mac with no display, through Screen Sharing).\n"
            + "  If “Darkbloom” isn't listed, macOS asks on this Mac's screen the next time it connects over the cable: run `darkbloom cluster` again and click Allow.\n"),
               "Allow bound: ✗, where to turn it on, and the case with no row: \(screen)")
        expect(liveRows(run.text).contains { $0.contains("Waiting for Allow \u{00B7} ") && $0.contains("of 0 min") }, "Allow bound: a visible timer")
        expect(published.all == ["localNetwork"], "Allow bound: the other Mac can say it: \(published.all)")
        transcript("leader-allow-bound", screen, keys: run.keys)
    }

    static func theLeaderPublishesEachStepAndItsRefusal() {
        let published = Recorder()
        var made = operations(Recorder(), pairEvents: leaderEvents, pairResult: .paired(role: .leader, peerName: "Apple M3 Ultra, 256 GB"))
        made.publishStep = { published.note($0?.kind.rawValue ?? "none") }
        let run = TerminalRun(made)
        defer { run.release() }
        expect(run.waitFor(codeQuestion), "steps: the code"); run.type("y")
        expect(run.waitFor("  " + prompt(2), count: 2), "steps: the model list"); run.type("\r")
        expect(run.finish() == 0, "steps: served")
        expect(published.all == ["reading", "modelList", "starting"], "steps: each published in turn: \(published.all)")

        let refused = Recorder()
        let blocked = choices.map { choice -> ClusterOnboardingModelChoice in
            var choice = choice
            choice.blocker = ClusterOnboardingLeaderStep.differentBuildsReason
            return choice
        }
        var builds = operations(Recorder(), pairEvents: leaderEvents, pairResult: .paired(role: .leader, peerName: "Apple M3 Ultra, 256 GB"),
                                choices: blocked)
        builds.publishStep = { step in refused.note((step?.kind.rawValue ?? "none") + (step?.differentBuilds == true ? " builds" : "")) }
        let leader = TerminalRun(builds)
        defer { leader.release() }
        expect(leader.waitFor(codeQuestion), "builds, leader: the code"); leader.type("y")
        expect(leader.finish() == 1, "builds, leader: not success")
        expect(refused.all == ["reading", "refused builds"], "builds, leader: the refusal published: \(refused.all)")
        expect(leader.text.contains(block("\u{2717}", "Not serving: The two Macs run different Darkbloom builds.",
            ["Run `darkbloom --version` on both Macs, and `darkbloom update` on the one that's behind.", "Then run `darkbloom cluster` here again."])),
               "builds, leader: the same ✗ with what to do: \(leader.text)")
        transcript("leader-different-builds", leader.text, keys: leader.keys)
    }
}

/// Every live row is one row of the window: the 0.10.8 leader's "Loading Gemma 4 26B on both Macs (starting; this
/// Mac's part ended (exit 1: another update operation owns the lock (pid 952 …" repeated end to end, each petal turn
/// leaving the wrapped start of the last one behind.
extension OnboardingChecks {
    static func liveLineChecks() {
        aLongReasonIsShortenedNeverWrapped()
        theUsersLoadingLineStaysOneRow()
    }

    /// The user's reason, as the leader's wait reports it (a part's error can carry a newline or a tab).
    static let usersLoadingReport = "starting; this Mac's part ended (exit 1: another update operation owns the lock (pid 952)) and starts again "
        + "by itself; the other Mac's part ended (exit 1: memory_gate_refused source=follower\nTensor-parallel shard load\tneeds 49.08 GiB) "
        + "and starts again by itself"

    static func aLongReasonIsShortenedNeverWrapped() {
        let head = "Loading Gemma 4 26B on both Macs (" + usersLoadingReport + ") \u{00B7} 1 min 3 s"
        for room in 1...140 {
            let row = ClusterOnboardingBrand.liveText(head, room: room)
            if ClusterOnboardingBrand.textColumns(row) > room || row.contains("\n") || row.contains("\t") {
                expect(false, "live text at \(room): \(row)"); break
            }
        }
        let at80 = ClusterOnboardingBrand.liveText(head, room: 74)
        expect(at80.hasPrefix("Loading Gemma 4 26B on both Macs (starting; this Mac's part e") && at80.hasSuffix("\u{2026} \u{00B7} 1 min 3 s"),
               "80 columns: the reason is shortened and the time kept: \(at80)")
        expect(ClusterOnboardingBrand.liveText("a\n\tb   c\u{1B}[31m", room: 40) == "a  b   c [31m", "each control character becomes a space; spaces stay (a layout's columns)")
        expect(ClusterOnboardingBrand.liveText("模型加载中模型加载中", room: 7) == "模型加", "a wide character counts two columns")
    }

    static func theUsersLoadingLineStaysOneRow() {
        for columns: UInt16 in [80, 40] {
            let recorder = Recorder()
            let gemma = [ClusterOnboardingModelChoice(title: "Gemma 4 26B", lines: ["14.9 GB · tensor parallel"], blocker: nil,
                                                      validated: true, split: "tensor parallel")]
            let made = operations(recorder, resume: .init(role: .leader, peerName: "Apple M4 Max, 128 GB"), pairEvents: [], pairResult: .failed([]),
                                  choices: gemma, readyReports: [usersLoadingReport], readyReportPause: 900_000)
            // Animated, so the petal turns while the reason stays: each turn is a redraw.
            let run = TerminalRun(made, environment: ["TERM": "xterm-256color", "LANG": "en_US.UTF-8"], columns: columns)
            defer { run.release() }
            expect(run.waitFor("enter select"), "\(columns) columns: the model list"); run.type("\r")
            expect(run.finish(seconds: 20) == 0, "\(columns) columns: served")
            let raw = run.text
            let draws = raw.components(separatedBy: ClusterOnboardingBrand.noWrap).dropFirst()
            let loading = draws.filter { $0.contains("Loading Gemma 4 26B") }
            expect(loading.count >= 4, "\(columns) columns: the petal turned while the reason stayed: \(loading.count)")
            expect(draws.allSatisfy { $0.contains(ClusterOnboardingBrand.wrap) }, "\(columns) columns: line wrap back on in the same write")
            let rows = draws.flatMap { draw in
                (draw.components(separatedBy: ClusterOnboardingBrand.wrap).first ?? "").components(separatedBy: "\n")
                    .map { $0.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression) }
            }
            let wide = rows.filter { ClusterOnboardingBrand.textColumns($0) > Int(columns) - 1 }
            expect(!rows.isEmpty && wide.isEmpty, "\(columns) columns: every live row fits the window: \(wide)")
            expect(loading.allSatisfy { !$0.contains("\t") }, "\(columns) columns: no tab in a live row")
            if columns == 80 {
                expect(rows.contains { $0.contains("Loading Gemma 4 26B on both Macs (starting; this Mac's part") && $0.contains("\u{2026} \u{00B7} ") },
                       "80 columns: the user's line, shortened, its time kept: \(rows.filter { $0.contains("Gemma") }.prefix(2))")
            }
        }
        // Plain (NO_COLOR, TERM=dumb): nothing redrawn, so nothing repeats.
        for environment in [["NO_COLOR": "1"], ["TERM": "dumb"]] {
            let plain = TerminalRun(operations(Recorder(), resume: .init(role: .leader, peerName: "Apple M4 Max, 128 GB"), pairEvents: [],
                                               pairResult: .failed([]), readyReports: [usersLoadingReport], readyReportPause: 300_000),
                                    environment: environment, columns: 40)
            defer { plain.release() }
            expect(plain.waitFor(prompt(2)), "plain \(environment): the list"); plain.type("\r")
            expect(plain.finish(seconds: 20) == 0, "plain \(environment): served")
            expect(!plain.text.contains("\u{1B}") && !plain.text.contains("on both Macs (starting"),
                   "plain \(environment): no live line at all: \(plain.text)")
        }
    }
}
