import Foundation
import Darwin

/// The terminal while the console owns it: no echo, no line editing and no
/// terminal signals, on the alternate screen with the cursor hidden and pastes
/// bracketed. `leave` puts back exactly what `init` found, and is safe to call
/// on every way out.
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

    /// The saved mode and where it goes, for the one caller that cannot wait
    /// for the run loop: a second request to end while the loop is stuck.
    struct Restore: @unchecked Sendable {
        let input: Int32
        let output: Int32
        let saved: termios

        /// Applied at once, without waiting for output to leave.
        func now() {
            var mode = saved
            _ = tcsetattr(input, TCSANOW, &mode)
        }

        /// Leaves the alternate screen if the terminal will take the few
        /// bytes that does without being waited on; otherwise not at all.
        func leaveScreenIfWritable() {
            var descriptor = pollfd(fd: output, events: Int16(POLLOUT), revents: 0)
            guard Darwin.poll(&descriptor, 1, 0) > 0, descriptor.revents & Int16(POLLOUT) != 0 else { return }
            let bytes = Array(ClusterConsoleTerminal.leaveScreen.utf8)
            _ = bytes.withUnsafeBytes { Darwin.write(output, $0.baseAddress, $0.count) }
        }
    }

    /// Alternate screen, hidden cursor, cleared, and pastes marked so that
    /// pasted text is never read as keys.
    private static let enterScreen = "\u{1B}[?1049h\u{1B}[?25l\u{1B}[?2004h\u{1B}[2J"
    fileprivate static let leaveScreen = "\u{1B}[?2004l\u{1B}[?25h\u{1B}[?1049l"
    /// Longest a write waits for a terminal that has stopped reading.
    static let writeAllowanceMilliseconds: Int32 = 5_000
    /// Small enough that a terminal which reports room has room for it.
    private static let writeChunkBytes = 512

    private let input: Int32
    private let output: Int32
    private let writeAllowanceMilliseconds: Int32
    private var saved = termios()
    private var entered = false

    public convenience init(input: Int32, output: Int32) throws {
        try self.init(input: input, output: output, writeAllowanceMilliseconds: Self.writeAllowanceMilliseconds)
    }

    /// `writeAllowanceMilliseconds` is shortened only by checks, which cannot wait out the real one.
    init(input: Int32, output: Int32, writeAllowanceMilliseconds: Int32) throws {
        self.input = input; self.output = output; self.writeAllowanceMilliseconds = writeAllowanceMilliseconds
        guard isatty(input) == 1, isatty(output) == 1, tcgetattr(input, &saved) == 0 else { throw Failure.notATerminal }
    }

    var restore: Restore { Restore(input: input, output: output, saved: saved) }

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
        var stalled = false
        do { try write(Array(Self.leaveScreen.utf8)) } catch Failure.cannotWrite(let code) { stalled = code == ETIMEDOUT } catch {}
        // The saved mode goes back once what was just written has left, and
        // keys typed while closing are dropped rather than handed to the
        // shell. A terminal that has stopped reading is not waited on: there
        // the mode goes back at once.
        if stalled || tcsetattr(input, TCSAFLUSH, &saved) != 0 { restore.now() }
    }

    /// Nil when the terminal does not report a size. A terminal nobody has
    /// sized reports 0 by 0, which is no size either.
    public func size() -> ClusterConsoleSize? {
        var window = winsize()
        guard ioctl(output, TIOCGWINSZ, &window) == 0, window.ws_col > 0, window.ws_row > 0 else { return nil }
        return .init(columns: Int(window.ws_col), rows: Int(window.ws_row))
    }

    /// Writes in small pieces, each only once the terminal has room, so a
    /// terminal that stops reading fails the write instead of holding the
    /// console, which takes its signals as events, beyond reach.
    public func write(_ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            var descriptor = pollfd(fd: output, events: Int16(POLLOUT), revents: 0)
            let ready = Darwin.poll(&descriptor, 1, writeAllowanceMilliseconds)
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0 else { throw Failure.cannotWrite(ready == 0 ? ETIMEDOUT : errno) }
            let count = min(bytes.count - offset, Self.writeChunkBytes)
            let written = bytes.withUnsafeBytes { Darwin.write(output, $0.baseAddress! + offset, count) }
            if written > 0 { offset += written; continue }
            guard errno == EINTR || errno == EAGAIN else { throw Failure.cannotWrite(errno) }
        }
    }

    deinit { leave() }
}
