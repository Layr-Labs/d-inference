import Foundation
import Darwin

/// The onboarding's console on a terminal: plain lines (it scrolls like any
/// command, so what was said stays readable), choices from a list, and single
/// keys (q cancels). Keys are read with line editing and echo off; ^C still
/// ends the command, and the terminal's mode is put back on every way out, a
/// signal included.
///
/// With colour on a terminal, a choice is a list the person moves through with
/// ↑ and ↓ and takes with enter, as `darkbloom start` picks models; once taken
/// it folds to the one chosen line. With colour on a UTF-8 terminal at least
/// 40 columns wide, headings carry a step meter and long work shows a one-row
/// live line that the next said line replaces; where the mark and its text fit
/// on one row each, the setup opens with the Darkbloom mark. The mark blooms
/// and the live line turns unless DARKBLOOM_NO_ANIMATION or CI is set. Without
/// colour (NO_COLOR, TERM=dumb, a pipe) every byte is the plain transcript: a
/// choice is its numbered lines and one key (a number, enter, or a letter).
public final class ClusterOnboardingTerminal: ClusterOnboardingConsole {
    private let input: Int32
    private let output: Int32
    private let usesColor: Bool
    /// Colour plus block glyphs and room for the mark.
    private let decorates: Bool
    /// The mark blooms and live work turns (never in a transcript).
    private let animates: Bool
    /// The window's width in columns when the setup started (0 when unknown).
    private let columns: Int
    private let brand: String
    /// The live work rows on screen (one, or one per Mac while the parts load), if any; the next said line replaces them.
    private var working: [String]?
    private var drawnFrame = -1
    private let echoesInput: Bool
    private var saved = termios()
    /// The mode keys are read in (no line editing, no echo), put back after `suspended`.
    private var reading = termios()
    private var configured = false
    public private(set) var closed = false

    /// What a signal (Ctrl-C) says before the command ends.
    static var stoppedLine: String { ClusterOnboardingCommand.named("Stopped. Run `darkbloom cluster` again to continue where it was.") }
    /// `stoppedLine`'s bytes, made before the handlers are set: a signal handler only writes them.
    nonisolated(unsafe) private static var stoppedBytes: [UInt8] = []

    /// The mode to put back from a signal handler (one terminal per process).
    nonisolated(unsafe) private static var restoreInput: Int32 = -1
    nonisolated(unsafe) private static var restoreMode = termios()
    /// A list is up with the cursor hidden: a signal shows it again before the command ends.
    nonisolated(unsafe) private static var cursorHidden = false

    public init(input: Int32, output: Int32, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.input = input; self.output = output
        echoesInput = isatty(input) == 1 && isatty(output) == 1
        usesColor = Self.supportsColor(inputIsTerminal: isatty(input) == 1,
            outputIsTerminal: isatty(output) == 1, environment: environment)
        var window = winsize()
        let columns = ioctl(output, TIOCGWINSZ, &window) == 0 ? Int(window.ws_col) : 0
        self.columns = columns
        decorates = usesColor && ClusterOnboardingBrand.drawsBlocks(environment) && columns >= 40
        animates = decorates && environment["DARKBLOOM_NO_ANIMATION"] == nil && environment["CI"] == nil
        brand = ClusterOnboardingBrand.colour(environment)
        guard isatty(input) == 1, tcgetattr(input, &saved) == 0 else { return }
        var mode = saved
        mode.c_lflag &= ~tcflag_t(ICANON | ECHO)
        // One byte at a time, no wait inside read: poll decides how long.
        withUnsafeMutablePointer(to: &mode.c_cc) {
            $0.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { $0[Int(VMIN)] = 1; $0[Int(VTIME)] = 0 }
        }
        guard tcsetattr(input, TCSANOW, &mode) == 0 else { return }
        reading = mode
        configured = true
        Self.restoreInput = input
        Self.restoreMode = saved
        Self.stoppedBytes = Array("\r\n\(Self.stoppedLine)\r\n".utf8)
        for number in [SIGINT, SIGTERM, SIGHUP] {
            signal(number) { received in
                var mode = ClusterOnboardingTerminal.restoreMode
                if ClusterOnboardingTerminal.restoreInput >= 0 { _ = tcsetattr(ClusterOnboardingTerminal.restoreInput, TCSANOW, &mode) }
                // Nothing is allocated here: a literal in the binary, and the bytes made before the handlers were set.
                if ClusterOnboardingTerminal.cursorHidden {
                    let show: StaticString = "\u{1B}[?25h"
                    _ = Darwin.write(STDOUT_FILENO, show.utf8Start, show.utf8CodeUnitCount)
                }
                let text = ClusterOnboardingTerminal.stoppedBytes
                _ = text.withUnsafeBytes { Darwin.write(STDOUT_FILENO, $0.baseAddress, $0.count) }
                Darwin._exit(128 + received)
            }
        }
    }

