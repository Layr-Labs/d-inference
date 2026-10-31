import Darwin
import Foundation
import DarkbloomClusterProtocol
import DarkbloomClusterProcess
import DarkbloomClusterSecurity

/// Installed darkbloom's configured worker-owner entry calls this service. No
/// executable, model path, environment or bootstrap address is accepted on wire.
public enum ClusterWorkerOwnerService {
    /// This factory must return an UNLAUNCHED direct child. With a bootstrap
    /// profile it must require that profile's attachment. Without one the child
    /// uses its native bootstrap and the caller must say so wherever it reports
    /// the session; the two are never substituted for each other. The child's
    /// own hard deadline must also cover owner death; this supervisor cannot
    /// run after death.
    ///
    /// Journal rule: the device journal is written immediately before the child
    /// is launched and cleared by this owner once it has itself observed that
    /// child's exit (or that no child was created). A release acknowledgement
    /// from the leader is still exchanged when the connection is alive, but its
    /// loss does not leave a journal behind. The journal outlives this process
    /// only when the child may still be running: this owner died first, or the
    /// child outlived its own deadline and every signal.
    public typealias NativeFactory = @Sendable (ClusterOwnerBinding, UInt64) throws -> ClusterWorkerProcess
    public typealias BindingFactory = @Sendable (UUID, UUID, UUID) throws -> ClusterOwnerBinding

    public typealias AttachedNativeFactory = @Sendable (ClusterOwnerBinding, UInt64, ClusterOwnerBootstrapAttachment?) throws -> ClusterWorkerProcess
    /// The same with the worker's data-plane credential line from the open
    /// frame (S16), already checked against this owner's epoch and rank; nil
    /// when the leader sent none. The factory writes it as the worker's first
    /// input line (`ClusterWorkerLaunch.initialInput`).
    public typealias KeyedNativeFactory = @Sendable (ClusterOwnerBinding, UInt64, ClusterOwnerBootstrapAttachment?, Data?) throws -> ClusterWorkerProcess
    /// There is no configured owner lifetime. The leader opens with a first
    /// rank-lease grant of at most `ClusterWorkerLease.maximumNanoseconds` and
    /// renews it with `renew` frames while it keeps the session; the native
    /// child's own lease is renewed by its supervisor until this owner fences
    /// it. A leader that stops renewing (stopped, died, lost its link) leaves
    /// this owner to fence the child at the lease's end.
    public static func serve(input: Int32, output: Int32, clusterID: String, leaseDirectory: URL,
                             binding: BindingFactory, native: NativeFactory) throws {
        try serveConfigured(input: input, output: output, clusterID: clusterID, leaseDirectory: leaseDirectory,
            bootstrapProfile: nil, binding: binding,
            native: { binding, deadline, _ in try native(binding, deadline) })
    }
    public static func serveConfigured(input: Int32, output: Int32, clusterID: String, leaseDirectory: URL,
                             bootstrapProfile: ClusterOwnerBootstrapProfile?,
                             authorizeNativeStart: (@Sendable (ClusterNativeAuthorizationStart) throws -> Void)? = nil,
                             lanes: Int = 1,
                             binding: BindingFactory, native: AttachedNativeFactory) throws {
        try serveKeyed(input: input, output: output, clusterID: clusterID, leaseDirectory: leaseDirectory,
            bootstrapProfile: bootstrapProfile, authorizeNativeStart: authorizeNativeStart, lanes: lanes, binding: binding,
            native: { binding, deadline, attachment, trust in
                guard trust == nil else { throw OwnerWire.invalid("This owner launches no keyed data plane") }
                return try native(binding, deadline, attachment)
            })
    }

