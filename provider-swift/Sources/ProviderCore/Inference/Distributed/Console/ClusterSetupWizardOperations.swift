import Foundation

/// Every operation the wizard runs, as blocking calls. The live set runs the
/// same functions the `darkbloom cluster` subcommands run; checks supply
/// their own so that no tool, prompt or process is started.
public struct ClusterSetupOperations: Sendable {
    /// Everything local, read again.
    public var snapshot: @Sendable () -> ClusterSetupSnapshot
    /// The other Mac's own report, over the pinned SSH route. With `adoptPlan`'s delivery to the
    /// other Mac's inbox, the only place the wizard itself reaches the other Mac: the SSH-free link
    /// control channel (S06) replaces these two closures, not the screens.
    public var reachPeer: @Sendable () -> ClusterSetupPeerResult
    /// The model folders and the planner's answer for each, from both Macs' readings.
    public var planModels: @Sendable (_ peer: ClusterSetupReport) -> ClusterSetupPlansResult
    /// `cluster link --fix`: its dry run, or the change behind one macOS prompt.
    public var fixLink: @Sendable (_ dryRun: Bool) -> ClusterSetupLinkFixResult
    /// Writes that the person saw the same code on both screens.
    public var recordConfirmation: @Sendable (_ code: String, _ clusterID: String?) -> ClusterConsoleActionResult
    /// Writes both setups for one model, saves this Mac's with `cluster configure`, and sends the other Mac its own.
    public var adoptPlan: @Sendable (_ folder: String, _ planKey: String, _ peer: ClusterSetupReport) -> ClusterConsoleActionResult
    /// `cluster configure` on the setup in the inbox, refused unless it is still the one shown.
    public var approveInbox: @Sendable (_ expectedSHA256: String) -> ClusterConsoleActionResult
    public var recordCheck: @Sendable (ClusterSetupRecord.CheckPass) -> ClusterConsoleActionResult
    /// The leader's status, with this Mac's memory and link beside it.
    public var observeSession: @Sendable () -> ClusterSetupLive
    /// Starts `darkbloom start --local --distributed` and reports its output and its end.
    public var launchSession: @Sendable (_ events: @escaping @Sendable (ClusterConsoleSessionEvent) -> Void) throws -> any ClusterConsoleSessionHandle
    /// One streamed request through the local serving API; returns when it has ended.
    public var sendPrompt: @Sendable (_ text: String, _ maxTokens: Int, _ events: @escaping @Sendable (ClusterSetupPromptEvent) -> Void) -> Void
    /// The pairing ceremony over the link (S17), the operation behind `darkbloom cluster pair`:
    /// listens (nil) or dials the address given, reports as it moves, and returns when it has ended.
    public var pairOverLink: @Sendable (_ connect: String?, _ events: @escaping @Sendable (ClusterSetupLinkPairingEvent) -> Void) -> Void = { _, events in
        events(.finished(succeeded: false, lines: ["Pairing over the link is not available in this build."]))
    }
    /// The person's answer to the ceremony's code, delivered to the running ceremony.
    public var answerLinkCode: @Sendable (_ accept: Bool) -> Void = { _ in }

    public init(snapshot: @escaping @Sendable () -> ClusterSetupSnapshot,
                reachPeer: @escaping @Sendable () -> ClusterSetupPeerResult,
                planModels: @escaping @Sendable (ClusterSetupReport) -> ClusterSetupPlansResult,
                fixLink: @escaping @Sendable (Bool) -> ClusterSetupLinkFixResult,
                recordConfirmation: @escaping @Sendable (String, String?) -> ClusterConsoleActionResult,
                adoptPlan: @escaping @Sendable (String, String, ClusterSetupReport) -> ClusterConsoleActionResult,
                approveInbox: @escaping @Sendable (String) -> ClusterConsoleActionResult,
                recordCheck: @escaping @Sendable (ClusterSetupRecord.CheckPass) -> ClusterConsoleActionResult,
                observeSession: @escaping @Sendable () -> ClusterSetupLive,
                launchSession: @escaping @Sendable (@escaping @Sendable (ClusterConsoleSessionEvent) -> Void) throws -> any ClusterConsoleSessionHandle,
                sendPrompt: @escaping @Sendable (String, Int, @escaping @Sendable (ClusterSetupPromptEvent) -> Void) -> Void) {
        self.snapshot = snapshot; self.reachPeer = reachPeer; self.planModels = planModels; self.fixLink = fixLink
        self.recordConfirmation = recordConfirmation; self.adoptPlan = adoptPlan; self.approveInbox = approveInbox
        self.recordCheck = recordCheck; self.observeSession = observeSession; self.launchSession = launchSession
        self.sendPrompt = sendPrompt
    }
}