    deinit { restore() }

    public func restore() {
        guard configured else { return }
        configured = false
        _ = tcsetattr(input, TCSANOW, &saved)
        Self.restoreInput = -1
    }

    public func say(_ line: String) {
        guard let live = working else { write(line + "\n"); return }
        // The said line takes the live rows' place; the live rows move below it.
        write(Self.up(live.count) + "\r\u{1B}[J" + line + "\n")
        working = nil
        drawWorking(live, force: true)
    }

    /// Bold for the stressed part in a colour terminal, as the outcome's title; plain text otherwise.
    public func sayStressed(_ lead: String, _ stressed: String, _ tail: String) {
        say(usesColor && !stressed.isEmpty ? lead + "\u{1B}[1m" + stressed + "\u{1B}[0m" + tail : lead + stressed + tail)
    }

    public var width: Int? { columns > 0 ? columns : nil }

    /// From the last live row back to the first.
    private static func up(_ rows: Int) -> String { rows > 1 ? "\u{1B}[\(rows - 1)A" : "" }

    /// The outcome block: the rules dim, the outcome bold, green for ✓ and red for ✗ (the mark carries it too).
    public func result(_ succeeded: Bool, _ title: String, _ lines: [String]) {
        let rule = usesColor ? "\u{1B}[2m" + ClusterOnboardingDriver.resultRule + "\u{1B}[0m" : ClusterOnboardingDriver.resultRule
        let mark = succeeded ? ClusterOnboardingDriver.done : ClusterOnboardingDriver.failed
        say("")
        say(rule)
        say(usesColor ? "\u{1B}[1;\(succeeded ? "32" : "31")m\(mark) \(title)\u{1B}[0m" : "\(mark) \(title)")
        for line in lines { say("  " + line) }
        say(rule)
    }

    /// The setup's opening: the mark beside its name where the terminal can
    /// draw it (blooming when it animates), else the plain heading lines.
    public func banner(_ title: String, _ subtitle: String) {
        let words = title.split(separator: " ", maxSplits: 1).map(String.init)
        let texts = [words.first ?? title, words.count > 1 ? words[1] : "", subtitle]
        // Each row is the mark, then its text. A row wider than the window
        // wraps, and the bloom's climb of `height` rows would leave the top
        // behind: such a window keeps the heading lines (and the meter).
        let widest = 2 + ClusterOnboardingBrand.width + 3 + (texts.map(\.count).max() ?? 0)
        guard decorates, widest < columns else { heading(title); if !subtitle.isEmpty { say(subtitle) }; return }
        let beside = ["\u{1B}[1m\(texts[0])\u{1B}[0m", "\u{1B}[2m\(texts[1])\u{1B}[0m",
                      "\u{1B}[2m\(texts[2])\u{1B}[0m", ""]
        func draw(_ revealed: Int) {
            let rows = ClusterOnboardingBrand.rows(revealed: revealed)
            write(zip(rows, beside).map { "  \u{1B}[\(brand)m\($0)\u{1B}[0m   \($1)" }.joined(separator: "\n") + "\n")
        }
        write("\n")
        guard animates else { draw(Int.max); return }
        for (index, revealed) in ClusterOnboardingBrand.frames.enumerated() {
            if index > 0 { write("\u{1B}[\(ClusterOnboardingBrand.height)A") }
            draw(revealed)
            usleep(55_000)
        }
    }

    /// Live work under the last said line: a turning petal and what runs.
    /// Plain transcripts show nothing extra.
    public func working(_ text: String) { workingRows([text]) }