    /// `lanes`: requests the worker serves at once (the plan's batch lanes,
    /// which the worker's own load agreement binds); one by default.
    public static func serveKeyed(input: Int32, output: Int32, clusterID: String, leaseDirectory: URL,
                             bootstrapProfile: ClusterOwnerBootstrapProfile?,
                             authorizeNativeStart: (@Sendable (ClusterNativeAuthorizationStart) throws -> Void)? = nil,
                             lanes: Int = 1,
                             binding: BindingFactory, native: KeyedNativeFactory) throws {
        let pipe = try ClusterOwnerPipe(input: input, output: output, readingCommands: true)
        // The force-cancel hook is routed before any child exists; a failure
        // to route it is noted on standard error and never stops the owner.
        if let problem = ClusterOwnerForceCancel.route() {
            FileHandle.standardError.write(Data("darkbloom-force-cancel-v1 role=owner routed=no reason=\(problem)\n".utf8))
        }
        let begin = DispatchTime.now().uptimeNanoseconds
        guard let bytes = try pipe.read(until: begin + 5_000_000_000) else { throw ClusterWorkerOwnerErrorProxy.deadline }
        let open = try OwnerWire.decode(bytes, commandStream: true)
        guard open.kind == "open", open.sequence == 0, open.clusterID == clusterID, open.bootstrapProfile == bootstrapProfile, let duration = open.remaining,
              duration <= ClusterWorkerLease.maximumNanoseconds else {
            throw OwnerWire.invalid("Owner open differs from installed configuration or exceeds one lease grant")
        }
        // Opt-in is configured locally. Wire start bytes alone never enable it.
        let nativeStart: ClusterNativeAuthorizationStart?
        if bootstrapProfile?.carriesNativeStart == true {
            guard let authorizeNativeStart, let bytes = open.nativeStart else { throw OwnerWire.invalid("Native authorization is not configured") }
            let value = try ClusterNativeAuthorizationStart(encoded: bytes)
            guard value.common.epoch == open.epoch, value.leaseID == open.lease,
                  bootstrapProfile != .nativeKeyPrelude || (open.nativeLocalDeadline ?? 0) > DispatchTime.now().uptimeNanoseconds else {
                throw OwnerWire.invalid("Native committed start identity/deadline differs")
            }
            try authorizeNativeStart(value)
            nativeStart = value
        } else { guard authorizeNativeStart == nil else { throw OwnerWire.invalid("Ambiguous native authorization mode") }; nativeStart = nil }
        let ownerBinding = try binding(open.epoch, open.lease, nativeStart?.ownerIncarnation ?? UUID())
        guard ownerBinding.route.clusterID == clusterID, ownerBinding.route.membershipEpoch == open.epoch,
              ownerBinding.route.leaseID == open.lease else { throw OwnerWire.invalid("Configured owner binding differs") }
        if let line = open.dataPlaneTrust {
            guard let trust = try? ClusterWorkerCodec.decodeDataPlaneTrust(line), trust.rank == ownerBinding.rank,
                  trust.membershipEpoch == ownerBinding.identity.membershipEpoch else {
                throw OwnerWire.invalid("Data-plane credential belongs to another rank or epoch")
            }
        }
        if let nativeStart {
            guard ownerBinding.rank == nativeStart.rank,
                  ownerBinding.executionPlanSHA256 == nativeStart.common.planSHA256.map({ String(format: "%02x", $0) }).joined(),
                  ownerBinding.identity.artifactSHA256 == nativeStart.common.artifactSHA256.map({ String(format: "%02x", $0) }).joined() else { throw OwnerWire.invalid("Configured native plan differs") }
        }
        let lease = try ClusterDeviceLease(directoryURL: leaseDirectory)
        let localNow = DispatchTime.now().uptimeNanoseconds
        var remaining = duration
        if let end = open.nativeLocalDeadline {
            guard end > localNow else { throw OwnerWire.invalid("Native local lifetime expired before lease admission") }
            remaining = min(remaining, end - localNow)
        }
        var state = try ClusterOwnerLeaseState(binding: ownerBinding, now: localNow,
            remainingLifetimeNanoseconds: remaining, lanes: lanes)
        let launchID = nativeStart?.launchID ?? UUID()
        try state.beginNativeLaunch(launchID, now: DispatchTime.now().uptimeNanoseconds)
        let attachment = try bootstrapProfile.map { try ClusterOwnerBootstrapAttachment(profile: $0,
            deadline: min(state.lifetimeDeadlineUptimeNanoseconds, DispatchTime.now().uptimeNanoseconds + 30_000_000_000), nativeStart: nativeStart) }
        let context = ServiceContext(pipe: pipe, state: state, launchID: launchID, attachment: attachment)
        // Hello establishes a fresh incarnation before any native readiness.
        try context.publish(kind: "hello", launchID: launchID)
        let child: ClusterWorkerProcess
        do {
            child = try native(ownerBinding, state.lifetimeDeadlineUptimeNanoseconds, attachment, open.dataPlaneTrust)
            context.child = child
            guard child.launchedProcessIdentifier == nil, child.termination == nil, !child.nativeCleanupObserved, child.expectedIdentity == ownerBinding.identity, child.rank == ownerBinding.rank,
                  child.expectedProfile == ownerBinding.profile, child.executionPlanSHA256 == ownerBinding.executionPlanSHA256,
                  child.localLifetimeDeadlineUptimeNanoseconds <= state.lifetimeDeadlineUptimeNanoseconds else {
                throw OwnerWire.invalid("Native factory binding differs")
            }
        } catch {
            // Nothing was launched and nothing was recorded: no journal exists.
            try? context.recordTerminal(.launchFailed)
            try? context.publishTerminal()
            throw error
        }
        context.supervisionDeadline = Self.supervisionDeadline(child)
        // The owner-side force-cancel hook: SIGUSR1 fences this child.
        ClusterOwnerForceCancel.register(child)
        defer { ClusterOwnerForceCancel.register(nil) }
        // The journal names this launch immediately before it can exist.
        do { try lease.record(binding: ownerBinding, launchID: launchID) }
        catch {
            // A failed journal write is never retried and no child is launched.
            try? context.recordTerminal(.launchFailed)
            try? context.publishTerminal()
            throw error
        }
        do {
            try child.launch()
            try context.lock.withLock { try context.state.observeNativeStarted(launchID) }
        } catch {
            // Run failure is independently exposed by Process. No PID-absence inference.
            if child.launchedProcessIdentifier != nil {
                try? context.lock.withLock { if !context.state.childStarted { try context.state.observeNativeStarted(launchID) } }
                child.requestNativeCleanup()
                if child.waitForExit(until: child.retirementDeadlineUptimeNanoseconds), let terminal = child.termination {
                    try context.recordTerminal(terminal)
                    try lease.resolve() // This owner observed the exit of the only child it launched.
                }
            } else {
                try context.recordTerminal(.launchFailed)
                try lease.resolve() // No child was launched.
            }
            try? context.publishTerminal()
            throw error
        }
        if let attachment {
            context.attachmentTasks.enter()
            DispatchQueue(label: "darkbloom.owner.bootstrap-attachment").async {
                defer { context.attachmentTasks.leave() }
                do { try attachment.run(child: child, binding: ownerBinding) { sequence, bytes in
                    try context.publish(kind: "bootstrapRound", bootstrapSequence: sequence, bootstrapBytes: bytes)
                } } catch { context.lock.withLock { context.state.disconnect() }; child.requestNativeCleanup() }
            }
        }
        let relay = DispatchGroup(); relay.enter()
        DispatchQueue(label: "darkbloom.owner.native-events").async {
            defer { relay.leave() }
            context.relayNative()
        }
        var released = false
        do {
            while !released {
                let now = DispatchTime.now().uptimeNanoseconds
                // The child's lease, and so its retirement ceiling, moves with
                // each renewal its supervisor queues.
                context.lock.withLock { context.supervisionDeadline = Self.supervisionDeadline(child) }
                // At the lease's end the state requests a fence; the child ends
                // itself there. This loop keeps serving the terminal and the
                // release handshake until the child's retirement ceiling.
                try context.observeTime()
                if now >= context.supervisionDeadline { throw ClusterWorkerOwnerErrorProxy.deadline }
                guard let line = try pipe.read(until: min(context.supervisionDeadline, now + 100_000_000)) else { continue }
                // One pool per frame: this loop never returns to a run loop (see ClusterAutorelease).
                let frame = try ClusterAutorelease.drained { () throws -> OwnerWire in
                    let frame = try OwnerWire.decode(line, commandStream: true)
                    try context.accept(frame)
                    return frame
                }
                if frame.kind == "release" {
                    // Terminal was emitted only after actual native cleanup. The
                    // ACK proves this connection received it, not future recovery.
                    relay.wait()
                    guard context.lock.withLock({ context.state.canReleaseDeviceLease && context.terminalWriteSucceeded }) else { throw OwnerWire.invalid("Owner still holds native resources") }
                    try lease.resolve()
                    try context.lock.withLock { try context.state.observeDeviceLeaseReleased() }
                    try context.publish(kind: "released")
                    released = true
                }
            }
        } catch {
            context.lock.withLock { context.state.disconnect() }
            attachment?.cancel()
            // S24: why this owner stopped serving, for the member log and the
            // leader's incident (the owner's own words; never request content).
            ServiceContext.writeDiagnostics("darkbloom-owner-fail-v1 rank=\(child.rank) error=\(String(String(describing: error).prefix(400)))\n")
            // The leader is gone or wrong. The child still ends itself, and its
            // exit, which this owner observes directly, is what frees the device.
            child.requestNativeCleanup()
            guard child.waitForExit(until: child.retirementDeadlineUptimeNanoseconds) else {
                throw OwnerWire.invalid("Native child \(child.launchedProcessIdentifier.map(String.init) ?? "unknown") outlived its own deadline and every signal; its device journal is retained (\(error))")
            }
            relay.wait()
            let resolvable = context.lock.withLock { context.state.canReleaseDeviceLease }
            if resolvable {
                try lease.resolve()
                try context.lock.withLock { try context.state.observeDeviceLeaseReleased() }
            }
            throw error
        }
    }

