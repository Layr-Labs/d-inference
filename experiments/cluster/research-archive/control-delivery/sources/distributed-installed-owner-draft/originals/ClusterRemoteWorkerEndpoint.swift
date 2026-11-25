import Foundation
import Darwin
import DarkbloomClusterProtocol
import DarkbloomClusterProcess

/// One authenticated SSH owner connection. The SSH process is only transport;
/// nativeCleanupObserved requires that owner's current-incarnation terminal.
public final class ClusterRemoteWorkerEndpoint: ClusterWorkerEndpoint, @unchecked Sendable {
    public let expectedIdentity: ClusterWorkerIdentity
    public let expectedProfile: ClusterWorkerProfile
    public let rank: Int
    public let executionPlanSHA256: String
    public let localLifetimeDeadlineUptimeNanoseconds: UInt64
    let clusterID: String
    let leaseID = UUID()
    private let bootstrapRelay: ClusterOwnerBootstrapRelay?
    private var bootstrapReplies: [(UInt64, Data)] = []
    private var bootstrapBusy = false
    private var nextBootstrapSequence: UInt64 = 0
    private let process = Process()
    private let input = Pipe(), output = Pipe(), diagnostics = Pipe()
    private let lock = NSLock()
    private let arrivals = DispatchSemaphore(value: 0)
    private let nativeEnded = DispatchGroup()
    private let notifications = DispatchQueue(label: "darkbloom.remote-owner.invalidation")
    private var handler: (@Sendable () -> Void)?
    private var notified = false
    private var invalid = false
    private var cleanup = false
    private var ownerReleased = false
    private var ready: ClusterWorkerReady?
    private var incarnation: UUID?
    private var launchID: UUID?
    private var incoming: [ClusterWorkerEventFrame] = []
    private var outgoing: [(ClusterWorkerCommandFrame, UInt64)] = []
    private var nextCommand: UInt64 = 0
    private var nextNativeEvent: UInt64 = 0
    private var nextWireEvent: UInt64 = 0
    private var fenceRequested = false
    private var releaseRequested = false
    private var stderr = Data()
    public var readiness: ClusterWorkerReady? { lock.withLock { invalid ? nil : ready } }
    public var nativeCleanupObserved: Bool { lock.withLock { cleanup } }
    /// Authenticated current-owner acknowledgment that its device lease journal was resolved.
    public var ownerDeviceLeaseReleasedObserved: Bool { lock.withLock { ownerReleased } }
    public var diagnosticTail: Data { lock.withLock { stderr } }

