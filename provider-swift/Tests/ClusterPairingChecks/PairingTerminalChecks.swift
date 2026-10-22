import Darwin
import Foundation

/// `darkbloom cluster pair` on two real pseudo-terminals: two child processes
/// (listener and connector) each on its own terminal, the check reading both
/// screens and typing on both keyboards as the person at the two Macs would.
extension PairingCheck {
    final class Terminal: @unchecked Sendable {
        let master: Int32, slave: Int32
        private let lock = NSLock()
        private var bytes = [UInt8]()
        private var stop = false

        init() {
            var primary: Int32 = -1, secondary: Int32 = -1
            var window = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
            precondition(openpty(&primary, &secondary, nil, nil, &window) == 0)
            master = primary; slave = secondary
            _ = fcntl(primary, F_SETFL, fcntl(primary, F_GETFL) | O_NONBLOCK)
            Thread.detachNewThread { [self] in
                var buffer = [UInt8](repeating: 0, count: 4096)
                while !lock.withLock({ stop }) {
                    var fd = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
                    guard poll(&fd, 1, 20) > 0 else { continue }
                    let count = read(master, &buffer, buffer.count)
                    if count > 0 { lock.withLock { bytes += buffer.prefix(count) } } else if count == 0 || (errno != EAGAIN && errno != EINTR) { return }
                }
            }
        }

        var text: String { String(decoding: lock.withLock { bytes }, as: UTF8.self) }
        func type(_ text: String) { _ = text.withCString { write(master, $0, strlen($0)) } }
        func close() { lock.withLock { stop = true }; Thread.sleep(forTimeInterval: 0.05); Darwin.close(master); Darwin.close(slave) }

        func wait(for needle: String, seconds: Double) -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { if text.contains(needle) { return true }; Thread.sleep(forTimeInterval: 0.02) }
            return text.contains(needle)
        }

        func code(seconds: Double) -> String? {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                if let range = text.range(of: "Pairing code:  [0-9]{3} [0-9]{3}", options: .regularExpression) {
                    return String(text[range].suffix(7))
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
            return nil
        }

        var canonicalMode: Bool {
            var mode = termios()
            _ = tcgetattr(slave, &mode)
            return mode.c_lflag & tcflag_t(ICANON) != 0 && mode.c_lflag & tcflag_t(ECHO) != 0
        }
    }

