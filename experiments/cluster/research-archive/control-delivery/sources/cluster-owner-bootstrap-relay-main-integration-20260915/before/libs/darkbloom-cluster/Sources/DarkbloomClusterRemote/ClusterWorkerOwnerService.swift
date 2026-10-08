import Foundation
import DarkbloomClusterProtocol
import DarkbloomClusterProcess

/// Installed darkbloom's configured worker-owner entry calls this service. No
/// executable, model path, environment or bootstrap address is accepted on wire.
public enum ClusterWorkerOwnerService {
    /// This factory must return an UNLAUNCHED direct child. For physical JACCL it
    /// must require the authenticated bootstrap attachment; plaintext fallback is
    /// not an implementation of that configuration. The child's native hard
    /// alarm must also cover owner death; this supervisor cannot run after death.
    public typealias NativeFactory = @Sendable (ClusterOwnerBinding, UInt64) throws -> ClusterWorkerProcess
    public typealias BindingFactory = @Sendable (UUID, UUID, UUID) throws -> ClusterOwnerBinding

    public static func serve(input: Int32, output: Int32, clusterID: String, leaseDirectory: URL,
                             maximumLifetimeNanoseconds: UInt64,
                             binding: BindingFactory, native: NativeFactory) throws {
        let pipe = try ClusterOwnerPipe(input: input, output: output, readingCommands: true)
        let begin = DispatchTime.now().uptimeNanoseconds
        guard maximumLifetimeNanoseconds > 0, maximumLifetimeNanoseconds <= ClusterWorkerLimits.deadlineNanoseconds else {
            throw OwnerWire.invalid("Invalid configured owner lifetime")
        }
        guard let bytes = try pipe.read(until: begin + 5_000_000_000) else { throw ClusterWorkerOwnerErrorProxy.deadline }
        let open = try OwnerWire.decode(bytes, commandStream: true)
        guard open.kind == "open", open.sequence == 0, open.clusterID == clusterID, let duration = open.remaining else {
            throw OwnerWire.invalid("Owner open differs from installed configuration")
        }
        let ownerBinding = try binding(open.epoch, open.lease, UUID())
        guard ownerBinding.route.clusterID == clusterID, ownerBinding.route.membershipEpoch == open.epoch,
              ownerBinding.route.leaseID == open.lease else { throw OwnerWire.invalid("Configured owner binding differs") }
        let lease = try ClusterDeviceLease(directoryURL: leaseDirectory)
        var state = try ClusterOwnerLeaseState(binding: ownerBinding, now: DispatchTime.now().uptimeNanoseconds,
            remainingLifetimeNanoseconds: min(duration, maximumLifetimeNanoseconds))
        let launchID = UUID()
        try state.beginNativeLaunch(launchID, now: DispatchTime.now().uptimeNanoseconds)
        try lease.record(binding: ownerBinding, launchID: launchID)
        let context = ServiceContext(pipe: pipe, state: state, launchID: launchID)
        // Hello establishes a fresh incarnation before any native readiness.
        try context.publish(kind: "hello", launchID: launchID)
        let child: ClusterWorkerProcess
        do {
            child = try native(ownerBinding, state.lifetimeDeadlineUptimeNanoseconds)
            context.child = child
            guard child.launchedProcessIdentifier == nil, child.termination == nil, !child.nativeCleanupObserved, child.expectedIdentity == ownerBinding.identity, child.rank == ownerBinding.rank,
                  child.expectedProfile == ownerBinding.profile, child.executionPlanSHA256 == ownerBinding.executionPlanSHA256,
                  child.localLifetimeDeadlineUptimeNanoseconds <= state.lifetimeDeadlineUptimeNanoseconds else {
                throw OwnerWire.invalid("Native factory binding differs")
            }
            try child.launch()
            try context.lock.withLock { try context.state.observeNativeStarted(launchID) }
        } catch {
            // Factory contract permits only construction before launch; run failure
            // is independently exposed by Process. No PID-absence inference.
            if let child = context.child, child.launchedProcessIdentifier != nil {
                try context.lock.withLock { if !context.state.childStarted { try context.state.observeNativeStarted(launchID) } }
                child.requestNativeCleanup(); child.waitForNativeCleanup()
                if let terminal = child.termination { try context.recordTerminal(terminal) }
            } else { try context.recordTerminal(.launchFailed) }
            try? context.publishTerminal()
            throw error // Sticky journal: no remote release acknowledgement.
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
                try context.observeTime()
                if now >= context.deadline { throw ClusterWorkerOwnerErrorProxy.deadline }
                guard let line = try pipe.read(until: min(context.deadline, now + 100_000_000)) else { continue }
                let frame = try OwnerWire.decode(line, commandStream: true)
                try context.accept(frame)
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
            child.requestNativeCleanup(); child.waitForNativeCleanup(); relay.wait()
            // Even if actual cleanup succeeded, loss of the release handshake
            // leaves the durable journal unresolved and prevents another load.
            throw error
        }
    }
}

