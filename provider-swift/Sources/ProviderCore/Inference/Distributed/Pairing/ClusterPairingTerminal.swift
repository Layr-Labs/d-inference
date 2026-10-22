import Darwin
import DarkbloomClusterRemote
import DarkbloomClusterSecurity
import Foundation

/// The person's side of `darkbloom cluster pair` on a terminal: what is shown
/// while the ceremony runs, and the one question it asks. Only a single `y`
/// or `n` key answers, and only after the code has been on screen for a
/// moment; a paste is dropped whole, so a stray clipboard can never confirm.
/// It needs a terminal on standard input: a code is confirmed by a person.
///
/// Built only from Foundation and the cluster modules so the pairing check
/// runner drives it on a real pseudo-terminal.
public final class ClusterPairingTerminal: @unchecked Sendable {
    public static let dwellMilliseconds = 700

    private let input: Int32
    private let write: @Sendable (String) -> Void
    private let lock = NSLock()
    private var pending: (@Sendable (Bool) -> Void)?
    private var savedMode: termios?
    private var readerWake: [Int32] = [-1, -1]
    private var peerAnswered: Bool?
    private var shownCode: String?

    public init(input: Int32 = STDIN_FILENO, write: @escaping @Sendable (String) -> Void = { text in
        FileHandle.standardOutput.write(Data(text.utf8))
    }) {
        self.input = input; self.write = write
    }

    deinit { restoreMode() }

    public static func isTerminal(_ descriptor: Int32 = STDIN_FILENO) -> Bool { isatty(descriptor) == 1 }

    public func say(_ line: String) { write(line + "\r\n") }

    /// Callbacks for `ClusterLinkPairing.run`.
    public func callbacks(otherMacCommand: @escaping @Sendable (_ interface: String, _ port: UInt16) -> String?)
        -> ClusterLinkPairing.Callbacks {
        ClusterLinkPairing.Callbacks(progress: { [weak self] progress in
            guard let self else { return }
            switch progress {
            case .searching(let interface):
                self.say("Looking for the other Mac on \(interface)…")
            case .listening(let interface, let port):
                self.say("Listening on \(interface), port \(port), for \(Int(ClusterPairingPolicy.codeLifetimeSeconds / 60)) minutes.")
                if let command = otherMacCommand(interface, port) { self.say("On the other Mac run:  \(command)") }
            case .dialing: self.say("Dialing the other Mac over the link…")
            case .connected: self.say("Connected over the link.")
            case .refused(let reason): self.say("Link connection refused (\(reason)); still trying.")
            case .storing: self.say("Storing the pin, the roster and the link key (owner-only files)…")
            }
        }, askConfirmation: { [weak self] code, peer, respond in
            self?.ask(code: code, peer: peer, respond: respond)
        }, peerDecided: { [weak self] accepted in
            self?.peerDecided(accepted)
        })
    }

    /// "482 913".
    public static func spaced(_ code: String) -> String { code.count == 6 ? "\(code.prefix(3)) \(code.suffix(3))" : code }

    public static func describe(_ peer: ClusterPairingPeer) -> [String] {
        let posture = peer.posture
        let security = [posture.sipEnabled ? "SIP on" : "SIP OFF", posture.secureBootEnabled ? "Secure Boot full" : "Secure Boot reduced",
                        posture.authenticatedRootEnabled ? "sealed system volume" : "system volume NOT sealed"].joined(separator: ", ")
        return ["The other Mac:  \(peer.name)",
                "                \(posture.hardwareModel), macOS \(posture.osVersion); \(security)",
                "                Secure Enclave key pin \(peer.pin.prefix(16))…, on its \(peer.interface)"]
    }

    private func ask(code: String, peer: ClusterPairingPeer, respond: @escaping @Sendable (Bool) -> Void) {
        for line in Self.describe(peer) { say(line) }
        say("")
        say("Pairing code:  \(Self.spaced(code))")
        say("")
        write("Do both screens show \(Self.spaced(code))? Type y or n: ")
        let shownAt = DispatchTime.now().uptimeNanoseconds
        lock.withLock { pending = respond; shownCode = code }
        startReading(shownAt: shownAt)
    }

    private func peerDecided(_ accepted: Bool) {
        let (waiting, code): (Bool, String?) = lock.withLock { peerAnswered = accepted; return (pending != nil, shownCode) }
        if accepted {
            say(waiting ? "\r\nThe other Mac confirmed the code." : "The other Mac confirmed the code.")
            // The question is asked again with the code, so the person still compares digits, not a promise.
            if waiting { write("Do both screens show \(code.map(Self.spaced) ?? "the same code")? Type y or n: ") }
        } else {
            let respond: (@Sendable (Bool) -> Void)? = lock.withLock { defer { pending = nil }; return pending }
            stopReading()
            say("\r\nThe other Mac did not confirm the code. Nothing was paired.")
            _ = respond
        }
    }