    /// Latest moment this owner still reads and writes its connection: the
    /// child's retirement ceiling plus time for the release handshake.
    static let handshakeAllowanceNanoseconds: UInt64 = 5_000_000_000
    static func supervisionDeadline(_ child: ClusterWorkerProcess) -> UInt64 {
        let value = child.retirementDeadlineUptimeNanoseconds.addingReportingOverflow(handshakeAllowanceNanoseconds)
        return value.overflow ? UInt64.max : value.partialValue
    }
}

private final class ServiceContext: @unchecked Sendable {
    let pipe: ClusterOwnerPipe
    let lock = NSLock()
    let writeLock = NSLock()
    let attachmentTasks = DispatchGroup()
    var state: ClusterOwnerLeaseState
    let launchID: UUID
    var child: ClusterWorkerProcess?
    var nextIncoming: UInt64 = 1
    var nextOutgoing: UInt64 = 0
    var nextWorkerCommand: UInt64 = 0
    var terminalPublished = false
    var terminalWriteSucceeded = false
    /// Each reserving request's admission deadline, by ID.
    var admissionDeadlines: [UUID: UInt64] = [:]
    var session: OwnerWorkerSession
    /// The rank lease's current deadline: the leader's renewals move it.
    private let leaseLock = NSLock()
    private var leaseDeadline: UInt64
    var deadline: UInt64 { leaseLock.withLock { leaseDeadline } }
    /// Set once the child exists; until then the owner's lease bounds IO.
    var supervisionDeadline: UInt64
    let binding: ClusterOwnerBinding
    let attachment: ClusterOwnerBootstrapAttachment?
    init(pipe: ClusterOwnerPipe, state: ClusterOwnerLeaseState, launchID: UUID, attachment: ClusterOwnerBootstrapAttachment?) {
        self.pipe = pipe; self.state = state; self.launchID = launchID
        leaseDeadline = state.lifetimeDeadlineUptimeNanoseconds; supervisionDeadline = state.lifetimeDeadlineUptimeNanoseconds
        binding = state.binding; self.attachment = attachment
        // Binding was validated by its initializer; the lane count by the state's.
        let b = state.binding
        session = state.lanes == 1
            ? .single(try! ClusterWorkerSession(identity: b.identity, rank: b.rank, profile: b.profile,
                executionPlanSHA256: b.executionPlanSHA256))
            : .lanes(try! ClusterWorkerLaneSession(identity: b.identity, rank: b.rank, profile: b.profile,
                executionPlanSHA256: b.executionPlanSHA256, lanes: state.lanes))
    }
    func publish(kind: String, payload: Data? = nil, launchID: UUID? = nil, termination: ClusterOwnerTermination? = nil, bootstrapSequence: UInt64? = nil, bootstrapBytes: Data? = nil) throws {
        try writeLock.withLock {
            let route = binding.route
            let frame = OwnerWire(kind: kind, epoch: route.membershipEpoch, lease: route.leaseID,
                incarnation: route.ownerIncarnation, sequence: nextOutgoing, launchID: launchID,
                payload: payload, termination: termination, bootstrapProfile: kind == "hello" ? attachment?.profile : nil,
                bootstrapSequence: bootstrapSequence, bootstrapBytes: bootstrapBytes)
            try pipe.write(frame.encoded(commandStream: false), until: min(supervisionDeadline, DispatchTime.now().uptimeNanoseconds + 500_000_000))
            nextOutgoing += 1
        }
    }
    func observeTime() throws {
        let fence = try lock.withLock { () -> Bool in
            let now = DispatchTime.now().uptimeNanoseconds
            try state.observeTime(now)
            if admissionDeadlines.values.contains(where: { now >= $0 }) { state.disconnect() }
            return state.requiresNativeFence
        }
        if fence { attachment?.cancel(); child?.requestNativeCleanup() }
    }
    func control(_ control: ClusterOwnerControl, now: UInt64) throws {
        _ = try state.accept(.init(route: state.binding.route, sequence: state.nextControlSequence, control: control), now: now)
    }
    func releaseRequest(_ id: UUID) throws {
        try control(.release(requestID: id), now: DispatchTime.now().uptimeNanoseconds)
        // The installed native worker emits retired after its runtime reservation
        // and owned state have been released. Here only the remote charge remains.
        try state.observeRequestResourcesReleased(requestID: id)
    }
    func accept(_ frame: OwnerWire) throws {
        try lock.withLock {
            let route = binding.route
            guard frame.epoch == route.membershipEpoch, frame.lease == route.leaseID,
                  frame.incarnation == route.ownerIncarnation, frame.sequence == nextIncoming else { throw OwnerWire.invalid("Owner replay or binding differs") }
            nextIncoming += 1
            let now = DispatchTime.now().uptimeNanoseconds
            switch frame.kind {
            case "fence": state.disconnect(); attachment?.cancel(); child?.requestNativeCleanup()
            case "renew":
                guard let ttl = frame.remaining else { throw OwnerWire.invalid("Lease renewal without a duration") }
                try state.renewLease(now: now, ttl: ttl)
                leaseLock.withLock { leaseDeadline = state.lifetimeDeadlineUptimeNanoseconds }
            case "bootstrapReply":
                guard let attachment, let sequence = frame.bootstrapSequence, let bytes = frame.bootstrapBytes else { throw OwnerWire.invalid("Unexpected bootstrap reply") }
                try attachment.acceptReply(sequence: sequence, bytes: bytes)
            case "release": guard terminalPublished else { throw OwnerWire.invalid("Release before native terminal") }
            case "command":
                let command = try frame.localCommand(now: now, lifetimeDeadline: deadline)
                guard command.sequence == nextWorkerCommand else { throw OwnerWire.invalid("Native command replay") }
                try session.accept(command, now: now)
                var forwardToNative = true
                switch command.command {
                case .reserve(let r):
                    guard let id = command.requestID else { throw OwnerWire.invalid("Missing request") }
                    try control(.reserve(requestID: id, capacityLimitBytes: r.capacityLimitBytes,
                        remainingNanoseconds: r.deadlineUptimeNanoseconds - now), now: now)
                    guard let delivery = frame.deliveryRemaining else { throw OwnerWire.invalid("Missing admission duration") }
                    let end = now.addingReportingOverflow(delivery)
                    guard !end.overflow else { throw OwnerWire.invalid("Admission duration overflow") }
                    admissionDeadlines[id] = min(end.partialValue, deadline)
                case .start: try control(.start(requestID: command.requestID!), now: now)
                case .cancel(let reason): try control(.cancel(requestID: command.requestID!, reason: reason), now: now)
                case .shutdown:
                    // A valid shutdown can already be in transit when an exhausted
                    // worker becomes unavailable and this owner starts fencing.
                    // Keep the release handshake alive; actual native terminal and
                    // request release remain required, and no shutdownComplete is
                    // synthesized for a child that no longer accepts commands.
                    if state.requiresNativeFence || state.status.nativeTerminal != nil {
                        forwardToNative = false
                    } else {
                        try control(.shutdown, now: now)
                    }
                case .tokenDecision, .keepWarm: break
                }
                guard let delivery = frame.deliveryRemaining else { throw OwnerWire.invalid("Missing delivery duration") }
                let deliveryEnd = now.addingReportingOverflow(delivery)
                guard !deliveryEnd.overflow else { throw OwnerWire.invalid("Delivery duration overflow") }
                if forwardToNative {
                    try child!.sendWorkerCommand(command.command, requestID: command.requestID, deadline: min(deadline, deliveryEnd.partialValue))
                }
                nextWorkerCommand += 1
            default: throw OwnerWire.invalid("Invalid owner command")
            }
        }
    }
    func relayNative() {
        guard let child else { return }
        do {
            while true {
                let frame: ClusterWorkerEventFrame
                do { frame = try child.receiveWorkerEvent(until: min(deadline, DispatchTime.now().uptimeNanoseconds + 100_000_000)) }
                catch ClusterWorkerOwnerError.deadline {
                    if DispatchTime.now().uptimeNanoseconds < deadline { continue }; throw ClusterWorkerOwnerError.deadline
                }
                catch ClusterWorkerOwnerError.closed { break }
                // One pool per event: this relay never returns to a run loop (see ClusterAutorelease).
                try ClusterAutorelease.drained {
                    if case .ready = frame.event {
                        guard attachment?.profile.publishesReadiness != false else { throw OwnerWire.invalid("Key-only authorization cannot publish native model readiness") }
                        try attachment?.requireCompleted()
                    }
                    try lock.withLock {
                        let now = DispatchTime.now().uptimeNanoseconds
                        try session.accept(frame, now: now)
                        switch frame.event {
                        case .ready(let ready): try state.observeReady(ready, launchID: launchID, now: now)
                        case .admitted(let bytes):
                            try state.observeAdmitted(requestID: frame.requestID!, reservedBytes: bytes)
                            if let end = admissionDeadlines[frame.requestID!], now >= end { state.disconnect() }
                            admissionDeadlines[frame.requestID!] = nil
                        case .refused(let reason):
                            try state.observeRefused(requestID: frame.requestID!, reason: reason)
                            admissionDeadlines[frame.requestID!] = nil
                        case .retired(let outcome):
                            try state.observeRetired(requestID: frame.requestID!, retirement: outcome)
                            try releaseRequest(frame.requestID!)
                        case .failed(let reason): Self.echoWorkerTail(child, label: "event=failed:\(reason.rawValue)"); state.disconnect()
                        case .unavailable(let reason): Self.echoWorkerTail(child, label: "event=unavailable:\(reason.rawValue)"); state.disconnect()
                        default: break
                        }
                    }
                    if lock.withLock({ state.requiresNativeFence }) { child.requestNativeCleanup(); throw ClusterWorkerOwnerError.deadline }
                    try publish(kind: "event", payload: ClusterWorkerCodec.encode(frame))
                    if lock.withLock({ state.requiresNativeFence }) { child.requestNativeCleanup() }
                }
            }
        } catch { lock.withLock { state.disconnect() }; child.requestNativeCleanup() }
        // Bounded by the child's retirement ceiling. Without an observed exit
        // no terminal is recorded and the journal stays.
        guard child.waitForExit(until: child.retirementDeadlineUptimeNanoseconds) else {
            attachment?.cancel(); lock.withLock { state.disconnect() }; return
        }
        attachment?.cancel()
        do {
            guard let termination = child.termination else { throw OwnerWire.invalid("Missing actual native terminal") }
            Self.echoWorkerTail(child, termination: termination)
            try recordTerminal(termination)
            try publishTerminal()
        } catch { lock.withLock { state.disconnect() } }
    }

