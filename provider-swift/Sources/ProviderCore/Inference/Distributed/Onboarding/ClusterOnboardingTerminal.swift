import Foundation
import Darwin

/// The onboarding's console on a terminal: plain lines (it scrolls like any
/// command, so what was said stays readable), single keys without enter for
/// y, n and q, and one typed line for the model number. Keys are read with
/// line editing and echo off; ^C still ends the command, and the terminal's
/// mode is put back on every way out, a signal included.
public final class ClusterOnboardingTerminal: ClusterOnboardingConsole {
    private let input: Int32
    private let output: Int32
    private let usesColor: Bool
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
        write(line + "\n")
    }

    static func supportsColor(inputIsTerminal: Bool, outputIsTerminal: Bool,
                              environment: [String: String]) -> Bool {
        inputIsTerminal && outputIsTerminal && environment["NO_COLOR"] == nil
            && environment["CLICOLOR"] != "0"
            && environment["TERM"].map { !$0.isEmpty && $0 != "dumb" } == true
    }

    public func heading(_ title: String) {
        say("")
        // No cursor movement or screen clearing: trust codes and recovery steps
        // stay in scrollback. Color never carries status by itself.
        say(usesColor ? "\u{1B}[1;36m" + title + "\u{1B}[0m" : title)
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
