import Foundation
import Darwin

/// The desktop app's console (`darkbloom cluster --app-console`): the same flows with the scripted operations, driven
/// over pipes as the desktop API drives them: one JSON event per line out, one JSON answer per line in.
extension OnboardingChecks {
    static func appConsoleChecks() {
        appConsoleEventsAreOneJSONLineEach()
        appLeaderFromScratch()
        appMemberFromScratch()
        appCancelWhileWaiting()
        appQLeavesTheWait()
        appCancelAtTheList()
        appStaleAndInvalidAnswersAreDropped()
        appInputEndIsACancel()
        appCopyOffersNoKey()
        appSudoNeedsTheTerminal()
        appLocalNetworkWaitOffersCancel()
        appLocalNamesTheModel()
    }

    static let appNeedsTerminal = "Run `darkbloom cluster` in a Terminal window on this Mac."

    /// One flow on the app's console over two pipes.
    final class AppRun: @unchecked Sendable {
        private let lock = NSLock()
        private var lines = [String]()
        private var exitCode: Int32?
        private let answers: Int32
        private var answersOpen = true
        let done = DispatchSemaphore(value: 0)
        let drained = DispatchSemaphore(value: 0)

        init(_ operations: ClusterOnboardingOperations, request: ClusterOnboardingRequest = .init()) {
            var input: [Int32] = [-1, -1], output: [Int32] = [-1, -1]
            precondition(pipe(&input) == 0 && pipe(&output) == 0)
            answers = input[1]
            let reader = output[0], writer = output[1], source = input[0]
            Thread.detachNewThread { [self] in
                var pending = [UInt8](), buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = Darwin.read(reader, &buffer, buffer.count)
                    guard count > 0 else { break }
                    pending.append(contentsOf: buffer[0..<count])
                    while let newline = pending.firstIndex(of: 0x0A) {
                        let line = String(decoding: pending[..<newline], as: UTF8.self)
                        pending.removeSubrange(...newline)
                        lock.withLock { lines.append(line) }
                    }
                }
                Darwin.close(reader)
                drained.signal()
            }
            Thread.detachNewThread { [self] in
                let console = ClusterOnboardingAppConsole(input: source, output: writer, needsTerminal: OnboardingChecks.appNeedsTerminal)
                let code = ClusterOnboardingDriver.run(operations, console: console, request: request)
                console.finish(code)
                Darwin.close(writer)
                lock.withLock { exitCode = code }
                done.signal()
            }
        }

        deinit { closeAnswers() }