    /// S24: a worker that ended abnormally usually names the cause in its own
    /// diagnostics, which only this owner holds. Their last lines are repeated
    /// on the owner's standard error, where its launcher keeps a bounded tail
    /// for the incident it records (classified, then redacted). Sizes, codes
    /// and the worker's own messages only; best effort, never fatal.
    static func echoWorkerTail(_ child: ClusterWorkerProcess, termination: ClusterWorkerProcessTermination) {
        guard let text = ClusterWorkerOwnerService.workerExitEcho(rank: child.rank, termination: termination,
                                                                  diagnosticTail: child.diagnosticTail) else { return }
        writeDiagnostics(text)
    }
    /// S24: the same tail when the worker reports a failed or unavailable
    /// request while it is still alive, so that its own words for the cause
    /// reach the member log and the leader's incident.
    static func echoWorkerTail(_ child: ClusterWorkerProcess, label: String) {
        writeDiagnostics(ClusterWorkerOwnerService.workerFailureEcho(rank: child.rank, label: label, diagnosticTail: child.diagnosticTail))
    }
    static func writeDiagnostics(_ text: String) {
        _ = fcntl(STDERR_FILENO, F_SETNOSIGPIPE, 1)
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let count = bytes[offset...].withUnsafeBytes { Darwin.write(STDERR_FILENO, $0.baseAddress, $0.count) }
            if count > 0 { offset += count } else if count < 0 && errno == EINTR { continue } else { return }
        }
    }
    func recordTerminal(_ value: ClusterWorkerProcessTermination) throws {
        try lock.withLock {
            let terminal: ClusterOwnerTermination
            switch value { case .launchFailed: terminal = .launchFailed; case .exited(let n): terminal = .exited(status: n); case .signalled(let n): terminal = .signalled(signal: n) }
            try state.observeNativeTerminal(launchID: launchID, termination: terminal)
            for id in state.activeRequestIDs { try releaseRequest(id) }
        }
    }
    func publishTerminal() throws {
        attachment?.cancel()
        attachmentTasks.wait() // No attachment publication can follow native terminal.
        guard let terminal = lock.withLock({ state.status.nativeTerminal }) else { throw OwnerWire.invalid("No native terminal") }
        // Serialize the flag with input acceptance, but never hold that lock over IO.
        lock.withLock { terminalPublished = true }
        try publish(kind: "terminal", launchID: launchID, termination: terminal.termination)
        lock.withLock { terminalWriteSucceeded = true }
    }
}