    static func spawnChild(_ arguments: [String], on terminal: Terminal) -> pid_t {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        for target in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] { posix_spawn_file_actions_adddup2(&actions, terminal.slave, target) }
        posix_spawn_file_actions_addclose(&actions, terminal.master)
        var pid: pid_t = 0
        let argv = ([child] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) }; posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawn(&pid, child, &actions, nil, argv, environ) == 0 else { return -1 }
        return pid
    }

    /// The exit status, or nil if it did not end in time (it is then killed).
    static func reap(_ pid: pid_t, seconds: Double) -> Int32? {
        let end = Date().addingTimeInterval(seconds)
        var status: Int32 = 0
        while Date() < end {
            if waitpid(pid, &status, WNOHANG) == pid { return (status & 0x7f) == 0 ? (status >> 8) & 0xff : -1 }
            Thread.sleep(forTimeInterval: 0.05)
        }
        kill(pid, SIGKILL); _ = waitpid(pid, &status, 0)
        return nil
    }

    struct TerminalPair {
        let listener = Terminal(), connector = Terminal()
        let listenerStore: URL, connectorStore: URL
        let listenerPID: pid_t, connectorPID: pid_t

        init(_ name: String) {
            let root = freshDirectory(name)
            listenerStore = root.appendingPathComponent("listener/cluster-pairing")
            connectorStore = root.appendingPathComponent("connector/cluster-pairing")
            try? FileManager.default.createDirectory(at: listenerStore.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: connectorStore.deletingLastPathComponent(), withIntermediateDirectories: true)
            let port = String(PairingCheck.port())
            listenerPID = spawnChild(["listen", port, listenerStore.path, root.appendingPathComponent("listener/identity.key").path], on: listener)
            _ = listener.wait(for: "Listening on lo0", seconds: 10)
            connectorPID = spawnChild(["connect", port, connectorStore.path, root.appendingPathComponent("connector/identity.key").path], on: connector)
        }
    }

    static func terminalBothConfirm() {
        let pair = TerminalPair("pty-confirm")
        defer { pair.listener.close(); pair.connector.close() }
        expect(pair.listenerPID > 0 && pair.connectorPID > 0, "both children started")
        expect(pair.listener.text.contains("On the other Mac run:  darkbloom cluster pair --connect"), "the listener says what to run on the other Mac")
        let listenerCode = pair.listener.code(seconds: 20), connectorCode = pair.connector.code(seconds: 20)
        expect(listenerCode != nil, "the listener's screen shows a code")
        expectEqual(listenerCode, connectorCode, "both screens show the same code")
        expect(pair.listener.text.contains("The other Mac:  Test connector"), "the listener names the other Mac")
        expect(pair.connector.text.contains("SIP on, Secure Boot full, sealed system volume"), "the connector shows the other Mac's attested posture")
        expect(pair.connector.text.contains("Do both screens show \(connectorCode ?? "?")? Type y or n: "), "the question names the code")
        expect(!pair.listener.canonicalMode, "the listener's terminal reads single keys while asking")
        // Too early, a stray key, and a paste: none of them answers.
        pair.connector.type("y")
        pair.listener.type("x")
        pair.listener.type("\u{1B}[200~y\u{1B}[201~")
        Thread.sleep(forTimeInterval: 1.2)
        expect(!pair.listener.text.contains("The other Mac confirmed"), "a y typed before the code could be read did not confirm")
        expect(!pair.connector.text.contains("The other Mac confirmed"), "neither a stray key nor a pasted y confirmed")
        pair.listener.type("y")
        expect(pair.listener.wait(for: "Confirmed here. Waiting for the other Mac", seconds: 5), "the listener waits for the other Mac")
        expect(pair.connector.wait(for: "The other Mac confirmed the code.", seconds: 5), "the connector is told the listener confirmed")
        let question = "Do both screens show \(connectorCode ?? "?")? Type y or n: "
        let reasked: () -> Bool = {
            let text = pair.connector.text
            guard let told = text.range(of: "The other Mac confirmed the code.") else { return false }
            return text[told.upperBound...].contains(question)
        }
        let askEnd = Date().addingTimeInterval(5)
        while Date() < askEnd && !reasked() { Thread.sleep(forTimeInterval: 0.02) }
        expect(reasked(), "the connector is asked again with the code itself, not just \"the same code\"")
        pair.connector.type("y")
        let listenerStatus = reap(pair.listenerPID, seconds: 20), connectorStatus = reap(pair.connectorPID, seconds: 20)
        expectEqual(listenerStatus, 0, "listener exits 0"); expectEqual(connectorStatus, 0, "connector exits 0")
        expect(pair.listener.text.contains("Paired. This Mac pins the other Mac's Secure Enclave key"), "the listener says it paired")
        expect(pair.connector.text.contains("Roster pty-pair, generation 1"), "the connector names the roster")
        expect(pair.connector.text.contains("No SSH was used."), "and that no SSH was used")
        expect(pair.listener.canonicalMode && pair.connector.canonicalMode, "both terminals are back in their normal mode")
        for store in [pair.listenerStore, pair.connectorStore] {
            expectEqual(mode(store.appendingPathComponent("pairings.json").path), 0o600, "\(store.lastPathComponent) pins 0600")
            expectEqual(mode(store.path), 0o700, "pairing directory 0700")
        }
        let both = pair.listener.text + pair.connector.text
        expect(!both.contains("\u{1B}[?2004h") || both.contains("\u{1B}[?2004l"), "bracketed paste is switched off again")
    }

    static func terminalDecline() {
        let pair = TerminalPair("pty-decline")
        defer { pair.listener.close(); pair.connector.close() }
        let code = pair.listener.code(seconds: 20)
        expect(code != nil && code == pair.connector.code(seconds: 20), "both show the code")
        Thread.sleep(forTimeInterval: 0.9)
        pair.connector.type("n")
        expectEqual(reap(pair.connectorPID, seconds: 15), 1, "the Mac that said no exits 1")
        expectEqual(reap(pair.listenerPID, seconds: 15), 1, "the other Mac exits 1")
        expect(pair.connector.text.contains("Not confirmed. Nothing was paired."), "the Mac that said no says so")
        expect(pair.listener.text.contains("The other Mac did not confirm the code. Nothing was paired."), "the other Mac is told")
        expect(pair.listener.text.contains("Not paired: the codes were not confirmed on the other Mac. Nothing was stored."), "the listener's closing line")
        expect(!FileManager.default.fileExists(atPath: pair.listenerStore.appendingPathComponent("pairings.json").path)
               && !FileManager.default.fileExists(atPath: pair.connectorStore.appendingPathComponent("pairings.json").path), "nothing stored on either")
        expect(pair.listener.canonicalMode, "the listener's terminal is restored after the other Mac declined")
        let audit = String(decoding: FileManager.default.contents(atPath: pair.listenerStore.appendingPathComponent("audit.jsonl").path) ?? Data(), as: UTF8.self)
        expect(audit.contains("declined_there") && audit.contains("attempt_failed"), "the decline is audited and counted")
    }
}
