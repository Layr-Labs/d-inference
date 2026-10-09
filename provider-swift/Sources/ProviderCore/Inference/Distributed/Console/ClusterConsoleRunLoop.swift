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

    public static func run(input: Int32, output: Int32, configuration: Configuration,
                           operations: ClusterConsoleOperations) throws -> ClusterConsoleExit {
        let terminal = try ClusterConsoleTerminal(input: input, output: output)
        var loop = try Loop(terminal: terminal, input: input, configuration: configuration, operations: operations)
        defer { loop.close() }
        try terminal.enter()
        defer { terminal.leave() }
        return try loop.run()
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
        var drawn: ClusterConsoleFrame?

        init(terminal: ClusterConsoleTerminal, input: Int32, configuration: Configuration,
             operations: ClusterConsoleOperations) throws {
            self.terminal = terminal; self.input = input
            self.configuration = configuration; self.operations = operations
            mailbox = try ClusterConsoleMailbox()
            signals = configuration.handlesSignals ? ClusterConsoleSignals(mailbox: mailbox) : nil
            state = ClusterConsoleState(size: terminal.size() ?? .init(columns: 80, rows: 24), options: configuration.options)
        }

        func close() {
            signals?.close()
            mailbox.close()
        }

        mutating func run() throws -> ClusterConsoleExit {
            perform(state.begin())
            try draw()
            var nextPoll = DispatchTime.now().uptimeNanoseconds + UInt64(configuration.pollMilliseconds) * 1_000_000
            var escapeDeadline: UInt64?
            while true {
                if let exit = state.exit { return exit }
                let now = DispatchTime.now().uptimeNanoseconds
                var wait = nextPoll > now ? Int((nextPoll - now) / 1_000_000) + 1 : 0
                if let escapeDeadline { wait = min(wait, escapeDeadline > now ? Int((escapeDeadline - now) / 1_000_000) + 1 : 0) }
                var descriptors = [pollfd(fd: input, events: Int16(POLLIN), revents: 0),
                                   pollfd(fd: mailbox.readEnd, events: Int16(POLLIN), revents: 0)]
                let ready = Darwin.poll(&descriptors, 2, Int32(clamping: wait))
                if ready < 0 {
                    if errno == EINTR { continue }
                    throw ClusterConsoleTerminal.Failure.cannotConfigure(errno)
                }
                if descriptors[0].revents != 0 {
                    for event in readKeys() { handle(event) }
                    // An unfinished sequence gets its allowance from the last byte that arrived.
                    escapeDeadline = decoder.hasPending
                        ? DispatchTime.now().uptimeNanoseconds + UInt64(configuration.escapeMilliseconds) * 1_000_000 : nil
                } else if let deadline = escapeDeadline, DispatchTime.now().uptimeNanoseconds >= deadline {
                    // Nothing followed the escape byte within its allowance.
                    escapeDeadline = nil
                    for key in decoder.flush() { handle(.key(key)) }
                }
                if descriptors[1].revents != 0 {
                    for item in mailbox.take() {
                        switch item {
                        case .event(let event): handle(event)
                        case .windowChanged: if let size = terminal.size() { handle(.resized(size)) }
                        }
                    }
                }
                if DispatchTime.now().uptimeNanoseconds >= nextPoll {
                    nextPoll = DispatchTime.now().uptimeNanoseconds + UInt64(configuration.pollMilliseconds) * 1_000_000
                    handle(.tick)
                }
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
            perform(state.handle(event, at: configuration.clock()))
        }

        private mutating func draw() throws {
            let frame = ClusterConsoleRenderer.frame(state)
            state.fit(to: frame)
            guard frame != drawn else { return }
            try terminal.write(frame.terminalBytes(color: configuration.color, rows: state.size.rows))
            drawn = frame
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
                    work.async {
                        mailbox.post(.actionFinished(.fixLink, dryRun ? operations.previewFixLink(device) : operations.fixLink(device)))
                    }
                case .recoverJournal:
                    work.async { mailbox.post(.actionFinished(.recoverJournal, operations.recoverJournal())) }
                case .approveSetup:
                    guard let candidate = configuration.candidate else {
                        mailbox.post(.actionFinished(.approveSetup, .init(succeeded: false, lines: ["No setup was passed in to approve."])))
                        continue
                    }
                    work.async { mailbox.post(.actionFinished(.approveSetup, operations.approveSetup(candidate))) }
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
                        self.handle(.session(.launched(processIdentifier: handle.processIdentifier)))
                    } catch {
                        self.handle(.session(.launchFailed(ClusterConsoleText.bounded(error))))
                    }
                case .interruptSession:
                    session?.interrupt()
                }
            }
        }
    }
}

extension ClusterConsoleState {
    /// Records what the last frame could show, so scrolling stops at its end.
    mutating func fit(to frame: ClusterConsoleFrame) {
        maximumScroll = frame.maximumScroll
        bodyRows = max(frame.bodyRows, 1)
        scroll = min(max(scroll, 0), maximumScroll)
    }
}
