import Foundation
import Darwin

/// The owner, 2026-11-05: "Is there any way to also capture all of the flow in one space, instead of the next line keeps
/// dragging down …". In a colour window, a step that finished folds to one line ("✓ 2/4 Pair (1 min 12 s)") once the next
/// step begins, keeping the pairing code, the questions and their answers and any ✗; the last step and the outcome stay
/// whole. A step taller than the window never folds (scrolled-off rows can't be redrawn). Plain output is unchanged. The
/// whole flow goes, line by line, to a log file whose path the end says ("Full log: …"), and a ✗ block too.
extension OnboardingChecks {
    static func stepFoldChecks() {
        theLeadingMacsFinishedStepsFold()
        theJoiningMacsFinishedStepsFold()
        aStepTallerThanTheWindowNeverFolds()
        plainOutputIsUnchangedAndWritesNoLog()
        aCrossSaysWhereTheFullLogIs()
    }

    /// The window's rows after `raw`, as a terminal of `columns` shows them: CR, LF, the cursor up (ESC [ n A), erase to
    /// the end (ESC [ J, ESC [ K), line wrap on or off (ESC [ ? 7 h/l); colours and the cursor's own codes ignored.
    static func screen(_ raw: String, columns: Int) -> [String] {
        var lines: [[Character]] = [[]]
        var row = 0, column = 0, wraps = true
        var characters = Array(raw)
        var index = 0
        func ensure() { while lines.count <= row { lines.append([]) } }
        while index < characters.count {
            let character = characters[index]
            index += 1
            switch character {
            case "\u{1B}":
                guard index < characters.count, characters[index] == "[" else { continue }
                index += 1
                var parameters = ""
                while index < characters.count, !(characters[index].isLetter) { parameters.append(characters[index]); index += 1 }
                guard index < characters.count else { break }
                let command = characters[index]
                index += 1
                switch command {
                case "A": row = max(0, row - (Int(parameters) ?? 1))
                case "J":
                    ensure()
                    lines[row] = Array(lines[row].prefix(column))
                    lines.removeSubrange((row + 1)...)
                case "K": ensure(); lines[row] = Array(lines[row].prefix(column))
                case "h" where parameters == "?7": wraps = true
                case "l" where parameters == "?7": wraps = false
                default: break
                }
            case "\r": column = 0
            case "\n", "\r\n": row += 1; column = 0; ensure()
            default:
                if column >= columns {
                    guard wraps else { continue }
                    row += 1; column = 0
                }
                ensure()
                while lines[row].count < column { lines[row].append(" ") }
                if column < lines[row].count { lines[row][column] = character } else { lines[row].append(character) }
                column += 1
            }
        }
        characters = []
        return lines.map { String($0) }
    }

