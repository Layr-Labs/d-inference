import Foundation
import Darwin

/// Runs the console on a terminal: reads keys, hands every event to the
/// reducer, does the work it asks for off this thread, and redraws. Blocking;
/// it returns when the reducer sets an exit, and it restores the terminal on
/// every way out, a thrown error included.
public enum ClusterConsoleRunLoop {
    public struct Configuration: Sendable {
        public var options: ClusterConsoleState.Options
        /// The setup the approve action saves, when one was passed in.
        public var candidate: ClusterConsoleCandidate?
        public var color: Bool
        public var darkbloomVersion: String
        /// How often a probe that is being waited on is run again.
        public var pollMilliseconds: Int
        /// How long a lone escape byte is held before it is the Escape key.
        public var escapeMilliseconds: Int
        /// How long a paste may go without a byte before its end is taken as lost.
        public var pasteMilliseconds: Int = 1_000
        /// False only where the caller owns the process's signals itself.
        public var handlesSignals: Bool
        /// Stamps activity entries; the current UTC time unless a check supplies its own.
        public var clock: @Sendable () -> String

        public init(options: ClusterConsoleState.Options = .init(), candidate: ClusterConsoleCandidate? = nil,
                    color: Bool = true, darkbloomVersion: String,
                    pollMilliseconds: Int = ClusterLinkWatch.pollIntervalSeconds * 1000, escapeMilliseconds: Int = 50,
                    handlesSignals: Bool = true,
                    clock: (@Sendable () -> String)? = nil) {
            self.options = options; self.candidate = candidate; self.color = color
            self.darkbloomVersion = darkbloomVersion; self.pollMilliseconds = pollMilliseconds
            self.escapeMilliseconds = escapeMilliseconds; self.handlesSignals = handlesSignals
            self.clock = clock ?? { ClusterConsoleText.timestamp() }
        }
    }

    /// The screen stopped on an error. A session it had started was asked to
    /// stop on the way out, and says so.
    public struct Failure: Error, CustomStringConvertible {
        public let underlying: Error
        /// The session process that was asked to stop, if one was running.
        public let interruptedSession: Int32?

        public var description: String {
            let reason = ClusterConsoleText.bounded(underlying)
            guard let interruptedSession else { return reason }
            return reason + " The session this screen started (process \(interruptedSession)) was asked to stop and is finishing by itself; `darkbloom cluster status` shows it."
        }
    }

    public static func run(input: Int32, output: Int32, configuration: Configuration,
                           operations: ClusterConsoleOperations) throws -> ClusterConsoleExit {
        let terminal = try ClusterConsoleTerminal(input: input, output: output)
        var loop = try Loop(terminal: terminal, input: input, configuration: configuration, operations: operations)
        defer { loop.close() }
        // Registered before entering, so a failure while entering is undone too.
        defer { terminal.leave() }
        try terminal.enter()
        do { return try loop.run() } catch {
            throw Failure(underlying: error, interruptedSession: loop.interruptRunningSession())
        }
    }

    private struct Loop {
        let terminal: ClusterConsoleTerminal
        let input: Int32
        let configuration: Configuration
        let operations: ClusterConsoleOperations
        let mailbox: ClusterConsoleMailbox
        let signals: ClusterConsoleSignals?
        let work = DispatchQueue(label: "darkbloom.cluster-console.work", attributes: .concurrent)
        var state: ClusterConsoleState
        var decoder = ClusterConsoleKeyDecoder()
        var session: (any ClusterConsoleSessionHandle)?
        /// The same session while it has not ended, for the forced way out.
        let active = ClusterConsoleSessionSlot()
        /// Set when the loop has ended by itself, so the forced way out stands down.
        let finished = ClusterConsoleFlag()
        var drawn: ClusterConsoleFrame?