    /// Answers once: the first `y` or `n` after the dwell. Everything else,
    /// and a whole bracketed paste, is ignored.
    private func startReading(shownAt: UInt64) {
        var mode = termios()
        if tcgetattr(input, &mode) == 0 {
            lock.withLock { if savedMode == nil { savedMode = mode } }
            var raw = mode
            raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
            withUnsafeMutablePointer(to: &raw.c_cc) {
                $0.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { $0[Int(VMIN)] = 1; $0[Int(VTIME)] = 0 }
            }
            _ = tcsetattr(input, TCSANOW, &raw)
        }
        write("\u{1B}[?2004h")
        var ends: [Int32] = [-1, -1]
        guard pipe(&ends) == 0 else { return }
        lock.withLock { readerWake = ends }
        let descriptor = input, wake = ends[0]
        Thread.detachNewThread { [weak self] in
            var pasting = false
            var buffer = [UInt8](repeating: 0, count: 256)
            var carry = [UInt8]()
            loop: while true {
                var fds = [pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0), pollfd(fd: wake, events: Int16(POLLIN), revents: 0)]
                guard poll(&fds, 2, -1) > 0 else { if errno == EINTR { continue }; break }
                if fds[1].revents != 0 { break }
                let count = read(descriptor, &buffer, buffer.count)
                if count <= 0 { if count < 0, errno == EINTR { continue }; break }
                carry += buffer.prefix(count)
                while !carry.isEmpty {
                    if pasting {
                        guard let end = Self.find([0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E], in: carry) else { carry = Array(carry.suffix(5)); break }
                        carry.removeFirst(end + 6); pasting = false; continue
                    }
                    if let start = Self.find([0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E], in: carry), start == 0 {
                        carry.removeFirst(6); pasting = true; continue
                    }
                    if carry[0] == 0x1B {
                        if carry.count < 6 && [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E].starts(with: carry) { break }
                        carry.removeFirst(); continue
                    }
                    let byte = carry.removeFirst()
                    let dwell = UInt64(Self.dwellMilliseconds) * 1_000_000
                    guard DispatchTime.now().uptimeNanoseconds - shownAt >= dwell else { continue }
                    switch byte {
                    case UInt8(ascii: "y"), UInt8(ascii: "Y"): self?.answer(true); break loop
                    case UInt8(ascii: "n"), UInt8(ascii: "N"): self?.answer(false); break loop
                    case 0x03, 0x04: self?.answer(false); break loop
                    default: continue
                    }
                }
            }
        }
    }

    private func answer(_ accept: Bool) {
        let respond: (@Sendable (Bool) -> Void)? = lock.withLock { defer { pending = nil }; return pending }
        guard let respond else { return }
        restoreMode()
        say(accept ? "y" : "n")
        if accept {
            let peer = lock.withLock { peerAnswered }
            say(peer == true ? "Both Macs confirmed." : "Confirmed here. Waiting for the other Mac…")
        } else {
            say("Not confirmed. Nothing was paired.")
        }
        respond(accept)
    }

    private func stopReading() {
        let wake: Int32 = lock.withLock { readerWake[1] }
        if wake >= 0 { var byte: UInt8 = 1; _ = Darwin.write(wake, &byte, 1) }
        restoreMode()
    }

    public func restoreMode() {
        let mode: termios? = lock.withLock { defer { savedMode = nil }; return savedMode }
        guard var mode else { return }
        write("\u{1B}[?2004l")
        _ = tcsetattr(input, TCSANOW, &mode)
    }

    static func find(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard haystack.count >= needle.count else { return nil }
        for index in 0...(haystack.count - needle.count) where Array(haystack[index..<(index + needle.count)]) == needle { return index }
        return nil
    }

    /// The closing lines for a run's result.
    public static func summary(_ result: Swift.Result<ClusterLinkPairing.Result, ClusterPairingError>) -> [String] {
        switch result {
        case .success(let paired):
            let record = paired.record
            return ["Paired. This Mac pins the other Mac's Secure Enclave key \(record.peerPin.prefix(16))…",
                    "Roster \(record.clusterID), generation \(record.roster.generation), sha256 \(record.rosterSHA256.prefix(16))…, signed by both Macs.",
                    "Link key for the link control channel: epoch \(record.link.linkEpoch.prefix(8))…, edge \(record.link.edgeID.prefix(8))…",
                    "Stored in \(paired.store.path) (owner-only files). No SSH was used."]
        case .failure(let error):
            return ["Not paired: \(error). Nothing was stored."]
        }
    }
}
