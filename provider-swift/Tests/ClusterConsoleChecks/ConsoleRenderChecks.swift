import Foundation
import DarkbloomClusterProtocol
@testable import InstalledContract

extension ClusterConsoleCheck {
    private static let time = "06:00:00"

    /// A state with every section filled, so no size is tested on an empty screen.
    private static func fullState(columns: Int, rows: Int) -> ClusterConsoleState {
        var state = ClusterConsoleState(size: .init(columns: columns, rows: rows), options: .init(onboarding: false))
        _ = state.begin()
        _ = state.handle(.snapshot(ConsoleFixtures.snapshot(link: ConsoleFixtures.bridgedLink, saved: ConsoleFixtures.savedSetup(),
            candidate: ConsoleFixtures.candidate(), journal: .ownershipUnproven)), at: time)
        _ = state.handle(.key(.character("f")), at: time)
        _ = state.handle(.actionFinished(.fixLink, .init(succeeded: false, lines: ["Link fix: approvalDeclined", "The macOS prompt was cancelled; nothing was changed."])), at: time)
        _ = state.handle(.session(.output("session output line")), at: time)
        return state
    }

    /// The frame invariants, for any state at any size.
    private static func expectFits(_ state: ClusterConsoleState, _ what: String) {
        let frame = ClusterConsoleRenderer.frame(state)
        let columns = max(state.size.columns, 0), rows = max(state.size.rows, 0)
        expect(frame.lines.count <= rows, "\(what): \(frame.lines.count) lines for \(rows) rows")
        expect(frame.lines.allSatisfy { $0.text.count <= columns }, "\(what): a line is wider than \(columns) columns")
        let garbage = frame.lines.contains { $0.text.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F } }
        expect(!garbage, "\(what): a control character reached the screen")
        // The bytes hold exactly the frame: one row per line, nothing after a full screen.
        let bytes = String(decoding: frame.terminalBytes(color: true, rows: rows), as: UTF8.self)
        expect(bytes.hasPrefix("\u{1B}[H"), "\(what): a frame starts at the home position")
        expectEqual(bytes.components(separatedBy: "\r\n").count - 1,
            max(frame.lines.count - 1, 0) + (frame.lines.count < rows && !frame.lines.isEmpty ? 1 : 0), "\(what): row breaks")
        expect(!bytes.contains("\n\n") && !bytes.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "\(what): a bare line feed")
    }

    static func rendererSizes() throws {
        let sizes = [(0, 0), (0, 10), (10, 0), (1, 1), (2, 1), (5, 2), (10, 3), (27, 5), (27, 40), (28, 5), (28, 6), (30, 8),
                     (40, 10), (80, 24), (81, 25), (132, 50), (133, 43), (300, 100), (500, 200), (1000, 1000), (-5, -5)]
        for (columns, rows) in sizes {
            var state = fullState(columns: columns, rows: rows)
            expectFits(state, "full state at \(columns)x\(rows)")
            let frame = ClusterConsoleRenderer.frame(state)
            if columns >= ClusterConsoleRenderer.minimumColumns, rows >= ClusterConsoleRenderer.minimumRows {
                expectEqual(frame.lines.count, rows, "a normal frame fills the window at \(columns)x\(rows)")
                expectEqual(frame.bodyRows, rows - 3, "body rows at \(columns)x\(rows)")
            } else {
                expect(frame.maximumScroll == 0 && frame.lines.count <= 3, "a window too small shows only the short notice")
                if columns >= 17, rows >= 1 { expectEqual(frame.lines[0].text, "darkbloom cluster", "the short notice names the command") }
            }
            // Every scroll position, including ones past the end, still fits.
            for offset in [0, 1, frame.maximumScroll, frame.maximumScroll + 1, 100_000, -3] {
                state.scroll = offset
                expectFits(state, "scrolled to \(offset) at \(columns)x\(rows)")
            }
            state.scroll = 0
            _ = state.handle(.key(.character("?")), at: time)
            expectFits(state, "help at \(columns)x\(rows)")
            _ = state.handle(.key(.character("?")), at: time)
            _ = state.handle(.key(.character("a")), at: time)
            expectFits(state, "a question at \(columns)x\(rows)")
        }
        var empty = ClusterConsoleState(size: .init(columns: 80, rows: 24))
        expectFits(empty, "before the first reading")
        _ = empty.begin()
        expectFits(empty, "while the first reading runs")

        // Scrolling reaches the last line and no further.
        var scrolling = fullState(columns: 60, rows: 12)
        let first = ClusterConsoleRenderer.frame(scrolling)
        expect(first.maximumScroll > 0, "the full state does not fit twelve rows")
        scrolling.drew(first)
        _ = scrolling.handle(.key(.end), at: time)
        let last = ClusterConsoleRenderer.frame(scrolling)
        expect(last.text.contains("Press ? for the reasons."), "the end of the body is reachable")
        let total = first.maximumScroll + first.bodyRows
        expect(last.lines[0].text.hasSuffix("lines \(first.maximumScroll + 1)-\(total) of \(total)"), "the header says where the body is: \(last.lines[0].text)")
        expect(first.lines[0].text.hasSuffix("lines 1-\(first.bodyRows) of \(total)") && first.lines[0].text.count == 60, "and it stays visible in a narrow window")
        _ = scrolling.handle(.resized(.init(columns: 200, rows: 300)), at: time)
        scrolling.drew(ClusterConsoleRenderer.frame(scrolling))
        expectEqual(scrolling.scroll, 0, "a window that now shows everything is not left scrolled")

        // Text from a file or a child process cannot draw on the screen.
        var hostile = fullState(columns: 80, rows: 400)
        _ = hostile.handle(.session(.output("\u{1B}[2J\u{1B}[31mred\u{07}\tbell\r\nnext \u{9B}0m \u{202E}reversed 日本 😀")), at: time)
        _ = hostile.handle(.actionFinished(.recoverJournal, .init(succeeded: false, lines: ["bad\u{1B}]0;title\u{07}"])), at: time)
        let drawn = ClusterConsoleRenderer.frame(hostile)
        expectFits(hostile, "hostile text")
        expect(drawn.text.contains("?[2J?[31mred?") && !drawn.text.contains("\u{1B}"), "escape bytes are shown as question marks")
        let bytes = String(decoding: drawn.terminalBytes(color: false, rows: 400), as: UTF8.self)
        let sequences = bytes.components(separatedBy: "\u{1B}").dropFirst().map { String($0.prefix(2)) }
        expect(sequences.allSatisfy { $0 == "[H" || $0 == "[K" || $0 == "[J" }, "without colour the only sequences are home and clear: \(Set(sequences))")

        // Wrapping keeps indents and never splits inside a short word.
        let wrapped = ClusterConsoleRenderer.wrap(.init("alpha beta gamma delta epsilon", .normal, indent: 4, from: .wired("link.port")), width: 16)
        expect(wrapped.allSatisfy { $0.source == .wired("link.port") }, "every row of a wrapped line keeps its source")
        expectEqual(wrapped.map(\.text), ["    alpha beta", "    gamma delta", "    epsilon"], "wrapping at spaces with a kept indent")
        expectEqual(ClusterConsoleRenderer.wrap(.init(String(repeating: "x", count: 25), .normal, indent: 2, from: .frame), width: 12).map(\.text),
            ["  xxxxxxxxxx", "  xxxxxxxxxx", "  xxxxx"], "a word wider than the row is split")
        expectEqual(ClusterConsoleRenderer.wrap(.blank, width: 10).map(\.text), [""], "a blank line stays one row")
    }

    static func rendererContent() throws {
        /// The frame as drawn, then the body's sentences unwrapped, so a
        /// sentence is found wherever the window happens to break it.
        func screen(_ state: ClusterConsoleState) -> String {
            ClusterConsoleRenderer.frame(state).text + "\n" + ClusterConsoleContent.body(state).map(\.text).joined(separator: "\n")
        }
        func state(_ snapshot: ClusterConsoleSnapshot, options: ClusterConsoleState.Options = .init(onboarding: false)) -> ClusterConsoleState {
            var state = ClusterConsoleState(size: .init(columns: 132, rows: 400), options: options)
            _ = state.begin()
            _ = state.handle(.snapshot(snapshot), at: time)
            return state
        }

        // Nothing observed yet: the screen says so and shows no state.
        var opening = ClusterConsoleState(size: .init(columns: 100, rows: 30))
        _ = opening.begin()
        let first = ClusterConsoleRenderer.frame(opening).text
        expect(first.contains("Reading this Mac's") && !first.contains("ready") && !first.contains("Pairing"),
            "before the first reading no state is shown")

        // This Mac as it is tonight: link ready, nothing saved.
        let bare = screen(state(ConsoleFixtures.snapshot()))
        for sentence in ["Readiness: link ready", "RDMA setup detected: RDMA over Thunderbolt is enabled on this Mac.",
                         "rdma_en7 (en7): ready", "1 port down: rdma_en2", "Device journal: absent.",
                         "No cluster setup is saved on this Mac. Nothing is paired and no peer is trusted.",
                         "The cluster runtime in this build accepts a setup for: " + ClusterRuntimeAdapter.admittedModels.map { "\($0.runtimeModelID) (\($0.adapterID) v\($0.adapterVersion))" }.joined(separator: ", ")
                             + ". A start also applies its own model and chip checks.",
                         "registered_qwen35_9b (qwen35-dense-layer-stage v1), registered_qwen38_27b (qwen35-dense-layer-stage v1)",
                         "No model is selected", "No session was started from this screen.", "Local leader: not observed. No discovery file.",
                         "Nothing has been run from this screen.", "Not available in this build"] {
            expect(bare.contains(sentence), "the bare screen lacks: \(sentence)")
        }
        expect(!bare.contains("Worker binary") && !bare.contains("Pinned host key"), "nothing about a setup that is not saved")

        // The fix is offered where the flow plans one, and reported as running only while it is.
        var bridged = state(ConsoleFixtures.snapshot(link: ConsoleFixtures.bridgedLink))
        expect(screen(bridged).contains("Press f to give that port an address and install the system job that keeps it there. macOS asks for your approval; nothing changes without it."),
            "the fix is offered as a key, with what it does")
        let temporary = ClusterConsoleState.Options(temporary: true, onboarding: false)
        expect(screen(state(ConsoleFixtures.snapshot(link: ConsoleFixtures.bridgedLink, options: temporary), options: temporary))
            .contains("Press f to give that port an address that lasts until macOS next removes it."), "a temporary fix is offered as what it is")
        expect(!screen(bridged).contains("Next: run `darkbloom cluster`"), "the screen does not tell the operator to run itself")
        _ = bridged.handle(.key(.character("f")), at: time)
        expect(screen(bridged).contains("The link fix is running. If it asks, macOS shows its own prompt: approve or cancel it there.")
            && screen(bridged).contains("Fix link is running"), "while the fix runs the screen says so, and claims no prompt it cannot see")
        var dry = state(ConsoleFixtures.snapshot(link: ConsoleFixtures.bridgedLink), options: .init(dryRun: true, onboarding: false))
        _ = dry.handle(.key(.character("f")), at: time)
        expect(screen(dry).contains("Dry run: working out what an approval would run. Nothing is asked or changed.") && !screen(dry).contains("macOS shows its own prompt"),
            "a dry run never mentions a prompt opening")
        expect(screen(dry).contains("dry run"), "the header marks a dry run")
        _ = dry.handle(.actionFinished(.fixLink, .init(succeeded: true, lines: ["Link fix: dryRun", "fixture sentence"])), at: time)
        expect(screen(dry).contains("Press f for a dry run of the fix: it lists the commands an approval would run, and changes nothing."),
            "in a dry run the key is offered as a dry run")
        expect(screen(dry).contains("06:00:00 Fix link") && screen(dry).contains("fixture sentence"), "the result is listed under Activity")
        expect(screen(state(ConsoleFixtures.snapshot(link: ConsoleFixtures.unpluggedLink))).contains("Watching for a connection: the link is read again every 2 seconds."),
            "the wait for a cable says how it waits")
        // What Darkbloom assigned to a port, and whether anything keeps it there, is the probe's reading.
        let kept = screen(state(ConsoleFixtures.snapshot(link: ConsoleFixtures.keptLink)))
        expect(kept.contains("en7 carries the address Darkbloom assigned to it, and the system job that keeps it is installed and loaded.")
            && kept.contains("A system job (io.darkbloom.cluster-link.en7) keeps that address there.") && !kept.contains("Press f"),
            "a kept address is shown as kept, and no fix is offered")
        let unkept = screen(state(ConsoleFixtures.snapshot(link: ConsoleFixtures.temporaryLink)))
        expect(unkept.contains("Readiness: link ready") && unkept.contains("nothing keeps its address")
            && unkept.contains("en7 carries the address Darkbloom assigned to it, and no system job keeps it: macOS removes it when it next reconfigures the port.")
            && unkept.contains("Press f to install the system job that keeps that address there."), "a ready link whose address nothing keeps says so and offers the job")
        let lostKept = ConsoleFixtures.snapshot(link: ConsoleFixtures.lostKeptLink)
        let waitingForJob = screen(state(lostKept))
        expect(waitingForJob.contains("its recorded address is missing")
            && waitingForJob.contains("en6 does not carry the address Darkbloom has on record for it; its system job is loaded and runs every 10 seconds.")
            && waitingForJob.contains("Watching for the address: the link is read again every 2 seconds. Press f to put it there now and install its system job afresh."),
            "a lost address whose job is loaded is watched, with the key that does not wait")
        expect(screen(state(lostKept, options: .init(onboarding: true)))
            .contains("If it is not back after \(ClusterConsoleLinkSetup.keeperReadings) readings, the fix is asked for once and macOS shows its prompt."),
            "where the screen will ask by itself it says so, and after how long")
        let brief = ClusterConsoleState.Options(temporary: true, onboarding: false)
        expect(screen(state(ConsoleFixtures.snapshot(link: ConsoleFixtures.lostKeptLink, options: brief), options: brief))
            .contains("Watching for the address: the link is read again every 2 seconds. Press f to put it there now. macOS asks"),
            "with a temporary fix nothing is said about installing a job")
        expect(!screen(state(ConsoleFixtures.snapshot(link: ConsoleFixtures.lostKeptLink, live: try ConsoleFixtures.live()), options: .init(onboarding: true)))
            .contains("the fix is asked for once"), "the automatic fix is not promised where a session stands in its way")
        expect(screen(state(ConsoleFixtures.snapshot(link: ConsoleFixtures.lostLink)))
            .contains("en6 does not carry the address Darkbloom has on record for it, and no system job would put it back."), "a lost address nothing keeps")
        // The fixed rows: every key fits an 80-column window, and the header does not call an unreadable setup none.
        var eighty = state(ConsoleFixtures.snapshot())
        _ = eighty.handle(.resized(.init(columns: 80, rows: 24)), at: time)
        expectEqual(ClusterConsoleRenderer.frame(eighty).lines.last?.text, "r read  f fix  a approve  s start  x stop  c recover  e export  ? help  q quit",
            "the whole key line shows at 80 columns")
        let unreadable = ClusterConsoleSavedSetup(state: .unreadable, error: "Configuration input does not exist", configurationSHA256: nil,
            pairing: nil, model: nil, installed: nil)
        let lost = screen(state(ConsoleFixtures.snapshot(saved: unreadable)))
        expect(lost.contains("saved setup unreadable") && !lost.contains("no saved setup") && lost.contains("The saved setup cannot be read: Configuration input does not exist"),
            "an unreadable saved setup is called that")
        expect(screen(state(ConsoleFixtures.snapshot(journal: .ownershipUnproven))).contains("Device journal: not empty."), "a journal with something in it is called not empty, no more")
        var exporting = state(ConsoleFixtures.snapshot())
        _ = exporting.handle(.key(.character("e")), at: time)
        expect(screen(exporting).contains("Export diagnostics is running and has not reported yet.") && !screen(exporting).contains("Nothing has been run from this screen."),
            "while the first action is out the screen does not say nothing was run")
        let disabled = screen(state(ConsoleFixtures.snapshot(link: ConsoleFixtures.disabledLink)))
        expect(disabled.contains("Readiness: link rdmaDisabled") && disabled.contains("rdma_ctl enable"), "RDMA off shows the probe's guidance")

        // A saved setup: who the peer is, by label and fingerprint, and the model.
        let saved = screen(state(ConsoleFixtures.snapshot(saved: ConsoleFixtures.savedSetup())))
        for sentence in ["Cluster fixture-cluster: this Mac is peer-0 (leader, rank 0) on rdma_en7; the peer is peer-1 (rank 1).",
                         "Pinned host key: ssh-ed25519 SHA256:QQQQ", "Known-hosts pin aaaaaaaaaaaa: the file still matches it.",
                         "Identity file: present and owner-only.", "Coordinator pair approval: none saved.",
                         "Saved setup serves fixture/public-model as registered_fixture",
                         "Rank 0, peer-0 (this Mac): layers 0 to 3 (4).", "Rank 1, peer-1: layers 4 to 31 (28).",
                         "Per-rank admission: not observed.", "12 of 12 manifest files present", "5.7 GiB",
                         "Weight contents are verified by the worker as it loads them, not here.",
                         "Worker binary: matches its pin; progress guard present; startup deadline accepted."] {
            expect(saved.contains(sentence), "the saved-setup screen lacks: \(sentence)")
        }
        expect(saved.contains("Darkbloom cluster \u{B7} cluster fixture-cluster \u{B7} link ready"), "the header names the cluster and the link state")

        // A setup waiting for approval is described and marked untrusted.
        let waiting = screen(state(ConsoleFixtures.snapshot(candidate: ConsoleFixtures.candidate())))
        expect(waiting.contains("Setup passed in for approval:") && waiting.contains("Not saved and not trusted. Press a, then y, to approve it"),
            "a waiting setup is shown as untrusted")
        var asking = state(ConsoleFixtures.snapshot(candidate: ConsoleFixtures.candidate()))
        _ = asking.handle(.key(.character("a")), at: time)
        expect(screen(asking).contains("y: save setup eeeeeeeeeeee and trust its pinned keys. Any other key cancels."),
            "the question names the setup and both answers")
        expect(waiting.contains("setup eeeeeeeeeeee") && waiting.contains("Pinned host key: ssh-ed25519 SHA256:QQQQ"),
            "and the setup is shown by the same digest, with the keys it pins, before it is asked about")
        // Every question fits an 80-column window whole, and is on the frame's own row or not at all.
        for (key, question) in [("a", ClusterConsoleState.Question.approveSetup(expectedSHA256: ConsoleFixtures.candidateSHA256)),
                                ("s", .startSession), ("c", .recoverJournal)] as [(Character, ClusterConsoleState.Question)] {
            let text = ClusterConsoleRenderer.text(of: question)
            expect(text.count <= 80 && text.hasPrefix("y: ") && text.hasSuffix(" Any other key cancels."), "\(key): the question is one 80-column row with both answers: \(text.count)")
            for columns in [text.count, 80, 132, 400] {
                var wide = state(ConsoleFixtures.snapshot(saved: ConsoleFixtures.savedSetup(), candidate: ConsoleFixtures.candidate()))
                _ = wide.handle(.resized(.init(columns: columns, rows: 24)), at: time)
                _ = wide.handle(.key(.character(key)), at: time)
                let frame = ClusterConsoleRenderer.frame(wide)
                expect(frame.question == question && frame.lines[frame.lines.count - 2].text == text, "\(key) at \(columns) columns: the whole question is on its row")
            }
            var narrow = state(ConsoleFixtures.snapshot(saved: ConsoleFixtures.savedSetup(), candidate: ConsoleFixtures.candidate()))
            _ = narrow.handle(.resized(.init(columns: text.count - 1, rows: 24)), at: time)
            _ = narrow.handle(.key(.character(key)), at: time)
            let frame = ClusterConsoleRenderer.frame(narrow)
            expect(frame.question == nil && narrow.asking == nil && frame.lines[frame.lines.count - 2].text.hasPrefix("Window too narrow to ask."),
                "\(key): one column short, the question is not asked and the row says why")
        }

        // Trust that no longer holds is said plainly.
        var broken = ConsoleFixtures.savedSetup()
        broken = .init(state: .loaded, error: nil, configurationSHA256: broken.configurationSHA256,
            pairing: .init(clusterID: "fixture-cluster", memberID: "peer-0", role: .leader, localRank: 0, peerID: "peer-1", peerRank: 1,
                linkDevice: "rdma_en7", trust: .init(knownHostsPinSHA256: String(repeating: "a", count: 64), knownHostsPinMatches: false,
                    hostKeys: [], hostKeysNotShown: 0, identityFileUsable: false, error: nil), pairApproval: nil),
            model: broken.model, installed: .init(workerBinary: .init(verified: true, detail: nil), hasProgressGuard: false,
                acceptsStartupDeadline: false, manifest: .init(verified: false, detail: "Product manifest raw pin or bound differs"), artifactFiles: nil))
        let untrusted = screen(state(ConsoleFixtures.snapshot(saved: broken)))
        for sentence in ["the file no longer matches it", "Identity file: missing, or not an owner-only regular file.",
                         "Pinned known-hosts file: no key could be read from it.", "NO progress guard, so a start is refused",
                         "its manifest is not verified. Product manifest raw pin or bound differs"] {
            expect(untrusted.contains(sentence), "the broken-trust screen lacks: \(sentence)")
        }

        // The session section shows the leader's own report, and changes only when the report does.
        func live(host: String, phase: String, ready: Bool, capacity: [Int?]) throws -> ClusterLiveStatus {
            try ConsoleFixtures.live(host: host, phase: phase, ready: ready, capacity: capacity)
        }
        let starting = screen(state(ConsoleFixtures.snapshot(saved: ConsoleFixtures.savedSetup(),
            live: try live(host: "starting", phase: "starting", ready: false, capacity: [1024 * 1024 * 3, nil]))))
        for sentence in ["Local leader: host starting, session starting, not ready, admission closed, port 8000, bearer authentication.",
                         "Rank 0, peer-0: localPipes; native ready;", "Rank 1, peer-1: authenticatedSSH; native not ready;",
                         "Rank 0, peer-0 (this Mac): layers 0 to 3 (4).", "Rank 1, peer-1: layers 4 to 31 (28).",
                         "Rank 0, peer-0: admitted and loaded, by the leader's status; request capacity 3.0 MiB.",
                         "Rank 1, peer-1: not ready, by the leader's status.",
                         "Epoch not observed; native bootstrap directNative (the peer that answers is not authenticated)"] {
            expect(starting.contains(sentence), "the starting session lacks: \(sentence)")
        }
        expect(!starting.contains("%"), "no percentage is shown for a load: a worker reports ready and nothing before it")
        let serving = screen(state(ConsoleFixtures.snapshot(saved: ConsoleFixtures.savedSetup(),
            live: try live(host: "serving", phase: "ready", ready: true, capacity: [4096, 8192]))))
        for sentence in ["host serving, session ready, ready, admission available", "Epoch 11111111-2222-3333-4444-555555555555",
                         "Lifetime remaining 281 s; admissions remaining 15; no active request.", "Rank 1, peer-1: authenticatedSSH; native ready;"] {
            expect(serving.contains(sentence), "the serving session lacks: \(sentence)")
        }
        // A newer observation replaces the session lines, and only those.
        var observed = state(ConsoleFixtures.snapshot(saved: ConsoleFixtures.savedSetup()))
        expect(screen(observed).contains("Local leader: not observed."), "no session observed yet")
        _ = observed.handle(.sessionObserved(.init(status: ConsoleFixtures.diagnostics(link: ConsoleFixtures.readyLink,
            live: try live(host: "serving", phase: "ready", ready: true, capacity: [4096, 8192])))), at: time)
        expect(screen(observed).contains("host serving, session ready") && screen(observed).contains("Cluster fixture-cluster"),
            "a session observation updates the session lines")

        let follower = screen(state(ConsoleFixtures.snapshot(saved: ConsoleFixtures.savedSetup(role: .follower))))
        expect(follower.contains("Per-rank admission: not observed. A worker admits as it loads, and the leader's status, which reports it, was not read.")
            && !follower.contains("no session is being served"), "a follower, which reads no status, is not told that nothing is serving")

        // A pinned file with more than host keys in it is described by what each entry is, and by how many are not listed.
        var crowded = ConsoleFixtures.savedSetup()
        crowded = .init(state: .loaded, error: nil, configurationSHA256: crowded.configurationSHA256,
            pairing: .init(clusterID: "fixture-cluster", memberID: "peer-0", role: .leader, localRank: 0, peerID: "peer-1", peerRank: 1,
                linkDevice: "rdma_en7", trust: .init(knownHostsPinSHA256: String(repeating: "a", count: 64), knownHostsPinMatches: true,
                    hostKeys: [.init(kind: .host, algorithm: "ssh-ed25519", fingerprint: "SHA256:host"),
                               .init(kind: .certificateAuthority, algorithm: "ssh-rsa", fingerprint: "SHA256:authority"),
                               .init(kind: .revoked, algorithm: "ssh-ed25519", fingerprint: "SHA256:revoked")],
                    hostKeysNotShown: 3, identityFileUsable: true, error: nil), pairApproval: nil),
            model: crowded.model, installed: crowded.installed)
        let listed = screen(state(ConsoleFixtures.snapshot(saved: crowded)))
        for sentence in ["Pinned host key: ssh-ed25519 SHA256:host", "Pinned certificate authority, whose signed host keys are accepted: ssh-rsa SHA256:authority",
                         "Pinned as revoked, and refused: ssh-ed25519 SHA256:revoked", "3 more keys in the pinned file are not listed here."] {
            expect(listed.contains(sentence), "the crowded known-hosts screen lacks: \(sentence)")
        }

        // Every line that states something names a wired row, and between them
        // the lines and the actions account for every wired row and no other.
        var sources = Set(ClusterConsoleAction.allCases.map(\.wiring))
        var ran = state(ConsoleFixtures.snapshot(link: ConsoleFixtures.lostLink, saved: broken, candidate: ConsoleFixtures.candidate(),
            journal: .ownershipUnproven))
        _ = ran.handle(.key(.character("e")), at: time)
        _ = ran.handle(.actionFinished(.exportDiagnostics, .init(succeeded: true, lines: ["Wrote x.json"])), at: time)
        _ = ran.handle(.session(.output("a line of session output")), at: time)
        let shown = [ran, state(ConsoleFixtures.snapshot()), state(ConsoleFixtures.snapshot(link: ConsoleFixtures.unpluggedLink)),
                     state(ConsoleFixtures.snapshot(saved: ConsoleFixtures.savedSetup(), live: try live(host: "serving", phase: "ready", ready: true, capacity: [4096, 8192]))),
                     state(ConsoleFixtures.snapshot(saved: crowded, candidate: ConsoleFixtures.candidate(error: "unreadable")))]
        for state in shown {
            for line in ClusterConsoleContent.body(state) {
                guard case .wired(let id) = line.source else { continue }
                expect(ClusterConsoleWiring.wired.contains(id), "a line names \(id), which is not a wired row: \(line.text)")
                sources.insert(id)
            }
        }
        expectEqual(Set(ClusterConsoleWiring.wired).subtracting(sources).sorted(), [], "wired rows that no line and no action shows")
        // Nothing the build cannot do is the source of a line.
        expect(sources.isDisjoint(with: ClusterConsoleWiring.unavailable.map(\.id)), "an unavailable element is the source of a line")

        // Help lists every key and every thing this build cannot do, with its reason.
        var help = state(ConsoleFixtures.snapshot())
        _ = help.handle(.key(.character("?")), at: time)
        let page = screen(help)
        for item in ClusterConsoleWiring.unavailable {
            expect(page.contains("\(item.title): \(item.reason)"), "help lacks the reason for \(item.id)")
        }
        for action in ClusterConsoleAction.allCases { expect(page.contains("\(action.key)  "), "help lacks the key for \(action)") }

        // The plain output is the same state without keys.
        let plain = ConsoleFixtures.snapshot(link: ConsoleFixtures.bridgedLink, saved: ConsoleFixtures.savedSetup(),
            candidate: ConsoleFixtures.candidate()).plainLines.joined(separator: "\n")
        for sentence in ["Readiness: link portBridgedWithoutAddress", "Next: run `darkbloom cluster` in a terminal on this Mac and approve the macOS prompt",
                         "Cluster fixture-cluster: this Mac is peer-0", "`darkbloom cluster configure`, or `a` in the console, approves it.",
                         "Local leader: not observed.", "Join: A member in this build declines every pairing"] {
            expect(plain.contains(sentence), "the plain output lacks: \(sentence)")
        }
        expect(!plain.contains("Press f") && !plain.contains("Press ?") && !plain.contains("\u{1B}"), "the plain output offers no keys and no escapes")
        let plainWaiting = lostKept.plainLines.joined(separator: "\n")
        expect(plainWaiting.contains("Waiting for it") && plainWaiting.contains("Nothing is waited for here: run this again in a few seconds"),
            "printed output says that it does not wait for the system job")
        expect(plain.contains("Remove the port's address and its system job: `darkbloom cluster link --remove` does it"), "and names the removal it has no key for")
    }
}
