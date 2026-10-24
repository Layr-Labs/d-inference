import Foundation
import Darwin

/// The onboarding's console on a terminal: plain lines (it scrolls like any
/// command, so what was said stays readable), single keys without enter for
/// y, n and q, and one typed line for the model number. Keys are read with
/// line editing and echo off; ^C still ends the command, and the terminal's
/// mode is put back on every way out, a signal included.
///
/// With colour on a UTF-8 terminal at least 40 columns wide, the setup opens
/// with the Darkbloom mark, headings carry a step meter and long work shows a
/// live line that the next said line replaces. The mark blooms and the live
/// line turns unless DARKBLOOM_NO_ANIMATION or CI is set. Without colour
/// (NO_COLOR, TERM=dumb, a pipe) every byte is the plain transcript.
public final class ClusterOnboardingTerminal: ClusterOnboardingConsole {
    private let input: Int32
    private let output: Int32
    private let usesColor: Bool
    /// Colour plus block glyphs and room for the mark.
    private let decorates: Bool
    /// The mark blooms and live work turns (never in a transcript).
    private let animates: Bool
    private let brand: String
    /// The live work line on screen, if any; the next said line replaces it.
    private var working: String?
    private var drawnFrame = -1
    private let echoesInput: Bool
    private var saved = termios()
    private var configured = false
    public private(set) var closed = false

    /// The mode to put back from a signal handler (one terminal per process).
    nonisolated(unsafe) private static var restoreInput: Int32 = -1
    nonisolated(unsafe) private static var restoreMode = termios()

    public init(input: Int32, output: Int32, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.input = input; self.output = output
        echoesInput = isatty(input) == 1 && isatty(output) == 1
        usesColor = Self.supportsColor(inputIsTerminal: isatty(input) == 1,
            outputIsTerminal: isatty(output) == 1, environment: environment)
        var window = winsize()
        let columns = ioctl(output, TIOCGWINSZ, &window) == 0 ? Int(window.ws_col) : 0
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
        configured = true
        Self.restoreInput = input
        Self.restoreMode = saved
        for number in [SIGINT, SIGTERM, SIGHUP] {
            signal(number) { received in
                var mode = ClusterOnboardingTerminal.restoreMode
                if ClusterOnboardingTerminal.restoreInput >= 0 { _ = tcsetattr(ClusterOnboardingTerminal.restoreInput, TCSANOW, &mode) }
                let text = Array("\r\nStopped. Run `darkbloom cluster` again to continue where it was.\r\n".utf8)
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
        // The said line takes the live line's row; the live line moves below it.
        write("\r\u{1B}[K" + line + "\n")
        drawWorking(live, force: true)
    }

    /// The setup's opening: the mark beside its name where the terminal can
    /// draw it (blooming when it animates), else the plain heading lines.
    public func banner(_ title: String, _ subtitle: String) {
        guard decorates else { heading(title); say(subtitle); return }
        let words = title.split(separator: " ", maxSplits: 1).map(String.init)
        let beside = ["\u{1B}[1m\(words.first ?? title)\u{1B}[0m",
                      "\u{1B}[2m\(words.count > 1 ? words[1] : "")\u{1B}[0m",
                      "\u{1B}[2m\(subtitle)\u{1B}[0m", ""]
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
    public func working(_ text: String) {
        guard decorates else { return }
        drawWorking(text, force: text != working)
    }

    /// Clears the live work line, leaving the cursor where it was.
    public func settle() {
        guard working != nil else { return }
        working = nil; drawnFrame = -1
        write("\r\u{1B}[K")
    }

    private func drawWorking(_ text: String, force: Bool) {
        let now = DispatchTime.now().uptimeNanoseconds
        let frame = animates ? Int((now / 125_000_000) % 4) : 0
        working = text
        guard force || frame != drawnFrame else { return }
        drawnFrame = frame
        let petal = animates ? ClusterOnboardingBrand.spin(now) : ClusterOnboardingBrand.spinner[0]
        write("\r\u{1B}[K  \u{1B}[\(brand)m\(petal)\u{1B}[0m \u{1B}[2m\(text)\u{2026}\u{1B}[0m")
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
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let count = bytes[offset...].withUnsafeBytes { Darwin.write(output, $0.baseAddress, $0.count) }
            if count > 0 { offset += count } else if count < 0, errno == EINTR || errno == EAGAIN { usleep(1_000) } else { return }
        }
    }

    public func key(milliseconds: Int) -> Character? {
        guard !closed else { return nil }
        var descriptor = pollfd(fd: input, events: Int16(POLLIN), revents: 0)
        let ready = Darwin.poll(&descriptor, 1, Int32(clamping: milliseconds))
        guard ready > 0 else { return nil }
        var byte: UInt8 = 0
        let count = Darwin.read(input, &byte, 1)
        if count <= 0 {
            if count == 0 || (errno != EINTR && errno != EAGAIN) { closed = true }
            return nil
        }
        // A key that sends a sequence (an arrow) is one escape; the rest is dropped.
        if byte == 0x1B { drainSequence(); return "\u{1B}" }
        return Character(UnicodeScalar(byte))
    }

    private func drainSequence() {
        var byte: UInt8 = 0
        var descriptor = pollfd(fd: input, events: Int16(POLLIN), revents: 0)
        while Darwin.poll(&descriptor, 1, 20) > 0, Darwin.read(input, &byte, 1) == 1 {}
    }

    public func line(prompt: String) -> String? {
        settle()
        write(prompt)
        var typed = ""
        while true {
            guard let key = key(milliseconds: 60_000) else {
                if closed { write("\n"); return nil }
                continue
            }
            switch key {
            case "\r", "\n":
                write("\n")
                return typed
            case "\u{7F}", "\u{08}":
                if !typed.isEmpty {
                    typed.removeLast()
                    if echoesInput && configured { write("\u{08} \u{08}") }
                }
            case "\u{1B}":
                continue
            default:
                guard key.isASCII, !key.isNewline, let value = key.asciiValue, value >= 0x20, typed.count < 16 else { continue }
                typed.append(key)
                if echoesInput && configured { write(String(key)) }
            }
        }
    }
}