    static func foldLog(_ name: String) -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("onboarding-fold-\(getpid())")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(name + ".log")
        try? FileManager.default.removeItem(at: file)
        return file
    }

    static let foldedStep = #"^\u{2713} \d/4 [A-Za-z]+ \((\d+ s|\d+ min \d+ s)\)$"#

    static func theLeadingMacsFinishedStepsFold() {
        for columns in [80, 40] as [UInt16] {
            let log = foldLog("leading-\(columns)")
            let run = TerminalRun(operations(Recorder(), pairEvents: leaderEvents, pairResult: .paired(role: .leader, peerName: "Apple M5 Max, 128 GB")),
                                  environment: colourTerminal, columns: columns, logFile: log)
            defer { run.release() }
            expect(run.waitFor(codeQuestion), "fold, leading \(columns): the code"); run.type("y")
            expect(run.waitFor(arrowHint, count: 2), "fold, leading \(columns): the model list"); run.type("\r")
            expect(run.finish(seconds: 20) == 0, "fold, leading \(columns): served")
            let shown = screen(run.text, columns: Int(columns)).map { $0.trimmingCharacters(in: .whitespaces) }
            let folded = shown.filter { $0.range(of: foldedStep, options: .regularExpression) != nil }
            expect(folded.map { String($0.prefix(12)) } == ["\u{2713} 1/4 Connec", "\u{2713} 2/4 Pair (", "\u{2713} 3/4 Model ("].map { String($0.prefix(12)) },
                   "fold, leading \(columns): each finished step is one line: \(folded) in \(shown)")
            expect(!shown.contains { $0.contains("Cable ready") }, "fold, leading \(columns): a finished step's lines are folded: \(shown)")
            expect(shown.contains { $0.contains(ClusterOnboardingPairing.codeQuestion.prefix(4)) || $0.contains("Same on the other Mac?") },
                   "fold, leading \(columns): the pairing code stays: \(shown)")
            expect(shown.contains { $0.hasPrefix("\u{25B8} Yes") } && shown.contains { $0.hasPrefix("\u{25B8} Qwen3.8-27B-4bit-mtp") },
                   "fold, leading \(columns): the answers stay: \(shown)")
            expect(shown.contains { $0.contains("4/4 Start") } && shown.contains { $0.hasPrefix("\u{2713} Serving Qwen3.8-27B-4bit-mtp") },
                   "fold, leading \(columns): the last step and the outcome stay whole")
            expect(visible(run.text).last { !$0.isEmpty } == "Full log: " + log.path, "fold, leading \(columns): the log's path at the end: \(shown.suffix(3))")
            let written = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            expect(written.contains("Cable ready") && written.contains("2/4 Pair") && written.contains("Serving Qwen3.8-27B-4bit-mtp")
                   && !written.contains("\u{1B}"), "fold, leading \(columns): the log keeps every line, plain: \(written)")
            expect(run.text.components(separatedBy: "Full log: ").count == 2, "fold, leading \(columns): said once")
            transcript("fold-leading-\(columns)-columns", shown.joined(separator: "\n"), keys: run.keys)
        }
        // A resize mid-flow: the fold counts the rows the window shows now.
        let log = foldLog("leading-resized")
        let run = TerminalRun(operations(Recorder(), pairEvents: leaderEvents, pairResult: .paired(role: .leader, peerName: "Apple M5 Max, 128 GB")),
                              environment: colourTerminal, columns: 100, logFile: log)
        defer { run.release() }
        expect(run.waitFor(codeQuestion), "fold, resized: the code")
        var window = winsize(ws_row: 50, ws_col: 60, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(run.master, TIOCSWINSZ, &window)
        run.type("y")
        expect(run.waitFor(arrowHint, count: 2), "fold, resized: the model list"); run.type("\r")
        expect(run.finish(seconds: 20) == 0, "fold, resized: served")
        let shown = screen(run.text, columns: 60).map { $0.trimmingCharacters(in: .whitespaces) }
        expect(shown.filter { $0.range(of: foldedStep, options: .regularExpression) != nil }.count == 3
               && !shown.contains { $0.contains("Cable ready") }, "fold, resized: each step once, nothing left behind: \(shown)")
    }

    static func theJoiningMacsFinishedStepsFold() {
        let log = foldLog("joining")
        let served = "Serving Qwen 3.8 27B through Darkbloom on both Macs (pipeline)."
        let run = TerminalRun(operations(Recorder(), pairEvents: memberEvents, pairResult: .paired(role: .member, peerName: leaderName),
                                         statusSequence: [["Stopped."], ["Starting Qwen 3.8 27B."], [served]]),
                              environment: colourTerminal, columns: 80, logFile: log)
        defer { run.release() }
        expect(run.waitFor(codeQuestion), "fold, joining: the code"); run.type("y")
        expect(run.finish(seconds: 20) == 0, "fold, joining: served")
        let shown = screen(run.text, columns: 80).map { $0.trimmingCharacters(in: .whitespaces) }
        expect(shown.contains { $0.range(of: #"^\u{2713} 1/4 Connect \("#, options: .regularExpression) != nil }
               && !shown.contains { $0.contains("Cable ready") }, "fold, joining: Connect folded: \(shown)")
        expect(shown.contains { $0.contains("2/4 Pair") } && shown.contains { $0.contains("Paired. The other Mac leads.") }
               && shown.contains { $0.hasPrefix("\u{2713} Serving Qwen 3.8 27B") }, "fold, joining: its last step and the outcome stay: \(shown)")
        expect(visible(run.text).last { !$0.isEmpty } == "Full log: " + log.path, "fold, joining: the log's path at the end")
        transcript("fold-joining-80-columns", shown.joined(separator: "\n"), keys: run.keys)
    }

    static func aStepTallerThanTheWindowNeverFolds() {
        let log = foldLog("tall")
        let run = TerminalRun(operations(Recorder(), pairEvents: leaderEvents, pairResult: .paired(role: .leader, peerName: "Apple M5 Max, 128 GB")),
                              environment: colourTerminal, columns: 80, rows: 4, logFile: log)
        defer { run.release() }
        expect(run.waitFor(codeQuestion), "fold, tall: the code"); run.type("y")
        expect(run.waitFor(arrowHint, count: 2), "fold, tall: the model list"); run.type("\r")
        expect(run.finish(seconds: 20) == 0, "fold, tall: served")
        let shown = screen(run.text, columns: 80).map { $0.trimmingCharacters(in: .whitespaces) }
        // Connect and Pair are taller than 4 rows: kept whole. The model step (its heading and the answer) fits: folded.
        expect(shown.contains { $0.contains("Cable ready") } && shown.contains { $0.contains("1/4 Connect") }
               && !shown.contains { $0.hasPrefix("\u{2713} 1/4 Connect") || $0.hasPrefix("\u{2713} 2/4 Pair") },
               "fold, tall: a step taller than the window keeps its lines: \(shown)")
    }

    static func plainOutputIsUnchangedAndWritesNoLog() {
        let log = foldLog("plain")
        func run(_ logFile: URL?) -> String {
            let run = TerminalRun(operations(Recorder(), pairEvents: leaderEvents, pairResult: .paired(role: .leader, peerName: "Apple M5 Max, 128 GB")),
                                  logFile: logFile)
            defer { run.release() }
            _ = run.waitFor(codeQuestion); run.type("y")
            _ = run.waitFor(prompt(2), count: 2); run.type("\r")
            _ = run.finish(seconds: 20)
            return run.text
        }
        let with = run(log), without = run(nil)
        expect(with == without && !with.contains("Full log"), "fold, plain: the same transcript, no log line: \(with)")
        expect(!FileManager.default.fileExists(atPath: log.path), "fold, plain: no log file (the transcript is the whole flow)")
    }

    static func aCrossSaysWhereTheFullLogIs() {
        let log = foldLog("cross")
        let run = TerminalRun(followingTheUltra(Recorder(), status: [["Stopped."], ["Starting Qwen 3.8 27B."], appleWaitStatus], followSeconds: 1),
                              environment: colourTerminal, columns: 80, logFile: log)
        defer { run.release() }
        expect(run.waitFor(codeQuestion), "fold, ✗: the code"); run.type("y")
        expect(run.finish(seconds: 30) == 1, "fold, ✗: exit 1")
        let shown = visible(run.text).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let cross = shown.firstIndex(where: { $0.hasPrefix("\u{2717} Not serving") }) else {
            expect(false, "fold, ✗: the block: \(shown)"); return
        }
        let block = shown[cross...].prefix { !$0.hasPrefix(String(ClusterOnboardingDriver.resultRule.prefix(4))) }
        expect(block.contains("Full log: " + log.path), "fold, ✗: the block says where the full log is: \(Array(block))")
        expect(run.text.components(separatedBy: "Full log: ").count == 2, "fold, ✗: said once, in the block")
    }
}