    /// Live rows, one per row of the window (the first with the turning petal); plain transcripts show nothing extra.
    public func workingRows(_ rows: [String]) {
        guard decorates, !rows.isEmpty else { return }
        drawWorking(rows, force: rows != working)
    }

    /// Clears the live work rows, leaving the cursor at the start of the first.
    public func settle() {
        guard let live = working else { return }
        working = nil; drawnFrame = -1
        write(Self.up(live.count) + "\r\u{1B}[J")
    }

    /// A copy's or download's report: the live line, laid out for its room, where
    /// one shows; in a transcript only the logged reports, as plain lines.
    public func progress(_ text: (_ width: Int?) -> String, logged: Bool) {
        guard decorates else { if logged { say("  " + text(nil)) }; return }
        // Redrawn at most eight times a second: a copy or download reports more often than a person reads.
        let now = DispatchTime.now().uptimeNanoseconds
        let due = now &- progressDrawn >= 125_000_000
        if due { progressDrawn = now }
        drawWorking([text(liveRoom)], force: due)
    }

    /// When the progress line was last redrawn (uptime, nanoseconds).
    private var progressDrawn: UInt64 = 0

    /// One row only: the return and erase that replace the live line reach just
    /// the cursor's row, so a wrapped line would leave its start behind.
    /// Room: the indent, petal and space, the ellipsis and the last column.
    private var liveRoom: Int { max(1, columns - 6) }

    private func drawWorking(_ rows: [String], force: Bool) {
        let now = DispatchTime.now().uptimeNanoseconds
        let frame = animates ? Int((now / 125_000_000) % 4) : 0
        let shownRows = working?.count ?? 0
        working = rows
        guard force || frame != drawnFrame else { return }
        drawnFrame = frame
        let petal = animates ? ClusterOnboardingBrand.spin(now) : ClusterOnboardingBrand.spinner[0]
        // Each row fits one row of the window: the climb back to the first row counts rows, never wrapped lines.
        // Named for the running identity before it is fitted, so a renamed command never grows a fitted row (DevNet).
        func fit(_ text: String) -> String {
            let text = ClusterOnboardingCommand.named(text)
            return text.count > liveRoom ? String(text.prefix(liveRoom)) : text
        }
        let drawn = rows.enumerated().map { index, text in
            index == 0 ? "  \u{1B}[\(brand)m\(petal)\u{1B}[0m \u{1B}[2m\(fit(text))\u{2026}\u{1B}[0m" : "    \u{1B}[2m\(fit(text))\u{1B}[0m"
        }
        write(Self.up(shownRows) + "\r\u{1B}[J" + drawn.joined(separator: "\n"))
    }

    static func supportsColor(inputIsTerminal: Bool, outputIsTerminal: Bool,
                              environment: [String: String]) -> Bool {
        inputIsTerminal && outputIsTerminal && environment["NO_COLOR"] == nil
            && environment["CLICOLOR"] != "0"
            && environment["TERM"].map { !$0.isEmpty && $0 != "dumb" } == true
    }

    public func heading(_ title: String) {
        say("")
        // No screen clearing: trust codes and recovery steps stay in
        // scrollback. Color never carries status by itself.
        guard usesColor else { say(title); return }
        guard decorates else { say("\u{1B}[1;36m" + title + "\u{1B}[0m"); return }
        let meter = ClusterOnboardingBrand.meter(title).map { "   \u{1B}[\(brand)m\($0)\u{1B}[0m" } ?? ""
        say("\u{1B}[\(brand)m\u{25C6}\u{1B}[0m \u{1B}[1m" + title + "\u{1B}[0m" + meter)
    }

    private func write(_ text: String) {
        let bytes = Array(ClusterOnboardingCommand.named(text).utf8)
        var offset = 0
        while offset < bytes.count {
            let count = bytes[offset...].withUnsafeBytes { Darwin.write(output, $0.baseAddress, $0.count) }
            if count > 0 { offset += count } else if count < 0, errno == EINTR || errno == EAGAIN { usleep(1_000) } else { return }
        }
    }