        init(terminal: ClusterConsoleTerminal, input: Int32, configuration: Configuration,
             operations: ClusterConsoleOperations) throws {
            self.terminal = terminal; self.input = input
            self.configuration = configuration; self.operations = operations
            mailbox = try ClusterConsoleMailbox()
            let restore = terminal.restore, active = self.active, finished = self.finished
            signals = configuration.handlesSignals ? ClusterConsoleSignals(mailbox: mailbox) { number in
                // A second request to end. The loop is first given the time
                // an orderly end takes; if it has not ended by then it is
                // stuck, most likely on a terminal that stopped reading. A
                // session this screen started is asked to stop unless it was
                // asked already, the screen is left if the terminal takes
                // that without being waited on, the mode goes back at once,
                // and the process ends.
                for _ in 0..<(Self.forcedExitGraceMilliseconds / 20) {
                    if finished.isSet { return }
                    usleep(20_000)
                }
                guard !finished.isSet else { return }
                active.interruptOnce()
                restore.leaveScreenIfWritable()
                restore.now()
                Darwin._exit(128 + number)
            } : nil
            state = ClusterConsoleState(size: terminal.size() ?? .init(columns: 80, rows: 24), options: configuration.options)
        }

        /// Longer than an orderly end takes: one write allowance and the leave.
        static let forcedExitGraceMilliseconds = 2_000

        func close() {
            finished.set()
            signals?.close()
            mailbox.close()
        }

        /// For the one way out the reducer does not see: a thrown error. A
        /// session that is running is asked to stop; one that was already
        /// asked is not asked twice. Either way it is named.
        func interruptRunningSession() -> Int32? {
            switch state.session {
            case .running(let identifier):
                active.interruptOnce()
                return identifier
            case .stopping(let identifier): return identifier
            case .none, .launching, .ended: return nil
            }
        }

        mutating func run() throws -> ClusterConsoleExit {
            perform(state.begin())
            try draw()
            var nextPoll = DispatchTime.now().uptimeNanoseconds + UInt64(configuration.pollMilliseconds) * 1_000_000
            // When an unfinished key sequence, or a paste without its end, is given up on.
            var inputDeadline: UInt64?
            while true {
                if let exit = state.exit { return exit }
                let now = DispatchTime.now().uptimeNanoseconds
                var wait = nextPoll > now ? Int((nextPoll - now) / 1_000_000) + 1 : 0
                if let inputDeadline { wait = min(wait, inputDeadline > now ? Int((inputDeadline - now) / 1_000_000) + 1 : 0) }
                var descriptors = [pollfd(fd: input, events: Int16(POLLIN), revents: 0),
                                   pollfd(fd: mailbox.readEnd, events: Int16(POLLIN), revents: 0)]
                let ready = Darwin.poll(&descriptors, 2, Int32(clamping: wait))
                if ready < 0 {
                    if errno == EINTR { continue }
                    throw ClusterConsoleTerminal.Failure.cannotConfigure(errno)
                }
                if descriptors[0].revents != 0 {
                    for event in readKeys() { handle(event) }
                    // Each gets its allowance from the last byte that arrived.
                    let allowance = decoder.hasPending ? configuration.escapeMilliseconds
                        : decoder.isPasting ? configuration.pasteMilliseconds : nil
                    inputDeadline = allowance.map { DispatchTime.now().uptimeNanoseconds + UInt64($0) * 1_000_000 }
                } else if let deadline = inputDeadline, DispatchTime.now().uptimeNanoseconds >= deadline {
                    // Nothing followed the escape byte, or the paste's end, within its allowance.
                    inputDeadline = nil
                    for key in decoder.isPasting ? decoder.abandonPaste() : decoder.flush() { handle(.key(key)) }
                }
                if descriptors[1].revents != 0 {
                    for item in mailbox.take() {
                        switch item {
                        case .event(let event): handle(event)
                        case .windowChanged:
                            // The terminal may have redrawn or clipped what it showed: the next frame is written whole.
                            drawn = nil
                            if let size = terminal.size() { handle(.resized(size)) }
                        }
                    }
                }
                if DispatchTime.now().uptimeNanoseconds >= nextPoll {
                    nextPoll = DispatchTime.now().uptimeNanoseconds + UInt64(configuration.pollMilliseconds) * 1_000_000
                    handle(.tick)
                }
                // Once the screen is closing nothing more is drawn: the
                // terminal may be the thing that went away.
                if state.exit != nil { continue }
                try draw()
            }
        }

