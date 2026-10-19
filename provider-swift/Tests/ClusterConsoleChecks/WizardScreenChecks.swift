import Foundation
import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
@testable import InstalledContract

extension ClusterConsoleCheck {
    /// Every state the screen is checked in: each step of each kind of Mac,
    /// with each thing that can be wrong, and the live and failed views.
    static func wizardStates() -> [(String, ClusterSetupState)] {
        typealias F = WizardFixtures
        let savedA = ClusterSetupSaved(state: .loaded, error: nil, setup: F.setup(leader: true))
        let savedB = ClusterSetupSaved(state: .loaded, error: nil, setup: F.setup(leader: false, digest: String(repeating: "b", count: 64)))
        var off = F.linkA; off.state = "rdmaDisabled"; off.port = nil
        var none = F.linkA; none.state = "noActivePort"; none.port = nil
        var bridged = F.linkA; bridged.state = "portBridgedWithoutAddress"; bridged.port?.verdict = "portBridgedWithoutAddress"
        bridged.port?.hasIPv4Address = false
        var noProfile = F.mac(F.profileA); noProfile.profile = nil; noProfile.profileError = "darkbloom-cluster-plan beside the worker: not installed"
        var lowDisk = F.mac(F.profileA, disk: 8 * F.gib)
        lowDisk.diskTotalBytes = 1_800 * F.gib
        let leaking = ClusterSetupMemoryGuard(decision: .refused, wiredBytes: 92 * F.gib, baselineBytes: Int(25.6 * Double(F.gib)),
            detail: "92 GiB of memory is wired on this Mac and no other Darkbloom process is running; restart this Mac.")
        var passed = F.confirmed()
        passed.add(.init(configurationSHA256: F.setup(leader: true).configurationSHA256, at: "2026-10-10T15:40:00Z", readySeconds: 11.2,
            firstTokenMilliseconds: 720, tokensPerSecond: 53.1))

        func make(_ snapshot: ClusterSetupSnapshot, step: ClusterSetupStep, _ change: (inout ClusterSetupState) -> Void = { _ in }) -> ClusterSetupState {
            var state = ClusterSetupState(size: .init(columns: 80, rows: 24))
            state.snapshot = snapshot
            state.step = step
            state.now = 5_000_000_000
            change(&state)
            return state
        }
        let reached = ClusterSetupState.Peer.reached(F.reportB(saved: savedB), seconds: 0.42, at: 1)
        var states: [(String, ClusterSetupState)] = [
            ("reading", ClusterSetupState(size: .init(columns: 80, rows: 24))),
            ("1 ready", make(F.snapshot(F.reportA()), step: .thisMac)),
            ("1 rdma off", make(F.snapshot(F.reportA(link: off)), step: .thisMac)),
            ("1 no plan tool", make(F.snapshot(F.reportA(mac: noProfile)), step: .thisMac)),
            ("1 low disk", make(F.snapshot(F.reportA(mac: lowDisk)), step: .thisMac)),
            ("1 left wired", make(F.snapshot(F.reportA(memoryGuard: leaking)), step: .thisMac)),
            ("2 ready not isolated", make(F.snapshot(F.reportA()), step: .cable)),
            ("2 blocked by sharing", make(F.snapshot(F.reportB(), pair: nil), step: .cable)),
            ("2 no cable", make(F.snapshot(F.reportA(link: none)), step: .cable)),
            ("2 no address", make(F.snapshot(F.reportA(link: bridged)), step: .cable)),
            ("2 preview", make(F.snapshot(F.reportA()), step: .cable) { $0.linkFix = .previewed(F.wizardPreview); $0.asking = .applyLinkFix }),
            ("2 applying", make(F.snapshot(F.reportA()), step: .cable) { $0.linkFix = .applying }),
            ("2 applied", make(F.snapshot(F.reportA()), step: .cable) { $0.linkFix = .applied(F.wizardApplied) }),
            ("3 no pair, follower code", make(F.snapshot(F.reportB(), pair: nil, record: .init()), step: .pair)),
            ("3 reaching", make(F.snapshot(F.reportA()), step: .pair) { $0.peer = .reaching(since: 1_000_000_000) }),
            ("3 reached", make(F.snapshot(F.reportA()), step: .pair) { $0.peer = reached }),
            ("3 failed", make(F.snapshot(F.reportA()), step: .pair) { $0.peer = .failed("the other Mac did not accept this Mac's key") }),
            ("3 confirmed", make(F.snapshot(F.reportA(), record: F.confirmed()), step: .pair) { $0.peer = reached }),
            ("3 asking", make(F.snapshot(F.reportA()), step: .pair) { $0.peer = reached; $0.asking = .confirmCode(code: "482913") }),
            ("4 planning", make(F.snapshot(F.reportA(), record: F.confirmed()), step: .model) { $0.peer = reached; $0.plans = .planning }),
            ("4 plans", make(F.snapshot(F.reportA(), record: F.confirmed()), step: .model) { $0.peer = reached; $0.plans = .ready(F.options) }),
            ("4 blocked model", make(F.snapshot(F.reportA(), record: F.confirmed()), step: .model) { $0.peer = reached; $0.plans = .ready(F.options); $0.selectedModel = F.models.count }),
            ("4 plan failed", make(F.snapshot(F.reportA(), record: F.confirmed()), step: .model) { $0.peer = reached; $0.plans = .failed("the other Mac's plan tool did not answer") }),
            ("4 inbox", make(F.snapshot(F.reportB(inbox: F.setup(leader: false, digest: String(repeating: "e", count: 64))), pair: F.inboxFollowerPair, record: F.confirmed()), step: .model)),
            ("4 waiting for peer", make(F.snapshot(F.reportA(saved: savedA), pair: F.savedLeaderPair, record: F.confirmed()), step: .model) { $0.peer = .reached(F.reportB(), seconds: 0.4, at: 1) }),
            ("4 saved", make(F.snapshot(F.reportA(saved: savedA), pair: F.savedLeaderPair, record: F.confirmed()), step: .model) { $0.peer = reached }),
            ("5 ready to check", make(F.snapshot(F.reportA(saved: savedA), pair: F.savedLeaderPair, record: F.confirmed()), step: .check) { $0.peer = reached }),
            ("5 ranks", make(F.snapshot(F.reportA(saved: savedA), pair: F.savedLeaderPair, record: F.confirmed()), step: .check) {
                $0.peer = reached; $0.check = .running(.ranks, since: 1_000_000_000); $0.checkReadyRanks = 1
                $0.session = .running(processIdentifier: 4242, since: 1_000_000_000) }),
            ("5 failed", make(F.snapshot(F.reportA(saved: savedA), pair: F.savedLeaderPair, record: F.confirmed()), step: .check) {
                $0.peer = reached; $0.check = .failed(.ranks, "Both ranks were not ready 240 s after the start (1 of 2 ranks ready).") }),
            ("5 passed", make(F.snapshot(F.reportA(saved: savedA), pair: F.savedLeaderPair, record: passed), step: .check) {
                $0.peer = reached; $0.check = .passed(passed.checks[0]); $0.cleanup = ["This Mac: device journal empty; wired memory 9.8 GiB (was 9.7 GiB before), under the 26 GiB idle baseline"] }),
            ("5 follower", make(F.snapshot(F.reportB(saved: savedB), pair: F.savedFollowerPair, record: F.confirmed()), step: .check)),
            ("6 not started", make(F.snapshot(F.reportA(saved: savedA), pair: F.savedLeaderPair, record: passed), step: .serve) { $0.peer = reached }),
            ("6 serving", make(F.snapshot(F.reportA(saved: savedA), pair: F.savedLeaderPair, record: passed), step: .serve) {
                $0.peer = reached; $0.session = .running(processIdentifier: 4242, since: 1_000_000_000); $0.live = F.scriptedLive }),
            ("6 prompt", make(F.snapshot(F.reportA(saved: savedA), pair: F.savedLeaderPair, record: passed), step: .serve) {
                $0.peer = reached; $0.session = .running(processIdentifier: 4242, since: 1_000_000_000); $0.live = F.scriptedLive
                $0.prompt = .editing("Why is the sky blue?") }),
            ("6 answered", make(F.snapshot(F.reportA(saved: savedA), pair: F.savedLeaderPair, record: passed), step: .serve) {
                $0.peer = reached; $0.session = .running(processIdentifier: 4242, since: 1_000_000_000); $0.live = F.scriptedLive
                $0.prompt = .answered("Why is the sky blue?", reply: "Because shorter wavelengths scatter more.", .init(completionTokens: 9, firstTokenMilliseconds: 610, tokensPerSecond: 52.4, finishReason: "stop")) }),
            ("6 stopped", make(F.snapshot(F.reportA(saved: savedA), pair: F.savedLeaderPair, record: passed), step: .serve) {
                $0.peer = reached; $0.session = .ended("exited with status 0", clean: true)
                $0.cleanup = ["This Mac: device journal empty; wired memory 9.9 GiB, under the 26 GiB idle baseline", "The other Mac: device journal empty; wired memory 5.0 GiB, under the 16 GiB idle baseline"] }),
            ("6 failed", make(F.snapshot(F.reportA(saved: savedA), pair: F.savedLeaderPair, record: passed), step: .serve) {
                $0.session = .ended("exited with status 1", clean: false); $0.sessionOutput = ["Error: the coordinator did not acknowledge"] }),
            ("6 follower", make(F.snapshot(F.reportB(saved: savedB), pair: F.savedFollowerPair, record: F.confirmed()), step: .serve)),
            ("help", make(F.snapshot(F.reportA()), step: .cable) { $0.showsHelp = true }),
        ]
        states.append(("notice", make(F.snapshot(F.reportA()), step: .thisMac) { $0.notice = "Cancelled. Nothing was changed." }))
        return states
    }