    public func key(milliseconds: Int) -> Character? {
        guard let byte = rawByte(milliseconds: milliseconds) else { return nil }
        guard byte == 0x1B else { return Character(UnicodeScalar(byte)) }
        // A lone escape is a key (it cancels a wait); a key that sends a sequence (an arrow) is none, so an arrow
        // pressed during a wait never stops it.
        guard rawByte(milliseconds: 30) != nil else { return "\u{1B}" }
        drainSequence()
        return nil
    }

    /// One byte of input, or nil when `milliseconds` passed with none or the input closed.
    private func rawByte(milliseconds: Int) -> UInt8? {
        guard !closed else { return nil }
        var descriptor = pollfd(fd: input, events: Int16(POLLIN), revents: 0)
        guard Darwin.poll(&descriptor, 1, Int32(clamping: milliseconds)) > 0 else { return nil }
        var byte: UInt8 = 0
        let count = Darwin.read(input, &byte, 1)
        if count <= 0 {
            if count == 0 || (errno != EINTR && errno != EAGAIN) { closed = true }
            return nil
        }
        return byte
    }

    private func drainSequence() {
        var byte: UInt8 = 0
        var descriptor = pollfd(fd: input, events: Int16(POLLIN), revents: 0)
        while Darwin.poll(&descriptor, 1, 20) > 0, Darwin.read(input, &byte, 1) == 1 {}
    }

    // MARK: - Choices

    /// One of `options`: a list moved with ↑↓ (the ▸ marks the line) and taken with enter where the terminal shows
    /// colour, as `darkbloom start` picks models; elsewhere the numbered lines and one key.
    public func choose(_ options: [String], selected: Int, abandon: () -> Bool) -> Int? {
        guard !options.isEmpty else { return nil }
        settle()
        let start = min(max(0, selected), options.count - 1)
        return usesColor ? pick(options, start, abandon) : typedChoice(options, start, abandon)
    }

    /// The list, redrawn in place on each key; once taken it folds to the chosen line (cancelled: to nothing), so
    /// what scrolls up is what was chosen. q cancels; a number takes its line, and so does a letter only one option
    /// starts with. Every row, the hint's too, fits the window: a wrapped row would stay behind when the list folds.
    private func pick(_ options: [String], _ start: Int, _ abandon: () -> Bool) -> Int? {
        var cursor = start
        let marker = decorates ? "\u{25B8}" : ">"
        let room = columns > 10 ? columns - 6 : Int.max
        let rows = options.count + 1
        func fit(_ text: String) -> String {
            let text = ClusterOnboardingCommand.named(text)
            return text.count > room ? String(text.prefix(room - 1)) + "\u{2026}" : text
        }
        let hints = decorates ? ["\u{2191}\u{2193} move \u{00B7} enter select \u{00B7} q cancel", "\u{2191}\u{2193} \u{00B7} enter \u{00B7} q"]
            : ["up/down move, enter select, q cancel", "up/down, enter, q"]
        let hint = fit(hints.first { $0.count <= room } ?? hints[hints.count - 1])
        func draw(again: Bool) {
            var frame = again ? "\u{1B}[\(rows)A" : ""
            frame += "\r\u{1B}[J  \u{1B}[2m\(hint)\u{1B}[0m\n"
            for (index, option) in options.enumerated() {
                frame += index == cursor ? "  \u{1B}[\(brand)m\(marker)\u{1B}[0m \u{1B}[1m\(fit(option))\u{1B}[0m\n" : "    \(fit(option))\n"
            }
            write(frame)
        }
        // The cursor is hidden while the list is up and shown again as it folds, before the chosen line, so no line
        // after a choice starts with a terminal code.
        func fold(_ chosen: Int?) -> Int? {
            write("\u{1B}[\(rows)A\r\u{1B}[J\u{1B}[?25h")
            Self.cursorHidden = false
            if let chosen { write("  \u{1B}[\(brand)m\(marker)\u{1B}[0m \(fit(options[chosen]))\n") }
            return chosen
        }
        Self.cursorHidden = true
        write("\u{1B}[?25l")
        draw(again: false)
        while true {
            if abandon() { return fold(nil) }
            guard let key = readKey(milliseconds: 100) else {
                if closed { return fold(nil) }
                continue
            }
            switch key {
            case .up: cursor = (cursor + options.count - 1) % options.count
            case .down: cursor = (cursor + 1) % options.count
            case .enter: return fold(cursor)
            case .cancel: return fold(nil)
            case .character(let character):
                // q is cancel before it is a letter ("Qwen3.8 27B" is taken with the arrows, its number or another letter).
                if character == "q" || character == "Q" { return fold(nil) }
                if let number = character.wholeNumberValue, options.count <= 9 {
                    if options.indices.contains(number - 1) { return fold(number - 1) }
                } else if character.isLetter, let index = ClusterOnboardingChoice.match(String(character), options: options, selected: cursor) {
                    return fold(index)
                }
                continue
            }
            draw(again: true)
        }
    }