    public convenience init(configuration: ClusterSSHConfiguration, clusterID: String,
                            expectedIdentity: ClusterWorkerIdentity, profile: ClusterWorkerProfile, rank: Int,
                            executionPlanSHA256: String, lifetimeDeadlineUptimeNanoseconds: UInt64, bootstrapRelay: ClusterOwnerBootstrapRelay? = nil) throws {
        try self.init(transport: configuration.launch(), clusterID: clusterID, expectedIdentity: expectedIdentity,
            profile: profile, rank: rank, executionPlanSHA256: executionPlanSHA256,
            lifetimeDeadlineUptimeNanoseconds: lifetimeDeadlineUptimeNanoseconds, bootstrapRelay: bootstrapRelay)
    }
    // Internal local-child seam exists solely for CPU service tests. Production
    // callers cannot substitute an arbitrary shell/transport through this API.
    init(transport: ClusterWorkerLaunch, clusterID: String, expectedIdentity: ClusterWorkerIdentity,
         profile: ClusterWorkerProfile, rank: Int, executionPlanSHA256: String,
         lifetimeDeadlineUptimeNanoseconds: UInt64, bootstrapRelay: ClusterOwnerBootstrapRelay? = nil) throws {
        _ = try ClusterOwnerBinding(clusterID: clusterID, ownerIncarnation: UUID(), leaseID: leaseID,
            identity: expectedIdentity, profile: profile, rank: rank, executionPlanSHA256: executionPlanSHA256)
        let now = DispatchTime.now().uptimeNanoseconds
        guard lifetimeDeadlineUptimeNanoseconds > now,
              lifetimeDeadlineUptimeNanoseconds - now <= ClusterWorkerLimits.deadlineNanoseconds else { throw OwnerWire.invalid("Invalid remote lifetime") }
        if let bootstrapRelay {
            guard bootstrapRelay.identity == expectedIdentity, bootstrapRelay.executionPlanSHA256 == executionPlanSHA256,
                  bootstrapRelay.deadlineUptimeNanoseconds <= lifetimeDeadlineUptimeNanoseconds else { throw OwnerWire.invalid("Bootstrap relay configuration differs") }
        }
        self.bootstrapRelay = bootstrapRelay
        self.clusterID = clusterID; self.expectedIdentity = expectedIdentity; expectedProfile = profile; self.rank = rank
        self.executionPlanSHA256 = executionPlanSHA256; localLifetimeDeadlineUptimeNanoseconds = lifetimeDeadlineUptimeNanoseconds
        process.executableURL = transport.executable; process.arguments = transport.arguments; process.environment = transport.environment
        process.standardInput = input; process.standardOutput = output; process.standardError = diagnostics
        let pipe = try ClusterOwnerPipe(input: output.fileHandleForReading.fileDescriptor, output: input.fileHandleForWriting.fileDescriptor, readingCommands: false)
        let err = diagnostics.fileHandleForReading.fileDescriptor
        guard fcntl(err, F_SETFL, fcntl(err, F_GETFL) | O_NONBLOCK) == 0 else { throw OwnerWire.invalid("Cannot bound SSH diagnostics") }
        nativeEnded.enter()
        try process.run()
        try? input.fileHandleForReading.close(); try? output.fileHandleForWriting.close(); try? diagnostics.fileHandleForWriting.close()
        DispatchQueue(label: "darkbloom.remote-owner.writer").async { self.writeLoop(pipe) }
        DispatchQueue(label: "darkbloom.remote-owner.reader").async { self.readLoop(pipe) }
    }
    public func setInvalidationHandler(_ handler: @escaping @Sendable () -> Void) {
        let call = lock.withLock { self.handler = handler; return notificationLocked() }
        if let call { notifications.async(execute: call) }
    }
    private func notificationLocked() -> (@Sendable () -> Void)? {
        guard invalid, !notified, let handler else { return nil }; notified = true; return handler
    }
    private func fail() {
        let call = lock.withLock { invalid = true; ready = nil; if !cleanup { fenceRequested = true }; return notificationLocked() }
        bootstrapRelay?.cancel()
        arrivals.signal(); if let call { notifications.async(execute: call) }
    }
    /// Called under Pair/Request locks: validates and queues only, never performs
    /// SSH/native IO or invokes an invalidation callback synchronously.
    public func sendWorkerCommand(_ command: ClusterWorkerCommand, requestID: UUID?, deadline: UInt64) throws {
        try lock.withLock {
            guard !invalid, !cleanup, deadline > DispatchTime.now().uptimeNanoseconds, outgoing.count < 16 else { throw ClusterWorkerOwnerError.closed }
            let frame = ClusterWorkerCommandFrame(membershipEpoch: expectedIdentity.membershipEpoch, sequence: nextCommand,
                requestID: requestID, command: command)
            let bytes = try ClusterWorkerCodec.encode(frame)
            let queued = try outgoing.reduce(0) { try $0 + ClusterWorkerCodec.encode($1.0).count }
            guard bytes.count <= 1_048_576 - queued else { throw OwnerWire.invalid("Remote command queue full") }
            outgoing.append((frame, deadline)); nextCommand += 1
        }
    }
    public func receiveWorkerEvent(until deadline: UInt64, cancelled: () -> Bool) throws -> ClusterWorkerEventFrame {
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if cancelled() { throw ClusterWorkerOwnerError.cancelled }
            if let event = lock.withLock({ incoming.isEmpty ? nil : incoming.removeFirst() }) { return event }
            if lock.withLock({ invalid || cleanup }) { throw ClusterWorkerOwnerError.closed }
            _ = arrivals.wait(timeout: .init(uptimeNanoseconds: min(deadline, DispatchTime.now().uptimeNanoseconds + 50_000_000)))
        }
        throw ClusterWorkerOwnerError.deadline
    }
    public func requestNativeCleanup() { fail() }
    public func waitForNativeCleanup() { nativeEnded.wait() }
    public func waitUntilNativeCleanup() async {
        await withCheckedContinuation { c in nativeEnded.notify(queue: .global()) { c.resume() } }
    }
    private func writeLoop(_ pipe: ClusterOwnerPipe) {
        var sequence: UInt64 = 0
        do {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < localLifetimeDeadlineUptimeNanoseconds else { throw ClusterWorkerOwnerError.deadline }
            let open = OwnerWire(kind: "open", epoch: expectedIdentity.membershipEpoch, lease: leaseID,
                incarnation: nil, sequence: 0, clusterID: clusterID, remaining: localLifetimeDeadlineUptimeNanoseconds - now, bootstrapProfile: bootstrapRelay?.profile)
            try pipe.write(open.encoded(commandStream: true), until: min(localLifetimeDeadlineUptimeNanoseconds, now + 5_000_000_000)); sequence += 1
            var sentFence = false, sentRelease = false
            while process.isRunning {
                let now = DispatchTime.now().uptimeNanoseconds
                if now >= localLifetimeDeadlineUptimeNanoseconds { fail() }
                let work = lock.withLock { () -> (UUID?, Bool, Bool, (ClusterWorkerCommandFrame, UInt64)?, (UInt64, Data)?) in
                    let bootstrap = !invalid && !bootstrapReplies.isEmpty ? bootstrapReplies.removeFirst() : nil
                    let next = bootstrap == nil && !invalid && incarnation != nil && !outgoing.isEmpty ? outgoing.removeFirst() : nil
                    return (incarnation, fenceRequested && !cleanup, releaseRequested, next, bootstrap)
                }
                if let incarnation = work.0 {
                    let frame: OwnerWire?
                    var writeDeadline = min(localLifetimeDeadlineUptimeNanoseconds + 2_000_000_000, now + 500_000_000)
                    if work.2 && !sentRelease {
                        frame = OwnerWire(kind: "release", epoch: expectedIdentity.membershipEpoch, lease: leaseID, incarnation: incarnation, sequence: sequence); sentRelease = true
                    } else if work.1 && !sentFence {
                        frame = OwnerWire(kind: "fence", epoch: expectedIdentity.membershipEpoch, lease: leaseID, incarnation: incarnation, sequence: sequence); sentFence = true
                    } else if let (round, bytes) = work.4 {
                        frame = OwnerWire(kind: "bootstrapReply", epoch: expectedIdentity.membershipEpoch,
                            lease: leaseID, incarnation: incarnation, sequence: sequence,
                            bootstrapSequence: round, bootstrapBytes: bytes)
                        writeDeadline = min(writeDeadline, bootstrapRelay!.deadlineUptimeNanoseconds)
                    } else if let (command, deadline) = work.3 {
                        guard now < deadline else { throw ClusterWorkerOwnerError.deadline }
                        frame = try OwnerWire.command(command, lease: leaseID, incarnation: incarnation, sequence: sequence, now: now, deliveryDeadline: deadline)
                        writeDeadline = min(writeDeadline, deadline)
                    } else { frame = nil }
                    if let frame {
                        try pipe.write(frame.encoded(commandStream: true), until: writeDeadline)
                        sequence += 1
                    }
                }
                if lock.withLock({ ownerReleased }) { return }
                Thread.sleep(forTimeInterval: 0.005)
            }
        } catch {
            fail()
            // Preserve the read half for actual terminal proof. EOF asks the
            // still-live remote owner to fence; EOF itself proves nothing.
            pipe.closeOutput(); try? input.fileHandleForWriting.close()
        }
    }
    private func readLoop(_ pipe: ClusterOwnerPipe) {
        defer {
            // Reaping ssh owns transport only; this never leaves nativeEnded.
            if process.isRunning { process.terminate() }
            let limit = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
            while process.isRunning && DispatchTime.now().uptimeNanoseconds < limit { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close(); try? diagnostics.fileHandleForReading.close()
        }
        do {
            while true {
                let now = DispatchTime.now().uptimeNanoseconds
                if now >= localLifetimeDeadlineUptimeNanoseconds { fail() }
                if now >= localLifetimeDeadlineUptimeNanoseconds + 2_000_000_000 { throw ClusterWorkerOwnerError.deadline }
                var buffer = [UInt8](repeating: 0, count: 65_536)
                let count = Darwin.read(diagnostics.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
                if count > 0 {
                    try lock.withLock { guard stderr.count <= 1_048_576 - count else { throw OwnerWire.invalid("SSH stderr exceeded bound") }; stderr.append(contentsOf: buffer.prefix(count)) }
                }
                if let bytes = try pipe.read(until: now + 50_000_000) { try accept(OwnerWire.decode(bytes, commandStream: false)) }
                if lock.withLock({ ownerReleased }) { return }
                if !process.isRunning { throw ClusterWorkerOwnerError.closed }
            }
        } catch { fail() }
    }
    private func accept(_ frame: OwnerWire) throws {
        var complete = false, invalidateEvent = false
        var bootstrapWork: (ClusterOwnerBinding, UInt64, Data)?
        try lock.withLock {
            guard frame.epoch == expectedIdentity.membershipEpoch, frame.lease == leaseID,
                  frame.sequence == nextWireEvent else { throw OwnerWire.invalid("Remote owner epoch/lease/replay differs") }
            if frame.kind == "hello" {
                guard nextWireEvent == 0, incarnation == nil, frame.bootstrapProfile == bootstrapRelay?.profile, let inc = frame.incarnation, let launch = frame.launchID else { throw OwnerWire.invalid("Repeated owner incarnation") }
                incarnation = inc; launchID = launch
            } else {
                guard incarnation != nil, frame.incarnation == incarnation else { throw OwnerWire.invalid("Remote incarnation differs") }
                switch frame.kind {
                case "bootstrapRound":
                    guard let bootstrapRelay, ready == nil, !cleanup,
                          frame.bootstrapSequence == nextBootstrapSequence, let bytes = frame.bootstrapBytes else {
                        throw OwnerWire.invalid("Unexpected bootstrap round")
                    }
                    try bootstrapRelay.profile.validate(sequence: nextBootstrapSequence, contribution: bytes)
                    guard !bootstrapBusy else { throw OwnerWire.invalid("Concurrent bootstrap round") }
                    if invalid { nextBootstrapSequence += 1; break } // Drain valid in-flight round; keep reading terminal/released.
                    let binding = try ClusterOwnerBinding(clusterID: clusterID, ownerIncarnation: incarnation!, leaseID: leaseID,
                        identity: expectedIdentity, profile: expectedProfile, rank: rank, executionPlanSHA256: executionPlanSHA256)
                    bootstrapBusy = true; bootstrapWork = (binding, nextBootstrapSequence, bytes)
                case "event":
                    guard !cleanup, let payload = frame.payload else { throw OwnerWire.invalid("Event after native terminal") }
                    let event = try ClusterWorkerCodec.decodeEvent(payload)
                    guard event.membershipEpoch == expectedIdentity.membershipEpoch, event.sequence == nextNativeEvent,
                          incoming.count < 32 else { throw OwnerWire.invalid("Native event replay or queue bound") }
                    if case .ready(let value) = event.event {
                        guard nextNativeEvent == 0, bootstrapRelay == nil || nextBootstrapSequence == 4, value.identity == expectedIdentity, value.profile == expectedProfile,
                              value.rank == rank, value.executionPlanSHA256 == executionPlanSHA256 else { throw OwnerWire.invalid("Remote readiness differs") }
                        ready = value
                    } else { guard nextNativeEvent > 0 else { throw OwnerWire.invalid("Event precedes readiness") } }
                    incoming.append(event); nextNativeEvent += 1
                    switch event.event { case .failed, .unavailable: invalidateEvent = true; default: break }
                case "terminal":
                    guard !cleanup, frame.launchID == launchID, frame.termination != nil else { throw OwnerWire.invalid("Wrong native terminal") }
                    cleanup = true; ready = nil; releaseRequested = true; complete = true
                case "released": guard cleanup else { throw OwnerWire.invalid("Lease release precedes native cleanup") }; ownerReleased = true
                default: throw OwnerWire.invalid("Unexpected owner event")
                }
            }
            nextWireEvent += 1
        }
        if let (binding, sequence, bytes) = bootstrapWork {
            DispatchQueue(label: "darkbloom.remote-bootstrap.\(rank)").async {
                do {
                    let gathered = try self.bootstrapRelay!.exchange(binding: binding, sequence: sequence, contribution: bytes)
                    try self.lock.withLock {
                        guard !self.invalid, !self.cleanup, self.bootstrapReplies.isEmpty else { throw OwnerWire.invalid("Bootstrap reply queue unavailable") }
                        self.bootstrapReplies.append((sequence, gathered)); self.nextBootstrapSequence += 1; self.bootstrapBusy = false
                    }
                } catch { self.fail() }
            }
        }
        if complete { nativeEnded.leave() }
        if complete || invalidateEvent { fail() }
        arrivals.signal()
    }
}
