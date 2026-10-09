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
            candidate: ConsoleFixtures.candidate(), journal: .ownershipUnproven,
            aliases: [.init(interface: "en6", presence: .gone)])), at: time)
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
        scrolling.fit(to: first)
        _ = scrolling.handle(.key(.end), at: time)
        let last = ClusterConsoleRenderer.frame(scrolling)
        expect(last.text.contains("Press ? for the reasons."), "the end of the body is reachable")
        let total = first.maximumScroll + first.bodyRows
        expect(last.lines[0].text.hasSuffix("lines \(first.maximumScroll + 1)-\(total) of \(total)"), "the header says where the body is: \(last.lines[0].text)")
        expect(first.lines[0].text.hasSuffix("lines 1-\(first.bodyRows) of \(total)") && first.lines[0].text.count == 60, "and it stays visible in a narrow window")
        _ = scrolling.handle(.resized(.init(columns: 200, rows: 300)), at: time)
        scrolling.fit(to: ClusterConsoleRenderer.frame(scrolling))
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
        let wrapped = ClusterConsoleRenderer.wrap(.init("alpha beta gamma delta epsilon", .normal, indent: 4), width: 16)
        expectEqual(wrapped.map(\.text), ["    alpha beta", "    gamma delta", "    epsilon"], "wrapping at spaces with a kept indent")
        expectEqual(ClusterConsoleRenderer.wrap(.init(String(repeating: "x", count: 25), .normal, indent: 2), width: 12).map(\.text),
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
                         "This build admits across two Macs: " + ClusterRuntimeAdapter.admittedModels.map { "\($0.runtimeModelID) (\($0.adapterID) v\($0.adapterVersion))" }.joined(separator: ", ") + ".",
                         "No model is selected", "No session was started from this screen.", "Local leader: not observed. No discovery file.",
                         "Nothing has been run from this screen.", "Not available in this build"] {
            expect(bare.contains(sentence), "the bare screen lacks: \(sentence)")
        }
        expect(!bare.contains("Worker binary") && !bare.contains("Peer host key"), "nothing about a setup that is not saved")

        // The fix is offered where the flow plans one, and reported as running only while it is.
        var bridged = state(ConsoleFixtures.snapshot(link: ConsoleFixtures.bridgedLink))
        expect(screen(bridged).contains("Press f to give that port an address. macOS asks for your approval"), "the fix is offered as a key")
        expect(!screen(bridged).contains("Next: run `darkbloom cluster`"), "the screen does not tell the operator to run itself")
        _ = bridged.handle(.key(.character("f")), at: time)
        expect(screen(bridged).contains("macOS was asked to approve the address. Answer its prompt.")
            && screen(bridged).contains("Fix link is running"), "while the fix runs the screen says a prompt is open")
        var dry = state(ConsoleFixtures.snapshot(link: ConsoleFixtures.bridgedLink), options: .init(dryRun: true, onboarding: false))
        _ = dry.handle(.key(.character("f")), at: time)
        expect(screen(dry).contains("Dry run: working out what the fix would ask for.") && !screen(dry).contains("Answer its prompt"),
            "a dry run never claims a prompt is open")
        expect(screen(dry).contains("dry run"), "the header marks a dry run")
        _ = dry.handle(.actionFinished(.fixLink, .init(succeeded: true, lines: ["Link fix (dry run): would ask for approval", "fixture sentence"])), at: time)
        expect(screen(dry).contains("06:00:00 Fix link") && screen(dry).contains("fixture sentence"), "the result is listed under Activity")
        expect(screen(state(ConsoleFixtures.snapshot(link: ConsoleFixtures.unpluggedLink))).contains("Watching for a connection: the link is read again every 2 seconds."),
            "the wait for a cable says how it waits")
        let disabled = screen(state(ConsoleFixtures.snapshot(link: ConsoleFixtures.disabledLink)))
        expect(disabled.contains("Readiness: link rdmaDisabled") && disabled.contains("rdma_ctl enable"), "RDMA off shows the probe's guidance")

        // A saved setup: who the peer is, by label and fingerprint, and the model.
        let saved = screen(state(ConsoleFixtures.snapshot(saved: ConsoleFixtures.savedSetup(), aliases: [.init(interface: "en7", presence: .present)])))
        for sentence in ["Cluster fixture-cluster: this Mac is peer-0 (leader, rank 0) on rdma_en7; the peer is peer-1 (rank 1).",
                         "Peer host key: ssh-ed25519 SHA256:QQQQ", "Known-hosts pin aaaaaaaaaaaa: the file still matches it.",
                         "Identity file: present and owner-only.", "Coordinator pair approval: none saved.",
                         "Saved setup serves fixture/public-model as registered_fixture",
                         "Rank 0, peer-0 (this Mac): layers 0 to 3 (4).", "Rank 1, peer-1: layers 4 to 31 (28).",
                         "Per-rank admission: not observed.", "12 of 12 manifest files present", "5.7 GiB",
                         "Weight contents are verified by the worker as it loads them, not here.",
                         "Worker binary: matches its pin; progress guard present; startup deadline accepted.",
                         "The address Darkbloom added to en7 is still on that port."] {
            expect(saved.contains(sentence), "the saved-setup screen lacks: \(sentence)")
        }
        expect(saved.contains("Darkbloom cluster \u{B7} cluster fixture-cluster \u{B7} link ready"), "the header names the cluster and the link state")

        // A setup waiting for approval is described and marked untrusted.
        let waiting = screen(state(ConsoleFixtures.snapshot(candidate: ConsoleFixtures.candidate())))
        expect(waiting.contains("Setup passed in for approval:") && waiting.contains("Not saved and not trusted. Press a, then y, to approve it"),
            "a waiting setup is shown as untrusted")
        var asking = state(ConsoleFixtures.snapshot(candidate: ConsoleFixtures.candidate()))
        _ = asking.handle(.key(.character("a")), at: time)
        expect(screen(asking).contains("Save this setup and trust peer-1 by the host key shown? y approves; any other key cancels."),
            "the question names the peer and both answers")

        // Trust that no longer holds is said plainly.
        var broken = ConsoleFixtures.savedSetup()
        broken = .init(state: .loaded, error: nil, configurationSHA256: broken.configurationSHA256,
            pairing: .init(clusterID: "fixture-cluster", memberID: "peer-0", role: .leader, localRank: 0, peerID: "peer-1", peerRank: 1,
                linkDevice: "rdma_en7", trust: .init(knownHostsPinSHA256: String(repeating: "a", count: 64), knownHostsPinMatches: false,
                    hostKeys: [], identityFileUsable: false, error: nil), pairApproval: nil),
            model: broken.model, installed: .init(workerBinary: .init(verified: true, detail: nil), hasProgressGuard: false,
                acceptsStartupDeadline: false, manifest: .init(verified: false, detail: "Product manifest raw pin or bound differs"), artifactFiles: nil))
        let untrusted = screen(state(ConsoleFixtures.snapshot(saved: broken)))
        for sentence in ["the file no longer matches it", "Identity file: missing, or not an owner-only regular file.",
                         "Peer host key: none could be read", "NO progress guard, so a start is refused",
                         "its manifest is not verified. Product manifest raw pin or bound differs"] {
            expect(untrusted.contains(sentence), "the broken-trust screen lacks: \(sentence)")
        }

        // The session section shows the leader's own report, and changes only when the report does.
        let fixture = try installedFixture("render")
        let binding = try ClusterStatusBinding(configuration: fixture.configuration, capability: fixture.capability)
        func live(host: String, phase: String, ready: Bool, capacity: [Int?]) -> ClusterLiveStatus {
            .init(schema: ClusterLiveStatus.schemaName, nonce: "n", binding: binding, authenticationConfigured: true, hostPhase: host,
                session: .init(binding: binding, phase: phase, observedMembershipEpoch: ready ? "11111111-2222-3333-4444-555555555555" : nil,
                    observedPrefillSchedule: ready ? .serial : nil, ready: ready,
                    admission: ready ? .init(remainingLifetimeNanoseconds: 281_000_000_000, remainingRequests: 15, activeRequest: false, draining: false, valid: true) : nil,
                    members: (0..<2).map { .init(peerID: "peer-\($0)", rank: $0, transport: $0 == 0 ? .localPipes : .authenticatedSSH,
                        nativeReady: capacity[$0] != nil, requestCapacityBytes: capacity[$0], nativeCleanupObserved: false,
                        ownerReleaseAcknowledged: false, ownerTermination: nil) },
                    mtpEnabled: false, mtpOffReason: "runtimeCapabilityDisablesSpeculation", nativeBootstrap: .directNative,
                    collectiveProgressLimitMilliseconds: 60_000),
                boundPort: 8000, acquisitions: 0, failed: false, ready: ready, admissionAvailable: ready, quarantined: false)
        }
        let starting = screen(state(ConsoleFixtures.snapshot(saved: ConsoleFixtures.savedSetup(),
            live: live(host: "starting", phase: "starting", ready: false, capacity: [1024 * 1024 * 3, nil]))))
        for sentence in ["Local leader: host starting, session starting, not ready, admission closed, port 8000, bearer authentication.",
                         "Rank 0, peer-0: localPipes; native ready;", "Rank 1, peer-1: authenticatedSSH; native not ready;",
                         "Rank 0, peer-0 (this Mac): layers 0 to 3 (4). Admitted and loaded; request capacity 3.0 MiB.",
                         "Rank 1, peer-1: layers 4 to 31 (28). Not ready.", "Epoch not observed; native bootstrap directNative (the peer that answers is not authenticated)"] {
            expect(starting.contains(sentence), "the starting session lacks: \(sentence)")
        }
        expect(!starting.contains("%"), "no percentage is shown for a load: a worker reports ready and nothing before it")
        let serving = screen(state(ConsoleFixtures.snapshot(saved: ConsoleFixtures.savedSetup(),
            live: live(host: "serving", phase: "ready", ready: true, capacity: [4096, 8192]))))
        for sentence in ["host serving, session ready, ready, admission available", "Epoch 11111111-2222-3333-4444-555555555555",
                         "Lifetime remaining 281 s; admissions remaining 15; no active request.", "Rank 1, peer-1: authenticatedSSH; native ready;"] {
            expect(serving.contains(sentence), "the serving session lacks: \(sentence)")
        }
        // A newer observation replaces the session lines, and only those.
        var observed = state(ConsoleFixtures.snapshot(saved: ConsoleFixtures.savedSetup()))
        expect(screen(observed).contains("Local leader: not observed."), "no session observed yet")
        _ = observed.handle(.sessionObserved(.init(status: ConsoleFixtures.diagnostics(link: ConsoleFixtures.readyLink,
            live: live(host: "serving", phase: "ready", ready: true, capacity: [4096, 8192])))), at: time)
        expect(screen(observed).contains("host serving, session ready") && screen(observed).contains("Cluster fixture-cluster"),
            "a session observation updates the session lines")

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
    }
}