private final class ServiceContext: @unchecked Sendable {
    let pipe: ClusterOwnerPipe
    let lock = NSLock()
    let writeLock = NSLock()
    var state: ClusterOwnerLeaseState
    let launchID: UUID
    var child: ClusterWorkerProcess?
    var nextIncoming: UInt64 = 1
    var nextOutgoing: UInt64 = 0
    var nextWorkerCommand: UInt64 = 0
    var terminalPublished = false
    var terminalWriteSucceeded = false
    var admissionDeadline: UInt64?
    var session: ClusterWorkerSession
    let deadline: UInt64
    let binding: ClusterOwnerBinding
    init(pipe: ClusterOwnerPipe, state: ClusterOwnerLeaseState, launchID: UUID) {
        self.pipe = pipe; self.state = state; self.launchID = launchID
        deadline = state.lifetimeDeadlineUptimeNanoseconds; binding = state.binding
        // Binding was validated by its initializer.
        session = try! ClusterWorkerSession(identity: state.binding.identity, rank: state.binding.rank,
            profile: state.binding.profile, executionPlanSHA256: state.binding.executionPlanSHA256)
    }
    func publish(kind: String, payload: Data? = nil, launchID: UUID? = nil, termination: ClusterOwnerTermination? = nil) throws {
        try writeLock.withLock {
            let route = binding.route
            let frame = OwnerWire(kind: kind, epoch: route.membershipEpoch, lease: route.leaseID,
                incarnation: route.ownerIncarnation, sequence: nextOutgoing, launchID: launchID,
                payload: payload, termination: termination)
            try pipe.write(frame.encoded(commandStream: false), until: min(deadline + 2_000_000_000, DispatchTime.now().uptimeNanoseconds + 500_000_000))
            nextOutgoing += 1
        }
    }
    func observeTime() throws {
        let fence = try lock.withLock { () -> Bool in
            let now = DispatchTime.now().uptimeNanoseconds
            try state.observeTime(now)
            if let admissionDeadline, now >= admissionDeadline { state.disconnect() }
            return state.requiresNativeFence
        }
        if fence { child?.requestNativeCleanup() }
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
            case "fence": state.disconnect(); child?.requestNativeCleanup()
            case "release": guard terminalPublished else { throw OwnerWire.invalid("Release before native terminal") }
            case "command":
                let command = try frame.localCommand(now: now, lifetimeDeadline: deadline)
                guard command.sequence == nextWorkerCommand else { throw OwnerWire.invalid("Native command replay") }
                try session.accept(command, now: now)
                switch command.command {
                case .reserve(let r):
                    guard let id = command.requestID else { throw OwnerWire.invalid("Missing request") }
                    try control(.reserve(requestID: id, capacityLimitBytes: r.capacityLimitBytes,
                        remainingNanoseconds: r.deadlineUptimeNanoseconds - now), now: now)
                    guard let delivery = frame.deliveryRemaining else { throw OwnerWire.invalid("Missing admission duration") }
                    let end = now.addingReportingOverflow(delivery)
                    guard !end.overflow else { throw OwnerWire.invalid("Admission duration overflow") }
                    admissionDeadline = min(end.partialValue, deadline)
                case .start: try control(.start(requestID: command.requestID!), now: now)
                case .cancel(let reason): try control(.cancel(requestID: command.requestID!, reason: reason), now: now)
                case .shutdown: try control(.shutdown, now: now)
                case .tokenDecision: break
                }
                guard let delivery = frame.deliveryRemaining else { throw OwnerWire.invalid("Missing delivery duration") }
                let deliveryEnd = now.addingReportingOverflow(delivery)
                guard !deliveryEnd.overflow else { throw OwnerWire.invalid("Delivery duration overflow") }
                try child!.sendWorkerCommand(command.command, requestID: command.requestID, deadline: min(deadline, deliveryEnd.partialValue))
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
                try lock.withLock {
                    let now = DispatchTime.now().uptimeNanoseconds
                    try session.accept(frame, now: now)
                    switch frame.event {
                    case .ready(let ready): try state.observeReady(ready, launchID: launchID, now: now)
                    case .admitted(let bytes):
                        try state.observeAdmitted(requestID: frame.requestID!, reservedBytes: bytes)
                        if let admissionDeadline, now >= admissionDeadline { state.disconnect() }
                        admissionDeadline = nil
                    case .refused: try state.observeRefused(requestID: frame.requestID!); admissionDeadline = nil
                    case .retired(let outcome):
                        try state.observeRetired(requestID: frame.requestID!, retirement: outcome)
                        try releaseRequest(frame.requestID!)
                    case .failed, .unavailable: state.disconnect()
                    default: break
                    }
                }
                if lock.withLock({ state.requiresNativeFence }) { child.requestNativeCleanup(); throw ClusterWorkerOwnerError.deadline }
                try publish(kind: "event", payload: ClusterWorkerCodec.encode(frame))
                if lock.withLock({ state.requiresNativeFence }) { child.requestNativeCleanup() }
            }
        } catch { lock.withLock { state.disconnect() }; child.requestNativeCleanup() }
        child.waitForNativeCleanup()
        do {
            guard let termination = child.termination else { throw OwnerWire.invalid("Missing actual native terminal") }
            try recordTerminal(termination)
            try publishTerminal()
        } catch { lock.withLock { state.disconnect() } }
    }
    func recordTerminal(_ value: ClusterWorkerProcessTermination) throws {
        try lock.withLock {
            let terminal: ClusterOwnerTermination
            switch value { case .launchFailed: terminal = .launchFailed; case .exited(let n): terminal = .exited(status: n); case .signalled(let n): terminal = .signalled(signal: n) }
            try state.observeNativeTerminal(launchID: launchID, termination: terminal)
            if let id = state.status.activeRequestID { try releaseRequest(id) }
        }
    }
    func publishTerminal() throws {
        guard let terminal = lock.withLock({ state.status.nativeTerminal }) else { throw OwnerWire.invalid("No native terminal") }
        // Serialize the flag with input acceptance, but never hold that lock over IO.
        lock.withLock { terminalPublished = true }
        try publish(kind: "terminal", launchID: launchID, termination: terminal.termination)
        lock.withLock { terminalWriteSucceeded = true }
    }
}
