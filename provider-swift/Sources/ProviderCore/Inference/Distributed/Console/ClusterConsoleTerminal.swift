import Foundation
import Darwin

/// The terminal while the console owns it: no echo, no line editing and no
/// terminal signals, on the alternate screen with the cursor hidden. `leave`
/// puts back exactly what `init` found, and is safe to call on every way out.
public final class ClusterConsoleTerminal {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case notATerminal
        case cannotConfigure(Int32)
        case cannotWrite(Int32)

        public var description: String {
            switch self {
            case .notATerminal: return "The cluster console needs a terminal on standard input and output."
            case .cannotConfigure(let code): return "The terminal could not be configured (errno \(code))."
            case .cannotWrite(let code): return "The terminal could not be written to (errno \(code))."
            }
        }
    }

    private static let enterScreen = "\u{1B}[?1049h\u{1B}[?25l\u{1B}[2J"
    private static let leaveScreen = "\u{1B}[?25h\u{1B}[?1049l"

    private let input: Int32
    private let output: Int32
    private var saved = termios()
    private var entered = false

    public init(input: Int32, output: Int32) throws {
        self.input = input; self.output = output
        guard isatty(input) == 1, isatty(output) == 1, tcgetattr(input, &saved) == 0 else { throw Failure.notATerminal }
    }

    public func enter() throws {
        var raw = saved
        raw.c_lflag &= ~tcflag_t(ECHO | ICANON | ISIG | IEXTEN)
        raw.c_iflag &= ~tcflag_t(IXON | ICRNL)
        // Frames carry their own carriage returns; nothing is rewritten on the way out.
        raw.c_oflag &= ~tcflag_t(OPOST)
        raw.c_cc.16 = 1 // VMIN: a read returns as soon as one byte is there.
        raw.c_cc.17 = 0 // VTIME: no read timeout; the loop polls instead.
        guard tcsetattr(input, TCSAFLUSH, &raw) == 0 else { throw Failure.cannotConfigure(errno) }
        entered = true
        try write(Array(Self.enterScreen.utf8))
    }

    /// Restores the screen and the saved mode. Does nothing the second time.
    public func leave() {
        guard entered else { return }
        entered = false
        let screenRestored = (try? write(Array(Self.leaveScreen.utf8))) != nil
        // The saved mode goes back after what was just written has left, and
        // keys typed while closing are dropped rather than handed to the
        // shell. That waits for the terminal to take the output, so it is
        // skipped for a terminal that has just refused a write: it is gone,
        // and waiting on it would never end.
        let waits = screenRestored || !Self.sameTerminal(input, output)
        _ = tcsetattr(input, waits ? TCSAFLUSH : TCSANOW, &saved)
    }

    /// Nil when the terminal does not report a size. A terminal nobody has
    /// sized reports 0 by 0, which is no size either.
    public func size() -> ClusterConsoleSize? {
        var window = winsize()
        guard ioctl(output, TIOCGWINSZ, &window) == 0, window.ws_col > 0, window.ws_row > 0 else { return nil }
        return .init(columns: Int(window.ws_col), rows: Int(window.ws_row))
    }

    public func write(_ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { Darwin.write(output, $0.baseAddress! + offset, bytes.count - offset) }
            if written > 0 { offset += written; continue }
            if errno == EINTR { continue }
            guard errno == EAGAIN else { throw Failure.cannotWrite(errno) }
            var descriptor = pollfd(fd: output, events: Int16(POLLOUT), revents: 0)
            _ = Darwin.poll(&descriptor, 1, 100)
        }
    }

    private static func sameTerminal(_ first: Int32, _ second: Int32) -> Bool {
        var a = stat(), b = stat()
        return first == second || (fstat(first, &a) == 0 && fstat(second, &b) == 0 && a.st_rdev == b.st_rdev)
    }

    deinit { leave() }
}