/// Runs the wizard on a terminal: reads keys, hands every event to the
/// reducer, does the work it asks for off this thread, and redraws, ten times
/// a second while something moves. Blocking; it restores the terminal on
/// every way out.
public enum ClusterSetupRunLoop {
    public struct Configuration: Sendable {
        public var options: ClusterSetupState.Options
        public var color: Bool
        public var glyphs: ClusterSetupGlyphs
        /// How often the screen ticks while nothing moves.
        public var idleMilliseconds: Int
        /// How often it ticks while a spinner turns or a session runs.
        public var busyMilliseconds: Int
        public var escapeMilliseconds: Int
        public var pasteMilliseconds: Int = 1_000
        public var handlesSignals: Bool
        public var clock: @Sendable () -> String

        public init(options: ClusterSetupState.Options = .init(), color: Bool = true, glyphs: ClusterSetupGlyphs = .unicode,
                    idleMilliseconds: Int = 2_000, busyMilliseconds: Int = 100, escapeMilliseconds: Int = 50,
                    handlesSignals: Bool = true, clock: (@Sendable () -> String)? = nil) {
            self.options = options; self.color = color; self.glyphs = glyphs; self.idleMilliseconds = idleMilliseconds
            self.busyMilliseconds = busyMilliseconds; self.escapeMilliseconds = escapeMilliseconds
            self.handlesSignals = handlesSignals; self.clock = clock ?? { ClusterConsoleText.timestamp() }
        }
    }

    public static func run(input: Int32, output: Int32, configuration: Configuration,
                           operations: ClusterSetupOperations) throws -> ClusterConsoleExit {
        let terminal = try ClusterConsoleTerminal(input: input, output: output)
        var loop = try Loop(terminal: terminal, input: input, configuration: configuration, operations: operations)
        defer { loop.close() }
        defer { terminal.leave() }
        try terminal.enter()
        do { return try loop.run() } catch {
            throw ClusterConsoleRunLoop.Failure(underlying: error, interruptedSession: loop.interruptRunningSession())
        }
    }

    private struct Loop {
        let terminal: ClusterConsoleTerminal
        let input: Int32
        let configuration: Configuration
        let operations: ClusterSetupOperations
        let mailbox: ClusterScreenMailbox<ClusterSetupEvent>
        let signals: ClusterConsoleSignals?
        let work = DispatchQueue(label: "darkbloom.cluster-setup.work", attributes: .concurrent)
        var state: ClusterSetupState
        var decoder = ClusterConsoleKeyDecoder()
        let active = ClusterConsoleSessionSlot()
        let finished = ClusterConsoleFlag()
        var drawn: ClusterSetupFrame?

        init(terminal: ClusterConsoleTerminal, input: Int32, configuration: Configuration, operations: ClusterSetupOperations) throws {
            self.terminal = terminal; self.input = input; self.configuration = configuration; self.operations = operations
            let mailbox = try ClusterScreenMailbox<ClusterSetupEvent>()
            self.mailbox = mailbox
            let restore = terminal.restore, active = self.active, finished = self.finished
            signals = configuration.handlesSignals ? ClusterConsoleSignals(mailbox: mailbox, termination: { .terminationSignal($0) }) { number in
                // A second request to end: the loop had its chance and is stuck.
                for _ in 0..<100 {
                    if finished.isSet { return }
                    usleep(20_000)
                }
                guard !finished.isSet else { return }
                active.interruptOnce()
                restore.leaveScreenIfWritable()
                restore.now()
                Darwin._exit(128 + number)
            } : nil
            state = ClusterSetupState(size: terminal.size() ?? .init(columns: 80, rows: 24), options: configuration.options)
        }

        func close() {
            finished.set()
            signals?.close()
            mailbox.close()
        }

        func interruptRunningSession() -> Int32? {
            switch state.session {
            case .running(let identifier, _):
                active.interruptOnce()
                return identifier
            case .stopping(let identifier): return identifier
            case .none, .launching, .ended: return nil
            }
        }