        private mutating func readKeys() -> [ClusterConsoleEvent] {
            var buffer = [UInt8](repeating: 0, count: 256)
            let count = Darwin.read(input, &buffer, buffer.count)
            if count > 0 { return decoder.feed(Array(buffer.prefix(count))).map(ClusterConsoleEvent.key) }
            if count < 0, errno == EINTR || errno == EAGAIN { return [] }
            return [.inputClosed]
        }

        private mutating func handle(_ event: ClusterConsoleEvent) {
            perform(state.handle(event, at: configuration.clock(), uptime: DispatchTime.now().uptimeNanoseconds))
            if !state.session.isActive { active.set(nil) }
        }

        /// Every key read together is handled before this runs, so a question
        /// opened by one of them is drawn before any later read can answer it.
        private mutating func draw() throws {
            let frame = ClusterConsoleRenderer.frame(state)
            if frame != drawn {
                try terminal.write(frame.terminalBytes(color: configuration.color, rows: state.size.rows))
                drawn = frame
            }
            state.drew(frame, uptime: DispatchTime.now().uptimeNanoseconds)
        }

        /// Blocking operations run on the work queue and answer through the
        /// mailbox. Starting and interrupting the session are immediate.
        private mutating func perform(_ effects: [ClusterConsoleEffect]) {
            let operations = self.operations, mailbox = self.mailbox
            for effect in effects {
                switch effect {
                case .refresh:
                    work.async { mailbox.post(.snapshot(operations.snapshot())) }
                case .pollLink:
                    work.async { mailbox.post(.linkObserved(operations.inspectLink())) }
                case .pollSession:
                    work.async { mailbox.post(.sessionObserved(operations.observeSession())) }
                case .fixLink(let device, let dryRun):
                    let fix = ClusterConsoleLinkFix(device: device, temporary: configuration.options.temporary, dryRun: dryRun)
                    work.async { mailbox.post(.actionFinished(.fixLink, operations.fixLink(fix))) }
                case .recoverJournal:
                    work.async { mailbox.post(.actionFinished(.recoverJournal, operations.recoverJournal())) }
                case .approveSetup(let expectedSHA256):
                    guard let candidate = configuration.candidate else {
                        mailbox.post(.actionFinished(.approveSetup, .init(succeeded: false, lines: ["No setup was passed in to approve."])))
                        continue
                    }
                    work.async { mailbox.post(.actionFinished(.approveSetup, operations.approveSetup(candidate, expectedSHA256))) }
                case .exportDiagnostics:
                    guard let snapshot = state.snapshot else {
                        mailbox.post(.actionFinished(.exportDiagnostics, .init(succeeded: false, lines: ["Nothing has been observed to export."])))
                        continue
                    }
                    let input = ClusterDiagnosticExport.Input(snapshot: snapshot, activity: state.activity,
                        sessionState: String(describing: state.session), sessionOutput: state.sessionOutput,
                        darkbloomVersion: configuration.darkbloomVersion)
                    work.async { mailbox.post(.actionFinished(.exportDiagnostics, operations.exportDiagnostics(input))) }
                case .launchSession:
                    do {
                        let handle = try operations.launchSession { mailbox.post(.session($0)) }
                        session = handle
                        active.set(handle)
                        self.handle(.session(.launched(processIdentifier: handle.processIdentifier)))
                    } catch {
                        self.handle(.session(.launchFailed(ClusterConsoleText.bounded(error))))
                    }
                case .interruptSession:
                    active.interruptOnce()
                }
            }
        }
    }
}

/// The session a screen started, while it has not ended, where a thread other
/// than the run loop's can reach it. However many ways out ask, it is sent
/// its stop request once.
final class ClusterConsoleSessionSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var session: (any ClusterConsoleSessionHandle)?
    private var asked = false

    func set(_ session: (any ClusterConsoleSessionHandle)?) {
        lock.withLock {
            self.session = session
            asked = false
        }
    }

    /// Asks the session to stop if there is one and it was not asked before.
    /// True when this call asked.
    @discardableResult
    func interruptOnce() -> Bool {
        let session = lock.withLock { () -> (any ClusterConsoleSessionHandle)? in
            guard !asked, let session = self.session else { return nil }
            asked = true
            return session
        }
        session?.interrupt()
        return session != nil
    }
}

/// A flag one thread sets and another reads.
final class ClusterConsoleFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