    /// The plain transcript's choice: the numbered lines once, then one key where it can only mean one line (a number
    /// of a short list, a letter one option starts with), enter for the default, or a number and enter. The prompt's
    /// line ends with the option taken, written the same on a terminal and a pipe (no echo), so every plain
    /// presentation keeps one transcript.
    private func typedChoice(_ options: [String], _ start: Int, _ abandon: () -> Bool) -> Int? {
        for (index, option) in options.enumerated() { say("  \(index + 1)) \(option)") }
        // Enter takes the first line unless another is the default, which the prompt then names.
        let prompt = "  Choose 1-\(options.count)" + (start == 0 ? "" : " (enter = \(start + 1))") + ": "
        // The option taken, by its name: what the list said after its first " · " (a size, how it moves) is above.
        func finish(_ index: Int?) -> Int? {
            write((index.map { options[$0].components(separatedBy: " \u{00B7} ")[0] } ?? "") + "\n")
            return index
        }
        write(prompt)
        var text = ""
        while true {
            if abandon() { return finish(nil) }
            guard let key = key(milliseconds: 100) else {
                if closed { return finish(nil) }
                continue
            }
            switch key {
            case "\r", "\n":
                if let index = ClusterOnboardingChoice.match(text, options: options, selected: start) {
                    // Typed digits are on screen already; enter alone shows the default it took.
                    if text.isEmpty { return finish(index) }
                    write("\n")
                    return index
                }
                text = ""
                write("\n" + prompt)
            case "\u{7F}", "\u{08}":
                if !text.isEmpty {
                    text.removeLast()
                    if echoesInput && configured { write("\u{08} \u{08}") }
                }
            case "\u{1B}":
                return finish(nil)
            default:
                guard key.isASCII, let value = key.asciiValue, value >= 0x20, text.count < 8 else { continue }
                if text.isEmpty {
                    if key == "q" || key == "Q" { return finish(nil) }
                    if let number = key.wholeNumberValue, options.count <= 9 {
                        if options.indices.contains(number - 1) { return finish(number - 1) }
                        continue
                    }
                    if key.isLetter, let index = ClusterOnboardingChoice.match(String(key), options: options, selected: start) {
                        return finish(index)
                    }
                }
                text.append(key)
                if echoesInput && configured { write(String(key)) }
            }
        }
    }

    private enum Key: Equatable { case up, down, enter, cancel, character(Character) }

    /// One key with the arrows decoded (ESC [ A, ESC O B); a lone escape cancels; other sequences are dropped.
    private func readKey(milliseconds: Int) -> Key? {
        guard let first = rawByte(milliseconds: milliseconds) else { return nil }
        switch first {
        case 0x1B:
            guard let second = rawByte(milliseconds: 30) else { return .cancel }
            guard second == 0x5B || second == 0x4F, let third = rawByte(milliseconds: 30) else { drainSequence(); return nil }
            switch third {
            case 0x41: return .up
            case 0x42: return .down
            default: drainSequence(); return nil
            }
        case 0x0D, 0x0A: return .enter
        default: return .character(Character(UnicodeScalar(first)))
        }
    }

    /// The terminal in its ordinary mode while `body` runs (sudo reads a password there), the live line cleared.
    public func suspended<T>(_ body: () -> T) -> T {
        settle()
        guard configured else { return body() }
        _ = tcsetattr(input, TCSANOW, &saved)
        defer { _ = tcsetattr(input, TCSANOW, &reading) }
        return body()
    }
}