    static func wizardScreen() throws {
        let sizes: [(Int, Int)] = [(0, 0), (1, 1), (20, 5), (39, 11), (40, 12), (60, 16), (80, 24), (100, 30), (132, 43), (200, 60), (300, 100)]
        for (name, base) in wizardStates() {
            for (columns, rows) in sizes {
                var state = base
                state.size = .init(columns: columns, rows: rows)
                for glyphs in [ClusterSetupGlyphs.unicode, .ascii] {
                    let frame = ClusterSetupScreen.frame(state, glyphs: glyphs)
                    expect(frame.lines.count <= rows, "\(name) at \(columns)x\(rows): \(frame.lines.count) lines")
                    for line in frame.lines {
                        expect(line.text.count <= columns, "\(name) at \(columns)x\(rows): a line of \(line.text.count) columns: \(line.text)")
                        expect(line.text.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 }, "\(name): a control character")
                        if glyphs == .ascii {
                            expect(line.text.unicodeScalars.allSatisfy { $0.value < 127 }, "\(name) in ASCII: \(line.text)")
                        }
                    }
                    // Exactly the bytes of one frame, with and without colour.
                    let plain = String(decoding: frame.terminalBytes(color: false, rows: rows), as: UTF8.self)
                    expect(!plain.contains("\u{1B}[3") && !plain.contains("\u{1B}[1m"), "\(name): no colour without colour")
                    let colored = String(decoding: frame.terminalBytes(color: true, rows: rows), as: UTF8.self)
                    expectEqual(PseudoTerminal.strippingSequences(colored), PseudoTerminal.strippingSequences(plain),
                        "\(name) at \(columns)x\(rows): colour changes only colour")
                }
            }
            // At 80x24 each screen shows its whole heading, the rail and the key line.
            var standard = base
            standard.size = .init(columns: 80, rows: 24)
            let frame = ClusterSetupScreen.frame(standard)
            expectEqual(frame.lines.count, 24, "\(name): fills 80x24")
            if standard.snapshot != nil {
                expect(frame.lines[1].text.contains("Model"), "\(name): the rail names the steps at 80 columns: \(frame.lines[1].text)")
                expect(frame.lines[23].text.contains("q quit") || standard.asking != nil || standard.prompt != .closed,
                    "\(name): the key line shows quit: \(frame.lines[23].text)")
                expect(frame.lines[23].text.contains("help") || standard.asking != nil || standard.prompt != .closed || standard.showsHelp,
                    "\(name): help is on every screen")
            }
        }
        // Every question fits one 80-column row.
        for question in [ClusterSetupState.Question.applyLinkFix, .confirmCode(code: "482913"), .adoptPlan(folder: "x", planKey: "y"),
                         .approveInbox(expectedSHA256: String(repeating: "a", count: 64)), .runCheck, .startSession] {
            expect(ClusterSetupScreen.text(of: question, dryRun: false).count < 80, "question too long: \(question)")
            expect(ClusterSetupScreen.canShow(question, at: .init(columns: 80, rows: 24)), "question not shown at 80x24: \(question)")
        }
        // The glyphs follow the locale; a terminal that is not UTF-8 gets ASCII.
        expect(ClusterSetupGlyphs.forEnvironment(["LANG": "en_US.UTF-8"]) == .unicode, "UTF-8 locale draws Unicode")
        expect(ClusterSetupGlyphs.forEnvironment(["LC_ALL": "C", "LANG": "en_US.UTF-8"]) == .ascii, "LC_ALL wins")
        expect(ClusterSetupGlyphs.forEnvironment([:]) == .ascii, "no locale draws ASCII")
        expect(ClusterSetupGlyphs.forEnvironment(["LC_CTYPE": "UTF-8"]) == .unicode, "LC_CTYPE alone")
        // Text from the other Mac cannot draw: escapes and wide characters become question marks.
        let hostile = ClusterSetupScreen.sanitized("ok\u{1B}[2J\u{7}\u{4E2D}\u{2713}", glyphs: .ascii)
        expectEqual(hostile, "ok?[2J???", "untrusted text is made printable")
        expectEqual(ClusterSetupScreen.sanitized("\u{2713}", glyphs: .unicode), "\u{2713}", "the screen's own marks pass")
        // Wrapping: no row wider than asked, every word kept.
        let words = "The cable works, so setup can go on. Recommended: give the port to the cluster alone."
        for width in [1, 5, 10, 33, 80] {
            let rows = ClusterSetupScreen.wrap(words, width: width, hanging: 2)
            expect(rows.allSatisfy { $0.count <= max(width, 1) }, "wrap at \(width): \(rows)")
            expectEqual(rows.joined(separator: " ").split(separator: " ").joined(), words.split(separator: " ").joined(), "wrap keeps every word at \(width)")
        }
        // Bars: never wider than asked, more than full is full.
        for (used, total) in [(0, 10), (5, 10), (10, 10), (30, 10), (1, 0)] {
            let bar = ClusterSetupScreen.bar(used, of: total, width: 12, glyphs: .ascii)
            expectEqual(bar.count, 14, "bar width for \(used)/\(total)")
        }
        expectEqual(ClusterSetupScreen.gib(9 * 1_073_741_824 + 858_993_459), "9.8 GiB", "GiB rounding")
        expectEqual(ClusterSetupScreen.gib(256 * 1_073_741_824), "256 GiB", "large GiB")
        // The spinner turns with the clock.
        var spinning = ClusterSetupState(size: .init(columns: 80, rows: 24))
        spinning.refreshing = true
        spinning.now = 0
        let first = ClusterSetupScreen.frame(spinning).lines[22].text
        spinning.now = 100_000_000
        expect(ClusterSetupScreen.frame(spinning).lines[22].text != first, "the spinner advances every tenth of a second")
        // The plain output: the six steps, no keys.
        let plain = WizardFixtures.snapshot(WizardFixtures.reportA()).plainLines()
        for step in ClusterSetupStep.allCases { expect(plain.contains { $0.hasPrefix("Step \(step.number): \(step.title)") }, "plain output names step \(step.number)") }
        expect(!plain.contains { $0.contains("enter ") && $0.contains(" quit") }, "the plain output has no key line")
        expect(plain.joined(separator: "\n").contains("Apple M3 Ultra"), "the plain output says what was detected")
    }

    static func wizardContent() throws {
        typealias F = WizardFixtures
        func text(_ name: String) -> String {
            guard var state = wizardStates().first(where: { $0.0 == name })?.1 else { return "" }
            state.size = .init(columns: 100, rows: 200)
            return ClusterSetupContent.body(state, width: 100, glyphs: .unicode, interactive: true).map(\.text).joined(separator: "\n")
        }
        let ready = text("1 ready")
        for word in ["Apple M3 Ultra", "60 GPU cores", "256 GiB", "resident", "on the models volume", "enabled", "Darkbloom", "idle baseline"] {
            expect(ready.contains(word), "step 1 shows \(word): \(ready)")
        }
        expect(text("1 rdma off").contains("rdma_ctl enable"), "RDMA off gives the Recovery command")
        expect(text("1 no plan tool").contains("plan tool beside the worker did not answer"), "a missing plan tool is said")
        expect(text("1 low disk").contains("Little disk space"), "low disk is said")
        expect(text("1 left wired").contains("restart"), "left-wired memory says restart")
        let cable = text("2 ready not isolated")
        expect(cable.contains("en7 (\u{201C}Thunderbolt 6\u{201D})"), "the cluster port names its hardware port: \(cable)")
        expect(cable.contains("Thunderbolt 5 at 80 Gb/s to MacBook Pro (Mac17,7)"), "the connection is Thunderbolt 5 to the other Mac: \(cable)")
        expect(cable.contains("Thunderbolt 4 or USB4 at 40 Gb/s to Mac mini"), "a 40 Gb/s connection is called what it is: \(cable)")
        expect(cable.contains("a default route leaves through en7"), "isolation findings show in words")
        expect(text("2 blocked by sharing").contains("Internet Sharing"), "Mac B's blocker shows")
        expect(text("2 no address").contains("Fix link"), "a port without an address is offered the fix")
        expect(text("2 preview").contains("networksetup -createnetworkservice"), "the preview lists the commands")
        expect(text("2 applied").contains("Fixed: the port belongs to the cluster"), "the result shows in plain words")
        let follower = text("3 no pair, follower code")
        expect(follower.contains("Pair over the link (no SSH)") && follower.contains("press l on each"), "a lone Mac pairs over the link")
        expect(!follower.contains("SSH host key") && !follower.contains("--pair <description>") && !follower.contains("482 913"),
               "and is offered no SSH host-key code or pair description (owner gate: no SSH in the user path)")
        expect(text("3 reached").contains("holds the host key the setup pins"), "the pinned connection's meaning is said")
        expect(text("3 failed").contains("did not accept this Mac's key"), "a failed reach says why")
        expect(text("3 confirmed").contains("both screens showed this code"), "a confirmation shows")
        let plans = text("4 plans")
        expect(plans.contains("Qwen3.5-9B") && plans.contains("fits now"), "the 9B fits now: \(plans)")
        expect(plans.contains("speed not measured") && plans.contains("the split follows memory"), "without measurements no time is shown: \(plans)")
        expect(plans.contains("mac-a (this Mac)") && plans.contains("layers 0-"), "which Mac holds which layers")
        expect(plans.contains("Each alone"), "each Mac alone shows")
        expect(plans.contains(ClusterSetupPlanning.notClusterModel), "blocked models say why, next to them: \(plans)")
        expect(text("4 blocked model").contains(ClusterSetupPlanning.notClusterModel), "a selected blocked model says why")
        expect(text("4 inbox").contains("Approve this setup"), "the inbox offers approval")
        expect(text("4 waiting for peer").contains("has not saved its setup yet"), "waiting for the other Mac says what to do there")
        expect(text("5 ranks").contains("1 of 2 ranks ready"), "the check counts ranks")
        expect(text("5 failed").contains("Run the check again"), "a failed check offers to run again")
        expect(text("5 passed").contains("Check passed"), "a pass shows")
        expect(text("5 follower").contains("leader runs the check"), "a follower is told who checks")
        let serving = text("6 serving")
        expect(serving.contains("Serving Qwen3.5-9B") && serving.contains("3 requests served"), "the live view: \(serving)")
        expect(text("6 answered").contains("52.4 tok/s"), "the prompt's speed")
        expect(text("6 stopped").contains("Clean up"), "the clean-up after a stop")
        expect(text("6 failed").contains("coordinator did not acknowledge"), "a failed start shows its output")
        expect(text("6 follower").contains("leader starts and stops serving"), "a follower is told who serves")

        // The planner's answers from the captured readings: honest, restricted to this Mac leading.
        let options = F.options
        expectEqual(options.count, F.models.count + 1, "one option per model folder, the constructed unread one last")
        let nine = options.first { $0.model.modelID == "Qwen3.5-9B" }
        expect(nine?.blocker == nil && nine?.plan?.leaderID == "mac-a", "the 9B is planned with this Mac leading: \(String(describing: nine))")
        expect(nine?.plan?.fitsNow == true, "the 9B fits now on the captured memory")
        expect([4, 8, 12, 16].contains(nine?.plan?.cut ?? -1), "the 9B's cut is one the runtime admits: \(nine?.plan?.cut ?? -1)")
        expect(nine?.plan?.absolute == false, "without measurements the figures are relative and say so")
        let big = options.first { $0.model.modelID == "EigenLabs/Qwen3.8-27B-4bit-mtp" }
        expect(big?.blocker == nil && big?.plan?.leaderID == "mac-a", "the 27B is planned with this Mac leading")
        // Every family the runtime serves is offered: each captured folder is planned with this Mac leading,
        // fits now on the captured memory, at a cut its own layout admits, in a mode its worker described.
        for reading in F.readings {
            let option = options.first { $0.model.folder == reading.model.folder }
            // Records never refuse the owner (2026-10-14 08:45): MiMo (whose records ran with the M5 Ultra leading and
            // the M3 Ultra decoding, while this pair is an M3 Ultra leading an M5 Max) and GPT-OSS (whose pipeline
            // checks diverged at cuts 4, 8 and 10 on the bench pair) are offered whenever the Macs can hold them, at a
            // shape that did not diverge, with one line on public traffic; only memory could still block them.
            if ["mimo-v2.6-flash-mopd", "gpt-oss-20b"].contains(reading.model.modelID) {
                let words = option?.blocker ?? ""
                expect(words != ClusterSetupPlanning.noStageAdapter && words != ClusterSetupPlanning.everyShapeDiverged
                        && !words.contains("qualif") && !words.contains("not served on this pair"),
                    "\(reading.model.modelID): no qualification blocker: \(words)")
                if reading.model.modelID == "gpt-oss-20b" {
                    expect(option?.plan != nil, "GPT-OSS (13 GB) is offered on this pair: \(words)")
                }
                if let plan = option?.plan {
                    expect(option?.blocker == nil && plan.publicTraffic != nil
                            && ClusterGenerationMode(rawValue: plan.mode)?.isSharded == true,
                        "\(reading.model.modelID) is offered sharded with its public-traffic line: \(plan.mode) \(plan.publicTraffic ?? "-")")
                }
                continue
            }
            // A model the pair may not serve with this build is not offered at all (checked below).
            if let described = try? reading.capability.get(),
               ClusterSetupPlanning.pairServingRefused(described.record, publicModelID: reading.model.modelID) { continue }
            let layout = try? reading.layout.get()
            let described = (try? reading.capability.get())?.record.supportedGenerationModes.map(\.rawValue) ?? []
            expect(option?.blocker == nil && option?.plan?.leaderID == "mac-a",
                "\(reading.model.modelID) is offered with this Mac leading: \(option?.blocker ?? "no plan")")
            expect(option?.plan?.fitsNow == true, "\(reading.model.modelID) fits now on the captured memory")
            expect(layout?.admittedCuts.contains(option?.plan?.cut ?? -1) == true,
                "\(reading.model.modelID)'s cut \(option?.plan?.cut ?? -1) is one its layout admits")
            expect(described.contains(option?.plan?.mode ?? "-"), "\(reading.model.modelID)'s mode is one its worker described")
            // Sharded deployments only (owner, 2026-10-13): the onboarding never offers a hand-off mode (phase split,
            // phase split + MTP, the hybrid), even for a family whose worker runs one; every member holds layers.
            let mode = (option?.plan?.mode).flatMap(ClusterGenerationMode.init(rawValue:))
            expect(mode?.isSharded == true && (option?.plan?.ranks.allSatisfy { $0.endLayer > $0.firstLayer } ?? false),
                "\(reading.model.modelID) is offered sharded with layers on both Macs, never a hand-off mode: \(option?.plan?.mode ?? "-")")
        }
        expect(options.last?.model.folder == F.unreadModel.folder && options.last?.blocker == ClusterSetupPlanning.notClusterModel,
            "a folder no family reads is blocked in plain words")
        // With the 9B's recorded solo runs on each Mac, its figures are measured and shown, as on the pair.
        let measurements = ["speed-qwen35-9b-mac-a.json", "speed-qwen35-9b-mac-b.json"].compactMap {
            try? JSONDecoder().decode(ClusterSpeedMeasurement.self, from: F.data($0))
        }
        expectEqual(measurements.count, 2, "both recorded measurements decode")
        let measured = ClusterSetupPlanning.decide(readings: F.readings, description: F.pairDescription, localMemberID: "mac-a",
            localProfile: F.profileA, peerProfile: F.profileB, peerModels: F.models, measurements: measurements)
        let measuredNine = measured.first { $0.option.model.modelID == "Qwen3.5-9B" }?.option.plan
        expect(measuredNine?.absolute == true && measuredNine?.measured == true, "the 9B's figures are measured: \(String(describing: measuredNine))")
        expect((measuredNine?.firstTokenSeconds ?? 0) > 0.5 && (measuredNine?.firstTokenSeconds ?? 99) < 30, "a first-token time in seconds")
        expect((measuredNine?.decodeTokensPerSecond ?? 0) > 20, "a decode rate in tokens per second")
        expect(measured.first { $0.option.model.modelID == "EigenLabs/Qwen3.8-27B-4bit-mtp" }?.option.plan?.absolute == false,
            "the 27B, with no measurement of its own, shows no time")
        var withSpeed = ClusterSetupState(size: .init(columns: 100, rows: 60))
        withSpeed.snapshot = F.snapshot(F.reportA(), record: F.confirmed())
        withSpeed.step = .model
        withSpeed.peer = .reached(F.reportB(), seconds: 0.4, at: 1)
        withSpeed.plans = .ready(measured.map(\.option))
        let speedText = ClusterSetupContent.body(withSpeed, width: 100, glyphs: .unicode, interactive: true).map(\.text).joined(separator: "\n")
        expect(speedText.contains("first token") && speedText.contains("tok/s") && speedText.contains("Each alone"), "measured figures show: \(speedText)")
        expect(speedText.contains("Qwen3.8-27B-4bit-mtp") && !speedText.contains("EigenLabs/"), "names show without their publisher")
        // Not on the other Mac: blocked with the copy step.
        let alone = ClusterSetupPlanning.decide(readings: F.readings, description: F.pairDescription, localMemberID: "mac-a",
            localProfile: F.profileA, peerProfile: F.profileB, peerModels: [], measurements: [])
        expect(alone.allSatisfy { $0.option.blocker?.contains("copy it there first") == true }, "models only here say to copy them")
        // The other Mac holds the same entries under other folder names (a catalog download beside a copy): each
        // setup points every Mac at its own folder, never at this Mac's name for it.
        let renamed = F.models.map { model -> ClusterSetupLocalModel in var value = model; value.folder = "catalog-" + model.folder; return value }
        let elsewhere = ClusterSetupPlanning.decide(readings: F.readings, description: F.pairDescription, localMemberID: "mac-a",
            localProfile: F.profileA, peerProfile: F.profileB, peerModels: renamed, measurements: [])
        func directories(_ value: Any) -> [String: String] {
            if let object = value as? [String: Any] {
                var found = object.values.reduce(into: [String: String]()) { $0.merge(directories($1)) { a, _ in a } }
                if let id = object["id"] as? String, let directory = object["modelDirectory"] as? String { found[id] = directory }
                return found
            }
            return (value as? [Any])?.reduce(into: [String: String]()) { $0.merge(directories($1)) { a, _ in a } } ?? [:]
        }
        let planned = elsewhere.filter { $0.setup != nil }
        expect(!planned.isEmpty, "renamed folders on the other Mac still plan")
        for decision in planned {
            let folder = decision.option.model.folder
            for data in decision.setup!.configurations.values {
                let named = directories((try? JSONSerialization.jsonObject(with: data)) ?? [:])
                expect(named["mac-a"].map { URL(fileURLWithPath: $0).lastPathComponent } == folder
                    && named["mac-b"].map { URL(fileURLWithPath: $0).lastPathComponent } == "catalog-" + folder,
                    "\(folder): each Mac loads its own folder: \(named)")
            }
        }
        // A model no cluster stage adapter of this build runs is never offered (a start would refuse it on both Macs
        // after a long wait): that is the blocker, in plain words with no command.
        for withheld in F.readings {
            guard let described = try? withheld.capability.get(),
                  ClusterSetupPlanning.pairServingRefused(described.record, publicModelID: withheld.model.modelID) else { continue }
            let option = F.decisions.first { $0.option.model.folder == withheld.model.folder }?.option
            expect(option?.blocker == ClusterSetupPlanning.noStageAdapter, "\(withheld.model.modelID): not offered, plainly: \(option?.blocker ?? "offered")")
        }
        for option in F.decisions.map(\.option) {
            let words = option.blocker ?? ""
            expect(!words.contains("`darkbloom") && !words.contains("this Mac leads") && !words.contains("mac-a") && !words.contains("mac-b"),
                "\(option.model.modelID): the reason names no command, no member ID and no leader: \(words)")
        }
        // The decision also writes both setups, rank 0 this Mac's.
        let setup = F.decisions.first { $0.option.model.modelID == "Qwen3.5-9B" }?.setup
        expect(setup?.leaderID == "mac-a" && setup?.configurations.count == 2, "adopting writes both setups, this Mac leading")
    }
}