extension ClusterWorkerOwnerService {
    /// S24: what an owner repeats on its standard error when its worker ended
    /// abnormally (nil after a clean exit): one exit line, then the last 12
    /// lines (300 bytes each at most, control characters removed) of the
    /// worker's last 2 KiB of diagnostics. It is also the member log's record
    /// of why a worker ended (it replaces the separate stderr forwarder the
    /// public end-to-end track added for the same purpose).
    static func workerExitEcho(rank: Int, termination: ClusterWorkerProcessTermination, diagnosticTail: Data) -> String? {
        if case .exited(0) = termination { return nil }
        return workerDiagnosticEcho(header: "darkbloom-worker-exit-v1 rank=\(rank) termination=\(termination)", diagnosticTail: diagnosticTail)
    }
    static func workerFailureEcho(rank: Int, label: String, diagnosticTail: Data) -> String {
        workerDiagnosticEcho(header: "darkbloom-worker-fail-v1 rank=\(rank) \(label)", diagnosticTail: diagnosticTail)
    }
    static func workerDiagnosticEcho(header: String, diagnosticTail: Data) -> String {
        let tail = String(decoding: diagnosticTail.suffix(2_048), as: UTF8.self)
        var text = header + "\n"
        for line in tail.split(whereSeparator: \.isNewline).suffix(12) {
            // Control characters removed: the member log and the incident record are plain text.
            let clean = String(String.UnicodeScalarView(line.prefix(300).unicodeScalars.filter { $0.value >= 32 && $0.value != 127 }))
            text += "darkbloom-worker-tail-v1 \(clean)\n"
        }
        return text
    }
}

/// The worker protocol order this owner checks: one request at a time, or
/// several (its batch lanes) interleaved, each in that same order.
enum OwnerWorkerSession: Sendable {
    case single(ClusterWorkerSession)
    case lanes(ClusterWorkerLaneSession)

    mutating func accept(_ frame: ClusterWorkerCommandFrame, now: UInt64) throws {
        switch self {
        case .single(var value): defer { self = .single(value) }; try value.accept(frame, now: now)
        case .lanes(var value): defer { self = .lanes(value) }; try value.accept(frame, now: now)
        }
    }

    mutating func accept(_ frame: ClusterWorkerEventFrame, now: UInt64) throws {
        switch self {
        case .single(var value): defer { self = .single(value) }; try value.accept(frame, now: now)
        case .lanes(var value): defer { self = .lanes(value) }; try value.accept(frame, now: now)
        }
    }
}
