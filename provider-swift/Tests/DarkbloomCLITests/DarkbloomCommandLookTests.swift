import Foundation
import Testing

@testable import ProviderCore

// The Darkbloom look of the everyday commands, written into memory: the setup's rules, the mark, the live line and
// what a plain transcript keeps. The commands' own runs are in `ClusterPairCommandsTests` (`DarkbloomCommandLookRunTests`).

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = ""
    func append(_ text: String) { lock.withLock { bytes += text } }
    var text: String { lock.withLock { bytes } }
}

private let terminal = ["TERM": "xterm-256color", "LANG": "en_US.UTF-8"]
/// The brand colour without COLORTERM: the nearest of the 256.
private let colour = "38;5;27"

private func makeLook(_ mode: DarkbloomCommandLook.Mode, _ recorder: Recorder) -> DarkbloomCommandLook {
    DarkbloomCommandLook(mode: mode, environment: terminal, output: { recorder.append($0) }, pause: { _ in })
}

private func mode(_ changes: [String: String] = [:], input: Bool = true, output: Bool = true,
                  columns: Int = 100) -> DarkbloomCommandLook.Mode {
    .of(inputIsTerminal: input, outputIsTerminal: output, columns: columns,
        environment: terminal.merging(changes) { $1 })
}

@Suite("the Darkbloom look of the everyday commands", .serialized)
struct DarkbloomCommandLookTests {
    @Test("the setup's rules: both ends a terminal, colour allowed, UTF-8 and 40 columns; it animates unless CI or DARKBLOOM_NO_ANIMATION")
    func rules() {
        #expect(mode() == .init(decorates: true, animates: true, columns: 100))
        #expect(mode(["NO_COLOR": "1"]) == .init(decorates: false, animates: false, columns: 100))
        #expect(mode(["TERM": "dumb"]).decorates == false)
        #expect(mode(["CLICOLOR": "0"]).decorates == false)
        #expect(mode(["LANG": "C"]).decorates == false)
        #expect(mode(columns: 39).decorates == false)
        #expect(mode(columns: 40).decorates)
        #expect(mode(output: false).decorates == false)
        #expect(mode(input: false).decorates == false)
        #expect(mode(["CI": "true"]) == .init(decorates: true, animates: false, columns: 100))
        #expect(mode(["DARKBLOOM_NO_ANIMATION": "1"]) == .init(decorates: true, animates: false, columns: 100))
        // The cluster setup's screen decides colour by the same rule.
        for environment in [terminal, terminal.merging(["NO_COLOR": "1"]) { $1 }, terminal.merging(["TERM": "dumb"]) { $1 }] {
            #expect(ClusterOnboardingTerminal.supportsColor(inputIsTerminal: true, outputIsTerminal: true, environment: environment)
                == mode(environment).decorates)
        }
    }

    @Test("plain: nothing is written, and every line is the command's own print, in order")
    func plain() async {
        for plainMode in [DarkbloomCommandLook.Mode.plain, mode(["NO_COLOR": "1"]), mode(["TERM": "dumb"]), mode(columns: 30),
                          mode(output: false)] {
            let recorder = Recorder(), said = Recorder()
            let look = makeLook(plainMode, recorder)
            look.open("Darkbloom stop")
            let value = await look.working("Stopping both Macs") { () async -> Int in
                look.say("This Mac is in a two-Mac cluster: stopping both Macs.") { said.append($0 + "\n") }
                DarkbloomCommandLook.say("  1 accepted request(s) remaining") { said.append($0 + "\n") }
                return 7
            }
            #expect(value == 7)
            #expect(recorder.text.isEmpty, "\(plainMode)")
            #expect(said.text == "This Mac is in a two-Mac cluster: stopping both Macs.\n  1 accepted request(s) remaining\n")
        }
    }

    @Test("in a terminal: the mark beside the title once, then the live line, which each said line replaces and which is cleared at the end")
    func decorated() {
        let recorder = Recorder()
        let look = makeLook(.init(decorates: true, animates: false, columns: 100), recorder)
        look.open("Darkbloom stop")
        look.open("Darkbloom stop")
        look.working("Stopping both Macs") {
            look.say("first") { recorder.append($0 + "\n") }
            DarkbloomCommandLook.say("second") { recorder.append($0 + "\n") }
        }
        DarkbloomCommandLook.say("after") { recorder.append($0 + "\n") }
        let rows = ClusterOnboardingBrand.rows()
        let mark = "  \u{1B}[\(colour)m\(rows[0])\u{1B}[0m\n"
            + "  \u{1B}[\(colour)m\(rows[1])\u{1B}[0m   \u{1B}[1mDarkbloom\u{1B}[0m \u{1B}[2mstop\u{1B}[0m\n"
            + "  \u{1B}[\(colour)m\(rows[2])\u{1B}[0m\n" + "  \u{1B}[\(colour)m\(rows[3])\u{1B}[0m\n"
        let live = "\r\u{1B}[J" + ClusterOnboardingBrand.noWrap + "  \u{1B}[\(colour)m\u{2596}\u{1B}[0m \u{1B}[2mStopping both Macs\u{2026}\u{1B}[0m"
            + ClusterOnboardingBrand.wrap
        #expect(recorder.text == "\n" + mark + "\n" + live + "\r\u{1B}[J" + "first\n" + live + "\r\u{1B}[J" + "second\n" + live
            + "\r\u{1B}[J" + "after\n")
        #expect(rows.count == 4 && rows.allSatisfy { $0.count == ClusterOnboardingBrand.width })
    }

    @Test("the mark blooms in the setup's frames where it animates; the live line stays one row in a narrow window")
    func bloomAndRoom() {
        let recorder = Recorder()
        makeLook(.init(decorates: true, animates: true, columns: 100), recorder).open("Darkbloom update")
        let frames = recorder.text.components(separatedBy: "\u{1B}[\(ClusterOnboardingBrand.height)A")
        #expect(frames.count == ClusterOnboardingBrand.frames.count)
        #expect(frames.last?.hasSuffix(DarkbloomCommandLook.mark("Darkbloom update", revealed: Int.max, colour: colour) + "\n") == true)
        let row = DarkbloomCommandLook.liveRow(String(repeating: "x", count: 80), petal: "\u{2596}", colour: colour, columns: 40)
        #expect(row.contains(String(repeating: "x", count: 34) + "\u{2026}") && !row.contains(String(repeating: "x", count: 35)))
        // A window too narrow for the mark and its title keeps the plain transcript.
        let narrow = Recorder()
        makeLook(.init(decorates: true, animates: true, columns: 33), narrow).open("Darkbloom restart")
        #expect(narrow.text.isEmpty)
    }

    @Test("at 40 columns a long reason is shortened, never wrapped: line wrap is off for each redraw, the width is read again each time")
    func longReasonAtFortyColumns() {
        let recorder = Recorder()
        let width = Recorder()
        width.append("40")
        let look = DarkbloomCommandLook(mode: .init(decorates: true, animates: false, columns: 40), environment: terminal,
                                        output: { recorder.append($0) }, pause: { _ in }, width: { Int(width.text) ?? 40 })
        let reason = "Starting the provider service (Gemma 4 26B: part ended (exit 1: another update operation owns the lock\n(pid 952)) \u{00B7} 1 min 3 s"
        look.working(reason) { look.say("  a line said meanwhile") { recorder.append($0 + "\n") } }
        let draws = recorder.text.components(separatedBy: ClusterOnboardingBrand.noWrap).dropFirst()
        #expect(draws.count == 2 && draws.allSatisfy { $0.contains(ClusterOnboardingBrand.wrap) })
        let rows = draws.map { ($0.components(separatedBy: ClusterOnboardingBrand.wrap).first ?? "")
            .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression) }
        #expect(rows.allSatisfy { $0.count <= 39 && !$0.contains("\n") }, "\(rows)")
        #expect(rows.allSatisfy { $0.hasSuffix("\u{2026} \u{00B7} 1 min 3 s\u{2026}") }, "the time is kept: \(rows)")
        // The window made narrower: the next redraw fits the new width.
        let narrow = Recorder()
        let shrinking = DarkbloomCommandLook(mode: .init(decorates: true, animates: false, columns: 100), environment: terminal,
                                             output: { narrow.append($0) }, pause: { _ in }, width: { 40 })
        shrinking.working(reason) {}
        let drawn = (narrow.text.components(separatedBy: ClusterOnboardingBrand.noWrap).dropFirst().first ?? "")
            .components(separatedBy: ClusterOnboardingBrand.wrap).first ?? ""
        #expect(drawn.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression).count <= 39)
        // Plain: nothing at all, so nothing repeats.
        let plain = Recorder()
        DarkbloomCommandLook(mode: .plain, environment: terminal, output: { plain.append($0) }, pause: { _ in }).working(reason) {}
        #expect(plain.text.isEmpty)
    }

    @Test("every way out of the live line clears it, a failure included; the cursor is never hidden and the mode never changed")
    func everyWayOut() async {
        struct Failure: Error {}
        let recorder = Recorder()
        let look = makeLook(.init(decorates: true, animates: true, columns: 100), recorder)
        await #expect(throws: Failure.self) {
            try await look.working("Restarting the provider") { () async throws -> Void in throw Failure() }
        }
        #expect(recorder.text.hasSuffix("\r\u{1B}[J"))
        #expect(throws: Failure.self) { try look.working("Restarting the provider") { () throws -> Void in throw Failure() } }
        #expect(recorder.text.hasSuffix("\r\u{1B}[J"))
        // Lines said after it go straight through: no live line is left to clear.
        let said = Recorder()
        DarkbloomCommandLook.say("next") { said.append($0) }
        #expect(said.text == "next" && recorder.text.hasSuffix("\r\u{1B}[J"))
        #expect(!recorder.text.contains("\u{1B}[?25l"))
    }
}