        /// Every line written, as written.
        var raw: [String] { lock.withLock { lines } }
        /// Every line as a JSON object (an empty one for a line that isn't).
        var events: [[String: Any]] {
            raw.map { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] ?? [:] }
        }
        var said: [String] { events.filter { $0["event"] as? String == "say" }.compactMap { $0["text"] as? String } }
        func of(_ kind: String) -> [[String: Any]] { events.filter { $0["event"] as? String == kind } }
        /// The questions asked, in order (nulls left out).
        var questions: [[String: Any]] { of("question").compactMap { $0["question"] as? [String: Any] } }

        /// The `count`-th question of `type`, once asked.
        func question(_ type: String, count: Int = 1, seconds: Double = 10) -> [String: Any]? {
            let deadline = Date().addingTimeInterval(seconds)
            while true {
                let asked = questions.filter { $0["type"] as? String == type }
                if asked.count >= count { return asked[count - 1] }
                guard Date() < deadline else { return nil }
                usleep(10_000)
            }
        }

        func waitForSaid(_ text: String, seconds: Double = 10) -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline { if said.contains(text) { return true }; usleep(10_000) }
            return said.contains(text)
        }

        func send(_ line: String) {
            let bytes = Array((line + "\n").utf8)
            lock.withLock { guard answersOpen else { return }; _ = bytes.withUnsafeBytes { Darwin.write(answers, $0.baseAddress, $0.count) } }
        }

        func choose(_ question: [String: Any]?, _ choice: Int) {
            send("{\"question\":\"\(question?["id"] as? String ?? "")\",\"choice\":\(choice)}")
        }

        func key(_ question: [String: Any]?, _ key: String) {
            send("{\"question\":\"\(question?["id"] as? String ?? "")\",\"key\":\"\(key)\"}")
        }

        func cancel() { send("{\"cancel\":true}") }

        /// Ends the answers: the console reads the end of its input.
        func closeAnswers() {
            lock.withLock {
                guard answersOpen else { return }
                answersOpen = false
                Darwin.close(answers)
            }
        }

        /// The exit status once the run ended and every line it wrote was read (nil while it still runs).
        func finish(seconds: Double = 10) -> Int32? {
            guard done.wait(timeout: .now() + seconds) == .success else { return nil }
            _ = drained.wait(timeout: .now() + seconds)
            closeAnswers()
            return lock.withLock { exitCode }
        }
    }

    /// Each event's exact line, called one by one on a console: live work only when it changes, a settle only after it,
    /// a stressed line's parts, the whole progress line, and the exit last with nothing after it.
    static func appConsoleEventsAreOneJSONLineEach() {
        var input: [Int32] = [-1, -1], output: [Int32] = [-1, -1]
        precondition(pipe(&input) == 0 && pipe(&output) == 0)
        let console = ClusterOnboardingAppConsole(input: input[0], output: output[1], needsTerminal: appNeedsTerminal)
        console.banner("Darkbloom cluster", "This Mac leads")
        console.heading("1/4 Connect")
        console.say("")
        console.say("  Allow macOS permissions.")
        console.settle()
        console.working("Checking the cable")
        console.working("Checking the cable")
        console.workingRows(["Loading Qwen on both Macs \u{00B7} 3 s", "This Mac: loading its share"])
        console.settle()
        console.settle()
        console.sayStressed("  Recommended for these Macs: ", "tensor parallel", ".")
        console.progress({ width in width == nil ? "Copying: 8.2 of 16.3 GB" : "cut" }, logged: true)
        console.progress({ _ in "Copying: 8.2 of 16.3 GB" }, logged: false)
        console.result(true, "Serving Qwen", ["Test response in 0.61 s"])
        let ran = console.suspended { 7 }
        console.finish(0)
        console.say("after the end")
        Darwin.close(output[1])
        var text = [UInt8](), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(output[0], &buffer, buffer.count)
            guard count > 0 else { break }
            text.append(contentsOf: buffer[0..<count])
        }
        Darwin.close(output[0])
        Darwin.close(input[1])
        let lines = String(decoding: text, as: UTF8.self).components(separatedBy: "\n").dropLast()
        let expected = [
            #"{"event":"banner","subtitle":"This Mac leads","title":"Darkbloom cluster"}"#,
            #"{"event":"heading","text":"1/4 Connect"}"#,
            #"{"event":"say","text":"  Allow macOS permissions."}"#,
            #"{"event":"working","rows":["Checking the cable"]}"#,
            #"{"event":"working","rows":["Loading Qwen on both Macs · 3 s","This Mac: loading its share"]}"#,
            #"{"event":"settle"}"#,
            #"{"event":"say","stressed":{"lead":"  Recommended for these Macs: ","stressed":"tensor parallel","tail":"."},"text":"  Recommended for these Macs: tensor parallel."}"#,
            #"{"event":"progress","text":"Copying: 8.2 of 16.3 GB"}"#,
            #"{"event":"result","lines":["Test response in 0.61 s"],"ok":true,"title":"Serving Qwen"}"#,
            #"{"event":"needs_terminal","text":"Run `darkbloom cluster` in a Terminal window on this Mac."}"#,
            #"{"code":0,"event":"exit"}"#,
        ]
        expect(Array(lines) == expected, "app console: one exact JSON line per event: \(Array(lines))")
        expect(ran == 7, "app console: the suspended step still runs")
    }

    /// Every line is a JSON object with an `event`, no terminal code anywhere, and `exit` last with the run's status.
    static func appLinesAreEvents(_ run: AppRun, _ label: String, code: Int32) {
        let raw = run.raw
        expect(!raw.isEmpty && run.events.allSatisfy { $0["event"] is String }, "\(label): every line is an event: \(raw)")
        expect(!raw.contains { $0.contains("\u{1B}") || $0.contains("\\u001b") }, "\(label): no terminal codes")
        expect(run.events.last?["event"] as? String == "exit" && run.events.last?["code"] as? Int == Int(code),
               "\(label): exit \(code) last: \(raw.last ?? "")")
    }

    static func appLeaderFromScratch() {
        let recorder = Recorder()
        let run = AppRun(operations(recorder, pairEvents: leaderEvents, pairResult: .paired(role: .leader, peerName: "Apple M3 Ultra, 256 GB")))
        let code = run.question("choose")
        expect(code?["options"] as? [[String]] == [["Yes"], ["No"]] && code?["selected"] as? Int == 0, "app leader: the code's answers: \(String(describing: code))")
        expect(run.said.contains("  Code 123 456. " + codeQuestion), "app leader: the code and its question, said first")
        run.choose(code, 0)
        let models = run.question("choose", count: 2)
        expect(models?["options"] as? [[String]] == [["Qwen3.8-27B-4bit-mtp \u{00B7} 16.3 GB \u{00B7} pipeline"],
                                                    ["Z.ai: GLM-5.3-Flash \u{00B7} 181.8 GB \u{00B7} tensor parallel"]],
               "app leader: one row per model: \(String(describing: models?["options"]))")
        run.choose(models, 0)
        let exit = run.finish()
        expect(exit == 0, "app leader: exit 0, got \(String(describing: exit))")
        appLinesAreEvents(run, "app leader", code: 0)
        let banner = run.events.first
        expect(banner?["event"] as? String == "banner" && banner?["title"] as? String == "Darkbloom cluster" && banner?["subtitle"] as? String == "",
               "app leader: the banner first: \(String(describing: banner))")
        expect(run.of("heading").compactMap { $0["text"] as? String } == stages, "app leader: the four steps in order")
        let keys = run.questions.filter { $0["type"] as? String == "key" }.compactMap { $0["keys"] as? [[String: String]] }
        expect(keys.first == [["key": "q", "label": "Cancel"]], "app leader: q cancels the pairing's wait: \(keys)")
        expect(keys.contains([["key": "q", "label": "Leave"]]), "app leader: q leaves the start's wait: \(keys)")
        expect(run.said.contains("  \u{25B8} Yes") && run.said.contains("  \u{25B8} Qwen3.8-27B-4bit-mtp \u{00B7} 16.3 GB \u{00B7} pipeline"),
               "app leader: each answer said as the list folds to it")
        expect(run.said.contains("  \u{2713} Paired. This Mac leads."), "app leader: paired")
        let result = run.of("result").last
        expect(result?["ok"] as? Bool == true && result?["title"] as? String == "Serving Qwen3.8-27B-4bit-mtp through Darkbloom on both Macs (pipeline)",
               "app leader: the outcome block: \(String(describing: result))")
        expect(!run.of("working").isEmpty, "app leader: live work is sent")
        expect(recorder.all == ["checkLink", "pair", "answer y", "ensureService", "reachMembers", "planModels", "recheckFit 0", "adopt 0", "serve",
            "waitReady", "testRequest", "register", "waitReady", "pairServing"], "app leader: the terminal's operations, in order: \(recorder.all)")
    }

    static func appMemberFromScratch() {
        let recorder = Recorder()
        let run = AppRun(operations(recorder, pairEvents: memberEvents, pairResult: .paired(role: .member, peerName: "Apple M5 Ultra, 256 GB")))
        run.choose(run.question("choose"), 0)
        let exit = run.finish()
        expect(exit == 0, "app member: exit 0, got \(String(describing: exit))")
        appLinesAreEvents(run, "app member", code: 0)
        expect(run.said.contains("  \u{2713} Paired. The other Mac leads."), "app member: who leads")
        expect(run.said.contains("  " + ClusterOnboardingDriver.waitingForStartLine("Apple M5 Ultra, 256 GB")), "app member: follows the start")
        expect(run.of("result").last?["ok"] as? Bool == true, "app member: the outcome block")
        expect(run.said.last == ClusterOnboardingDriver.closeWindowLine, "app member: whether the window may close, last: \(run.said.suffix(3))")
        expect(run.questions.filter { $0["type"] as? String == "choose" }.count == 1, "app member: one question, the code")
        expect(Array(recorder.all.prefix(4)) == ["checkLink", "pair", "answer y", "ensureService"], "app member: operations \(recorder.all)")
    }

    static let waitingPairEvents: [ClusterOnboardingPairEvent] = [.searching, .waitingAsLeader, .note("still waiting"), .note("still waiting")]
        + Array(repeating: .note(""), count: 400)

    /// The app's Cancel in the pairing's wait answers as q: nothing paired, the same status.
    static func appCancelWhileWaiting() {
        let run = AppRun(operations(Recorder(), pairEvents: waitingPairEvents, pairResult: .failed(["expired"])))
        expect(run.question("key") != nil, "app cancel: the wait offers its key")
        run.cancel()
        expect(run.finish() == 130, "app cancel: as q, 130")
        expect(run.said.contains("Cancelled: nothing paired."), "app cancel: nothing paired, said")
        appLinesAreEvents(run, "app cancel", code: 130)
    }

    static func appQLeavesTheWait() {
        let run = AppRun(operations(Recorder(), pairEvents: waitingPairEvents, pairResult: .failed(["expired"])))
        let wait = run.question("key")
        expect(wait?["keys"] as? [[String: String]] == [["key": "q", "label": "Cancel"]], "app q: the key and the screen's word")
        run.key(wait, "q")
        expect(run.finish() == 130, "app q: 130")
        expect(run.said.contains("Cancelled: nothing paired."), "app q: nothing paired, said")
    }

    /// A cancel at a list answers it as q: nothing changed, and the run ends.
    static func appCancelAtTheList() {
        let recorder = Recorder()
        let run = AppRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [], pairResult: .failed([])))
        expect(run.question("choose") != nil, "app list cancel: the model list")
        run.cancel()
        expect(run.finish() == 0, "app list cancel: exit 0")
        expect(run.said.last == "Nothing changed.", "app list cancel: nothing changed: \(run.said.suffix(2))")
        expect(!recorder.all.contains("adopt 0") && !recorder.all.contains("serve"), "app list cancel: nothing started")
        expect(run.of("question").last?["question"] is NSNull, "app list cancel: nothing left asked")
    }

    /// Lines that are not JSON, name another question, or answer outside the question are dropped; the question stays.
    static func appStaleAndInvalidAnswersAreDropped() {
        let recorder = Recorder()
        let run = AppRun(operations(recorder, pairEvents: memberEvents, pairResult: .paired(role: .member, peerName: "Apple M5 Ultra, 256 GB")))
        let code = run.question("choose")
        let id = code?["id"] as? String ?? ""
        run.send("not json")
        run.send(#"{"question":"q999","choice":0}"#)
        run.send("{\"question\":\"\(id)\",\"choice\":2}")
        run.send("{\"question\":\"\(id)\",\"key\":\"q\"}")
        run.send("{\"question\":\"\(id)\",\"choice\":true}")
        usleep(300_000)
        expect(!recorder.all.contains("answer y") && !recorder.all.contains("answer n"), "app answers: none of those answered: \(recorder.all)")
        expect(run.of("question").last?["question"] is [String: Any], "app answers: the code is still asked")
        run.choose(code, 0)
        expect(run.finish() == 0, "app answers: the right one goes on")
        expect(recorder.all.contains("answer y"), "app answers: yes")
    }

    /// The input's end is the app's cancel: the code question ends, and the pairing says the input closed.
    static func appInputEndIsACancel() {
        let recorder = Recorder()
        let run = AppRun(operations(recorder, pairEvents: memberEvents, pairResult: .paired(role: .member, peerName: "Apple M5 Ultra, 256 GB")))
        expect(run.question("choose") != nil, "app input end: the code")
        run.closeAnswers()
        expect(run.finish() == 1, "app input end: exit 1")
        expect(run.said.contains("Input closed: nothing paired."), "app input end: said")
        expect(!recorder.all.contains("ensureService"), "app input end: nothing started")
    }

    /// q does nothing in a copy, so the app is offered no key there; the copy's report is live progress.
    static func appCopyOffersNoKey() {
        let recorder = Recorder()
        let run = AppRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [], pairResult: .failed([]),
            choices: copyChoices, provisionReportPause: 300_000))
        run.choose(run.question("choose"), 0)
        let copy = run.question("choose", count: 2)
        expect(copy?["options"] as? [[String]] == [["Copy to the other Mac"], ["Download"], ["Cancel"]], "app copy: the list: \(String(describing: copy))")
        run.choose(copy, 0)
        expect(run.finish() == 0, "app copy: served")
        let events = run.events
        let copied = events.firstIndex { $0["text"] as? String == "  \u{2713} Copied to the other Mac (16.3 GB, 6.9 s)" } ?? 0
        let answered = events.lastIndex { $0["text"] as? String == "  \u{25B8} Copy to the other Mac" } ?? events.count
        let between = events[min(answered, copied)..<copied]
        expect(copied > answered && !between.contains { ($0["question"] as? [String: Any])?["type"] as? String == "key" },
               "app copy: no key offered while it copies")
        expect(between.contains { $0["event"] as? String == "progress"
            && $0["text"] as? String == "Copying to the other Mac: 8.2 of 16.3 GB, 2.40 GB/s, about 1 s left" }, "app copy: the report, live")
    }

    /// sudo where macOS shows no prompt: the app says where to run it, and the step still runs (with nothing to read).
    static func appSudoNeedsTheTerminal() {
        let recorder = Recorder()
        let run = AppRun(operations(recorder, pairEvents: [], pairResult: .failed([]),
            linkScript: "~/.darkbloom/cluster-device/link-fix.sh", sudoSucceeds: false))
        expect(run.finish() == 1, "app sudo: stops")
        let events = run.events
        let typed = events.firstIndex { $0["text"] as? String == "  Type this Mac's password to set up the cable port." }
        let needs = events.firstIndex { $0["event"] as? String == "needs_terminal" }
        expect(typed != nil && needs != nil && typed! < needs! && events[needs!]["text"] as? String == appNeedsTerminal,
               "app sudo: what the step needs, then where to run it: \(run.raw)")
        expect(recorder.all.contains("runAsAdministrator"), "app sudo: the step ran")
        expect(run.said.last == "Cable port not set up. Run `darkbloom cluster` again.", "app sudo: the flow's last line")
    }

    /// The wait for Allow takes q as "Cancel", as its line says.
    static func appLocalNetworkWaitOffersCancel() {
        let recorder = Recorder()
        let run = AppRun(operations(recorder, pairEvents: [], pairResult: .failed([]), localNetwork: { _ in .blocked }))
        let wait = run.question("key")
        expect(wait?["keys"] as? [[String: String]] == [["key": "q", "label": "Cancel"]], "app allow: q cancels: \(String(describing: wait))")
        run.key(wait, "q")
        expect(run.finish() == 1, "app allow: stops")
        expect(run.said.last?.hasPrefix("Local Network is off for Terminal.") == true, "app allow: where to turn it on: \(run.said.suffix(2))")
    }

    /// `darkbloom cluster local --app-console <model>` on the leading Mac: no list, the model served locally, the outcome.
    static func appLocalNamesTheModel() {
        let recorder = Recorder()
        var request = localRequest
        request.model = "qwen3.8-27b-4bit-MTP"
        let run = AppRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M5 Ultra, 256 GB", serving: true, modelName: "Qwen3.8-27B-4bit-mtp"),
            pairEvents: [], pairResult: .failed([]), readyResult: .success(localReady)), request: request)
        expect(run.finish() == 0, "app local: exit 0")
        appLinesAreEvents(run, "app local", code: 0)
        expect(run.questions.allSatisfy { $0["type"] as? String == "key" }, "app local: no list asked: \(run.questions)")
        expect(run.of("result").last?["ok"] as? Bool == true, "app local: the outcome block")
        expect(recorder.all == ["ensureService", "reachMembers", "planModels", "recheckFit 0", "adopt 0", "setScope local 0.0.0.0", "serve", "waitReady", "testRequest"],
               "app local: the terminal's operations: \(recorder.all)")
    }
}
