import Foundation
import Darwin
@testable import InstalledContract

/// A real pseudo-terminal pair. The console runs on the slave end exactly as
/// it runs on a terminal window; the check types on the master end and reads
/// what the console drew there.
final class PseudoTerminal: @unchecked Sendable {
    let master: Int32
    let slave: Int32
    private let lock = NSLock()
    private var captured = [UInt8]()
    private var masterOpen = true
    private var stopReading = false
    private let readerStopped = DispatchSemaphore(value: 0)

    /// `reads: false` is a terminal that has stopped taking output: nothing drains what the console writes.
    init(columns: Int, rows: Int, reads: Bool = true) throws {
        var primary: Int32 = -1, secondary: Int32 = -1
        var window = winsize(ws_row: UInt16(rows), ws_col: UInt16(columns), ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&primary, &secondary, nil, nil, &window) == 0 else { throw ClusterConfigurationError.invalid("openpty failed") }
        master = primary; slave = secondary
        _ = fcntl(primary, F_SETFL, fcntl(primary, F_GETFL) | O_NONBLOCK)
        guard reads else {
            readerStopped.signal()
            return
        }
        let reader = primary
        // The reader never blocks inside `read`, so the master can be closed
        // from another thread without closing a descriptor under a sleeper.
        Thread.detachNewThread { [self] in
            defer { readerStopped.signal() }
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while !lock.withLock({ stopReading }) {
                var descriptor = pollfd(fd: reader, events: Int16(POLLIN), revents: 0)
                guard Darwin.poll(&descriptor, 1, 10) > 0 else { continue }
                let count = Darwin.read(reader, &buffer, buffer.count)
                if count > 0 { lock.withLock { captured.append(contentsOf: buffer.prefix(count)) } }
                else if count == 0 || (errno != EINTR && errno != EAGAIN) { return }
            }
        }
    }

    func send(_ bytes: [UInt8]) {
        _ = bytes.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }
    }

    func send(_ text: String) { send(Array(text.utf8)) }

    /// Changes the window size, as a terminal does when its window is dragged.
    /// The kernel signals only the terminal's own foreground process group,
    /// which this in-process console is not, so the caller sends SIGWINCH.
    func resize(columns: Int, rows: Int) {
        var window = winsize(ws_row: UInt16(rows), ws_col: UInt16(columns), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &window)
    }

    var mode: termios {
        var value = termios()
        _ = tcgetattr(slave, &value)
        return value
    }

    /// Everything the console has written so far.
    var output: String { String(decoding: lock.withLock { captured }, as: UTF8.self) }

    /// The rows of the last frame drawn, without the sequences that drew them.
    var screen: [String] {
        guard var frame = output.components(separatedBy: "\u{1B}[H").last, output.contains("\u{1B}[H") else { return [] }
        // A frame shorter than the window ends by clearing what is below it.
        if let below = frame.range(of: "\r\n\u{1B}[J") { frame = String(frame[..<below.lowerBound]) }
        return Self.strippingSequences(frame).components(separatedBy: "\r\n")
    }

    var screenText: String { screen.joined(separator: "\n") }

    static func strippingSequences(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
    }

    /// Waits until the screen satisfies `condition`; false when it never did.
    func wait(_ seconds: Double = 5, until condition: (String) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition(screenText) { return true }
            usleep(10_000)
        }
        return condition(screenText)
    }

    /// The terminal goes away: the console sees its input close.
    func closeMaster() {
        let close = lock.withLock { () -> Bool in
            defer { masterOpen = false; stopReading = true }
            return masterOpen
        }
        guard close else { return }
        readerStopped.wait()
        Darwin.close(master)
    }

    deinit {
        closeMaster()
        Darwin.close(slave)
    }
}

/// The run loop on a pseudo-terminal, on its own thread, with scripted operations.
final class ConsoleRun: @unchecked Sendable {
    let terminal: PseudoTerminal
    let operations: ScriptedOperations
    /// The terminal's mode before the console touched it: what must be back when it is done.
    let initialMode: termios
    private let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var outcome: Result<ClusterConsoleExit, Error>?

    init(_ operations: ScriptedOperations, columns: Int = 132, rows: Int = 100,
         options: ClusterConsoleState.Options = .init(onboarding: false, questionDwellMilliseconds: 0), candidate: ClusterConsoleCandidate? = nil,
         handlesSignals: Bool = false, output: PseudoTerminal? = nil) throws {
        self.operations = operations
        terminal = try PseudoTerminal(columns: columns, rows: rows)
        initialMode = terminal.mode
        let configuration = ClusterConsoleRunLoop.Configuration(options: options, candidate: candidate, color: true,
            darkbloomVersion: "0.0.0-check", pollMilliseconds: 40, escapeMilliseconds: 250, handlesSignals: handlesSignals,
            clock: { "06:00:00" })
        let input = terminal.slave, outputDescriptor = output?.slave ?? terminal.slave, scripted = operations.operations
        Thread.detachNewThread { [self] in
            let result = Result { try ClusterConsoleRunLoop.run(input: input, output: outputDescriptor, configuration: configuration, operations: scripted) }
            lock.withLock { outcome = result }
            finished.signal()
        }
    }

    var isRunning: Bool { lock.withLock { outcome == nil } }

    /// How the loop ended; nil when it is still running after `seconds`.
    func end(within seconds: Double = 5) -> Result<ClusterConsoleExit, Error>? {
        guard finished.wait(timeout: .now() + seconds) == .success else { return nil }
        finished.signal()
        return lock.withLock { outcome }
    }
}

extension ClusterConsoleCheck {
    /// The settings a terminal must have back when the console is done with it.
    static func sameMode(_ a: termios, _ b: termios) -> Bool {
        a.c_lflag == b.c_lflag && a.c_iflag == b.c_iflag && a.c_oflag == b.c_oflag && a.c_cflag == b.c_cflag
            && a.c_cc.16 == b.c_cc.16 && a.c_cc.17 == b.c_cc.17
    }

    static func isRaw(_ mode: termios) -> Bool {
        mode.c_lflag & tcflag_t(ECHO | ICANON | ISIG) == 0
    }

    static let enterScreen = "\u{1B}[?1049h", leaveScreen = "\u{1B}[?1049l"

    /// As `sameMode`, for a mode put back at once on a terminal that had
    /// stopped reading: the kernel then marks input as pending, and nothing else differs.
    static func sameModeApartFromPendingInput(_ a: termios, _ b: termios) -> Bool {
        var a = a, b = b
        a.c_lflag &= ~tcflag_t(PENDIN); b.c_lflag &= ~tcflag_t(PENDIN)
        return sameMode(a, b)
    }
}

/// A scripted session whose events the check sends itself.
final class ScriptedSessionLaunch: @unchecked Sendable {
    let session: ScriptedSession
    private let lock = NSLock()
    private var report: (@Sendable (ClusterConsoleSessionEvent) -> Void)?

    init(processIdentifier: Int32) { session = ScriptedSession(processIdentifier: processIdentifier) }

    /// Installed as the operations' launch: hands back the session and keeps the way to report on it.
    func launch(_ events: @escaping @Sendable (ClusterConsoleSessionEvent) -> Void) -> any ClusterConsoleSessionHandle {
        lock.withLock { report = events }
        return session
    }

    /// The session process reports something, as its reader thread would.
    func send(_ event: ClusterConsoleSessionEvent) { lock.withLock { report }?(event) }
}