        mutating func run() throws -> ClusterConsoleExit {
            perform(state.begin())
            try draw()
            var nextTick = DispatchTime.now().uptimeNanoseconds + interval()
            var inputDeadline: UInt64?
            while true {
                if let exit = state.exit { return exit }
                let now = DispatchTime.now().uptimeNanoseconds
                var wait = nextTick > now ? Int((nextTick - now) / 1_000_000) + 1 : 0
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
                    let allowance = decoder.hasPending ? configuration.escapeMilliseconds
                        : decoder.isPasting ? configuration.pasteMilliseconds : nil
                    inputDeadline = allowance.map { DispatchTime.now().uptimeNanoseconds + UInt64($0) * 1_000_000 }
                } else if let deadline = inputDeadline, DispatchTime.now().uptimeNanoseconds >= deadline {
                    inputDeadline = nil
                    for key in decoder.isPasting ? decoder.abandonPaste() : decoder.flush() { handle(.key(key)) }
                }
                if descriptors[1].revents != 0 {
                    for item in mailbox.take() {
                        switch item {
                        case .event(let event): handle(event)
                        case .windowChanged:
                            drawn = nil
                            if let size = terminal.size() { handle(.resized(size)) }
                        }
                    }
                }
                if DispatchTime.now().uptimeNanoseconds >= nextTick {
                    handle(.tick)
                    nextTick = DispatchTime.now().uptimeNanoseconds + interval()
                } else {
                    // Something started moving: tick sooner.
                    nextTick = min(nextTick, DispatchTime.now().uptimeNanoseconds + interval())
                }
                if state.exit != nil { continue }
                try draw()
            }
        }

        /// Fast while a spinner turns, a session runs or a reading is awaited.
        private func interval() -> UInt64 {
            UInt64(state.animating ? configuration.busyMilliseconds : configuration.idleMilliseconds) * 1_000_000
        }

        private mutating func readKeys() -> [ClusterSetupEvent] {
            var buffer = [UInt8](repeating: 0, count: 256)
            let count = Darwin.read(input, &buffer, buffer.count)
            if count > 0 { return decoder.feed(Array(buffer.prefix(count))).map(ClusterSetupEvent.key) }
            if count < 0, errno == EINTR || errno == EAGAIN { return [] }
            return [.inputClosed]
        }

        private mutating func handle(_ event: ClusterSetupEvent) {
            perform(state.handle(event, at: configuration.clock(), uptime: DispatchTime.now().uptimeNanoseconds))
            if !state.session.isActive { active.set(nil) }
        }

        private mutating func draw() throws {
            let frame = ClusterSetupScreen.frame(state, glyphs: configuration.glyphs)
            if frame != drawn {
                try terminal.write(frame.terminalBytes(color: configuration.color, rows: state.size.rows))
                drawn = frame
            }
            state.drew(maximumScroll: frame.maximumScroll, bodyRows: frame.bodyRows, question: frame.question,
                uptime: DispatchTime.now().uptimeNanoseconds)
        }

        private mutating func perform(_ effects: [ClusterSetupEffect]) {
            let operations = self.operations, mailbox = self.mailbox
            for effect in effects {
                switch effect {
                case .refresh:
                    work.async { mailbox.post(.snapshot(operations.snapshot())) }
                case .reachPeer:
                    work.async { mailbox.post(.peer(operations.reachPeer())) }
                case .planModels:
                    guard let peer = state.peerReport else {
                        mailbox.post(.plans(.failed("The other Mac has not answered yet.")))
                        continue
                    }
                    work.async { mailbox.post(.plans(operations.planModels(peer))) }
                case .linkFix(let dryRun):
                    work.async { mailbox.post(.linkFix(operations.fixLink(dryRun))) }
                case .recordConfirmation(let code, let cluster):
                    work.async { mailbox.post(.actionFinished(.recordConfirmation, operations.recordConfirmation(code, cluster))) }
                case .adoptPlan(let folder, let key):
                    guard let peer = state.peerReport else {
                        mailbox.post(.actionFinished(.adoptPlan, .init(succeeded: false, lines: ["The other Mac has not answered, so its setup cannot be sent."])))
                        continue
                    }
                    work.async { mailbox.post(.actionFinished(.adoptPlan, operations.adoptPlan(folder, key, peer))) }
                case .approveInbox(let expected):
                    work.async { mailbox.post(.actionFinished(.approveInbox, operations.approveInbox(expected))) }
                case .recordCheck(let pass):
                    work.async { mailbox.post(.actionFinished(.recordCheck, operations.recordCheck(pass))) }
                case .pollSession:
                    work.async { mailbox.post(.sessionObserved(operations.observeSession())) }
                case .sendPrompt(let text, let maxTokens):
                    work.async { operations.sendPrompt(text, maxTokens) { mailbox.post(.prompt($0)) } }
                case .launchSession:
                    do {
                        let handle = try operations.launchSession { mailbox.post(.session($0)) }
                        active.set(handle)
                        self.handle(.session(.launched(processIdentifier: handle.processIdentifier)))
                    } catch {
                        self.handle(.session(.launchFailed(ClusterConsoleText.bounded(error))))
                    }
                case .interruptSession:
                    active.interruptOnce()
                case .pairOverLink(let connect):
                    work.async { operations.pairOverLink(connect) { mailbox.post(.linkPairing($0)) } }
                case .answerLinkCode(let accept):
                    work.async { operations.answerLinkCode(accept) }
                }
            }
        }
    }
}
