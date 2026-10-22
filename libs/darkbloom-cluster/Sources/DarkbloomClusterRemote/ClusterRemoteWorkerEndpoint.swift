import Foundation
import Darwin
import DarkbloomClusterProtocol
import DarkbloomClusterProcess
import DarkbloomClusterSecurity

/// One authenticated SSH owner connection. The SSH process is only transport;
/// nativeCleanupObserved requires that owner's current-incarnation terminal.
///
/// The transport process is control only: `ssh`, or the local owner that
/// supervises the native child. It never holds the model. Ending a local owner
/// early would end the supervision that waits for the child and clears the
/// device journal, so without a release acknowledgement this endpoint closes its
/// command stream (the owner's order to fence) and lets the owner run to its own
/// retirement ceiling before signalling it.
public final class ClusterRemoteWorkerEndpoint: ClusterOwnedWorkerEndpoint, @unchecked Sendable {
    /// Past the session lifetime: the child's retirement allowance, the owner's
    /// release handshake, and slack for the connection. An owner sizes its
    /// child's SIGTERM-to-SIGKILL margin to the bytes the child holds (up to
    /// 120 s), so this side allows the largest such margin.
    public static let standardOwnerRetirementAllowanceNanoseconds: UInt64 =
        ClusterWorkerSignalPolicy.maximumAllowanceNanoseconds + ClusterWorkerOwnerService.handshakeAllowanceNanoseconds + 5_000_000_000
    private let ownerRetirementAllowance: UInt64
    /// Guarded by `lock`; only ever moved later, once, when the hello arrives.
    private var ownerCeiling: UInt64
    private var offeredLifetime: UInt64 = 0
    /// The latest moment this endpoint still listens to, and refrains from
    /// signalling, an owner that has not acknowledged a release.
    ///
    /// An owner starts its lifetime when it reads the open, after its own
    /// preparation, so its lifetime ends later than this side's by that delay
    /// and its retirement ceiling with it. The delay is not known here, but it
    /// is bounded by the hello: the owner had read the open before it sent
    /// one, so its lifetime ends no later than the hello's arrival plus the
    /// lifetime the open offered. Until a hello arrives the ceiling is this
    /// side's own lifetime plus the allowance; no child is launched before
    /// the hello is written.
    public var ownerRetirementDeadlineUptimeNanoseconds: UInt64 { lock.withLock { ownerCeiling } }
    public let expectedIdentity: ClusterWorkerIdentity
    public let expectedProfile: ClusterWorkerProfile
    public let rank: Int
    public let executionPlanSHA256: String
    /// The rank lease this endpoint has granted the owner, on this Mac's
    /// clock (S03): the open's first grant, then each renewal's send time plus
    /// the time to live. There is no fixed lifetime; it moves while this
    /// endpoint keeps the owner and stops when it is fenced or released.
    public var localLifetimeDeadlineUptimeNanoseconds: UInt64 { lock.withLock { leaseDeadline } }
    private var leaseDeadline: UInt64
    private var nextRenewalAt: UInt64 = 0
    private var renewalsSent: UInt64 = 0
    let clusterID: String
    let leaseID: UUID
    private let nativeKeyRelay: ClusterOwnerNativeKeyRelay?
    private var selectedBootstrapProfile: ClusterOwnerBootstrapProfile? { nativeKeyRelay == nil ? bootstrapRelay?.profile : .nativeKeyPrelude }
    private var selectedBootstrapDeadline: UInt64? { nativeKeyRelay?.deadlineUptimeNanoseconds ?? bootstrapRelay?.deadlineUptimeNanoseconds }
    private let bootstrapRelay: (any ClusterOwnerBootstrapExchange)?
    /// The committed native start of this rank under the combined profile.
    private let relayStart: ClusterNativeAuthorizationStart?
    /// S16: the worker's data-plane credential line, sent once in the open frame.
    private let dataPlaneTrust: Data?
    private var bootstrapReplies: [(UInt64, Data)] = []
    private var bootstrapBusy = false
    private var nextBootstrapSequence: UInt64 = 0
    private let process = Process()
    /// The owner's exit as Foundation reports it. The reader waits on this,
    /// never on `waitUntilExit()`, which can sleep on a dispatch thread long
    /// after the owner is gone and so withhold the proof of its exit.
    private let ownerExit = ClusterProcessExit()
    private let input = Pipe(), output = Pipe(), diagnostics = Pipe()
    private let lock = NSLock()
    private let arrivals = DispatchSemaphore(value: 0)
    /// Wakes the writer whenever it has something new to write: a queued
    /// command or bootstrap reply, a fence or release request, or the hello
    /// that starts the renewal schedule. The writer writes as soon as it is
    /// woken and otherwise rests until the next renewal is due.
    private let writerWake = DispatchSemaphore(value: 0)
    /// The longest an idle writer rests: the lifetime check and the owner's
    /// exit are seen at least this often.
    static let writerIdleNanoseconds: UInt64 = 50_000_000
    private let nativeEnded = DispatchGroup()
    private let ownerEnded = DispatchGroup()
    private var ownerTerminationValue: ClusterWorkerProcessTermination?
    /// Why this owner's cleanup proof will never arrive (S24), once that is known.
    private var unresolvedText: String?
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
    private let diagnosticCapture = ClusterOwnerDiagnostics()
    public var readiness: ClusterWorkerReady? { lock.withLock { invalid ? nil : ready } }
    public var nativeCleanupObserved: Bool { lock.withLock { cleanup } }
    /// Authenticated current-owner acknowledgment that its device lease journal was resolved.
    public var ownerDeviceLeaseReleasedObserved: Bool { lock.withLock { ownerReleased } }
    public var diagnosticTail: Data { diagnosticCapture.snapshot }
    /// True only after the diagnostic pipe reaches EOF within its byte/time
    /// bounds. Independent of native cleanup, release ACK and transport exit.
    public var diagnosticDrainComplete: Bool { diagnosticCapture.isComplete }
    public var ownerTermination: ClusterWorkerProcessTermination? { lock.withLock { ownerTerminationValue } }
    /// Set once the owner (or its transport) is gone without its worker's
    /// cleanup proof: what happened, for the unresolved-cleanup incident.
    public var unresolvedReason: String? { lock.withLock { unresolvedText } }
    /// The owner process while it runs (checks only).
    var ownerProcessIdentifier: Int32? { process.isRunning ? process.processIdentifier : nil }
    static func describe(_ termination: ClusterWorkerProcessTermination?) -> String {
        switch termination {
        case .exited(let status)?: "exited with status \(status)"
        case .signalled(let signal)?: "was terminated by signal \(signal)"
        case .launchFailed?: "could not be launched"
        case nil: "ended"
        }
    }

    public func waitForOwnerReleased(deadline: UInt64) -> Bool {
        let finished = ownerEnded.wait(timeout: .init(uptimeNanoseconds: deadline)) == .success
        return finished && lock.withLock { cleanup && ownerReleased && ownerTerminationValue == .exited(0) }
    }

    /// Actual local owner/SSH transport exit plus the authenticated release ACK.
    /// Timeout or EOF without that ACK returns false and grants no cleanup proof.
    public func waitUntilOwnerReleased(deadline: UInt64) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let finished = self.ownerEnded.wait(timeout: .init(uptimeNanoseconds: deadline)) == .success
                continuation.resume(returning: finished && self.lock.withLock {
                    self.cleanup && self.ownerReleased && self.ownerTerminationValue == .exited(0)
                })
            }
        }
    }

    public convenience init(localOwner: ClusterLocalOwnerConfiguration, clusterID: String,
                            expectedIdentity: ClusterWorkerIdentity, profile: ClusterWorkerProfile, rank: Int,
                            executionPlanSHA256: String, lifetimeDeadlineUptimeNanoseconds: UInt64,
                            bootstrapRelay: (any ClusterOwnerBootstrapExchange)?, dataPlaneTrust: Data? = nil) throws {
        try self.init(transport: localOwner.launch(), clusterID: clusterID, expectedIdentity: expectedIdentity,
            profile: profile, rank: rank, executionPlanSHA256: executionPlanSHA256,
            lifetimeDeadlineUptimeNanoseconds: lifetimeDeadlineUptimeNanoseconds, bootstrapRelay: bootstrapRelay,
            dataPlaneTrust: dataPlaneTrust)
    }

    /// Only a local owned process may receive a local monotonic key-prelude deadline.
    /// The configured executable must explicitly support/validate this profile;
    /// the ordinary installed owner refuses it without launching a native child.
    public convenience init(localOwner: ClusterLocalOwnerConfiguration, clusterID: String,
                            expectedIdentity: ClusterWorkerIdentity, profile: ClusterWorkerProfile, rank: Int,
                            executionPlanSHA256: String, lifetimeDeadlineUptimeNanoseconds: UInt64,
                            nativeKeyRelay: ClusterOwnerNativeKeyRelay) throws {
        try self.init(transport: localOwner.launch(), clusterID: clusterID, expectedIdentity: expectedIdentity,
            profile: profile, rank: rank, executionPlanSHA256: executionPlanSHA256,
            lifetimeDeadlineUptimeNanoseconds: lifetimeDeadlineUptimeNanoseconds, nativeKeyRelay: nativeKeyRelay)
    }

    public convenience init(configuration: ClusterSSHConfiguration, clusterID: String,
                            expectedIdentity: ClusterWorkerIdentity, profile: ClusterWorkerProfile, rank: Int,
                            executionPlanSHA256: String, lifetimeDeadlineUptimeNanoseconds: UInt64, bootstrapRelay: (any ClusterOwnerBootstrapExchange)? = nil,
                            dataPlaneTrust: Data? = nil) throws {
        try self.init(transport: configuration.launch(), clusterID: clusterID, expectedIdentity: expectedIdentity,
            profile: profile, rank: rank, executionPlanSHA256: executionPlanSHA256,
            lifetimeDeadlineUptimeNanoseconds: lifetimeDeadlineUptimeNanoseconds, bootstrapRelay: bootstrapRelay,
            dataPlaneTrust: dataPlaneTrust)
    }
    // Internal local-child seam exists solely for CPU service tests. Production
    // callers cannot substitute an arbitrary shell/transport through this API.
    init(transport: ClusterWorkerLaunch, clusterID: String, expectedIdentity: ClusterWorkerIdentity,
         profile: ClusterWorkerProfile, rank: Int, executionPlanSHA256: String,
         lifetimeDeadlineUptimeNanoseconds: UInt64, bootstrapRelay: (any ClusterOwnerBootstrapExchange)? = nil,
         nativeKeyRelay: ClusterOwnerNativeKeyRelay? = nil, dataPlaneTrust: Data? = nil,
         ownerRetirementAllowanceNanoseconds: UInt64 = ClusterRemoteWorkerEndpoint.standardOwnerRetirementAllowanceNanoseconds) throws {
        if let dataPlaneTrust {
            guard let trust = try? ClusterWorkerCodec.decodeDataPlaneTrust(dataPlaneTrust),
                  trust.membershipEpoch == expectedIdentity.membershipEpoch, trust.rank == rank else {
                throw OwnerWire.invalid("Data-plane credential differs from this endpoint's epoch or rank")
            }
        }
        self.dataPlaneTrust = dataPlaneTrust
        let ceiling = lifetimeDeadlineUptimeNanoseconds.addingReportingOverflow(ownerRetirementAllowanceNanoseconds)
        guard !ceiling.overflow, ownerRetirementAllowanceNanoseconds <= 300_000_000_000 else { throw OwnerWire.invalid("Invalid owner retirement allowance") }
        ownerRetirementAllowance = ownerRetirementAllowanceNanoseconds
        ownerCeiling = ceiling.partialValue
        self.nativeKeyRelay = nativeKeyRelay
        // Under the combined profile the relay holds this rank's committed
        // start, and the owner's lease is the one that start names.
        let relayStart = bootstrapRelay?.profile.carriesNativeStart == true ? bootstrapRelay?.nativeStart(rank: rank) : nil
        guard bootstrapRelay?.profile.carriesNativeStart != true
            || (relayStart?.rank == rank && relayStart?.common.epoch == expectedIdentity.membershipEpoch) else {
            throw OwnerWire.invalid("Bootstrap relay lacks this rank's committed native start")
        }
        self.relayStart = relayStart
        self.leaseID = nativeKeyRelay?.start.leaseID ?? relayStart?.leaseID ?? UUID()
        guard bootstrapRelay == nil || nativeKeyRelay == nil else { throw OwnerWire.invalid("Ambiguous bootstrap relay") }
        try nativeKeyRelay?.requireBinding(identity: expectedIdentity, rank: rank, plan: executionPlanSHA256)
        if let nativeKeyRelay {
            guard nativeKeyRelay.deadlineUptimeNanoseconds <= lifetimeDeadlineUptimeNanoseconds else { throw OwnerWire.invalid("Native key relay exceeds owner lifetime") }
        }
        _ = try ClusterOwnerBinding(clusterID: clusterID, ownerIncarnation: UUID(), leaseID: leaseID,
            identity: expectedIdentity, profile: profile, rank: rank, executionPlanSHA256: executionPlanSHA256)
        let now = DispatchTime.now().uptimeNanoseconds
        guard lifetimeDeadlineUptimeNanoseconds > now,
              lifetimeDeadlineUptimeNanoseconds - now <= ClusterWorkerLease.maximumNanoseconds else { throw OwnerWire.invalid("Invalid first lease grant") }
        if let bootstrapRelay {
            guard bootstrapRelay.identity == expectedIdentity, bootstrapRelay.executionPlanSHA256 == executionPlanSHA256,
                  bootstrapRelay.deadlineUptimeNanoseconds <= lifetimeDeadlineUptimeNanoseconds else { throw OwnerWire.invalid("Bootstrap relay configuration differs") }
        }
        self.bootstrapRelay = bootstrapRelay
        self.clusterID = clusterID; self.expectedIdentity = expectedIdentity; expectedProfile = profile; self.rank = rank
        self.executionPlanSHA256 = executionPlanSHA256; leaseDeadline = lifetimeDeadlineUptimeNanoseconds
        process.executableURL = transport.executable; process.arguments = transport.arguments; process.environment = transport.environment
        process.standardInput = input; process.standardOutput = output; process.standardError = diagnostics
        let pipe = try ClusterOwnerPipe(input: output.fileHandleForReading.fileDescriptor, output: input.fileHandleForWriting.fileDescriptor, readingCommands: false)
        let err = diagnostics.fileHandleForReading.fileDescriptor
        guard fcntl(err, F_SETFL, fcntl(err, F_GETFL) | O_NONBLOCK) == 0 else { throw OwnerWire.invalid("Cannot bound SSH diagnostics") }
        nativeEnded.enter(); ownerEnded.enter()
        do { try ownerExit.run(process) } catch { nativeEnded.leave(); ownerEnded.leave(); throw error }
        try? input.fileHandleForReading.close(); try? output.fileHandleForWriting.close(); try? diagnostics.fileHandleForWriting.close()
        // Every token's decision waits on this writer, so it runs at the
        // priority of the request it serves.
        DispatchQueue(label: "darkbloom.remote-owner.writer", qos: .userInteractive).async { self.writeLoop(pipe) }
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
        let (call, changed) = lock.withLock { () -> ((@Sendable () -> Void)?, Bool) in
            // Only a new failure or a new fence order gives the writer work;
            // the repeated calls after a lifetime expiry must not keep it awake.
            let changed = !invalid || (!cleanup && !fenceRequested)
            invalid = true; ready = nil; if !cleanup { fenceRequested = true }; return (notificationLocked(), changed)
        }
        bootstrapRelay?.cancel(); nativeKeyRelay?.cancel()
        if changed { writerWake.signal() }
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
        writerWake.signal()
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
    /// The rank lease is renewed only while this endpoint keeps the owner:
    /// after the hello, and never once it failed, fenced or saw cleanup.
    /// The caller holds lock.
    private var renewalCanBeSentLocked: Bool {
        !invalid && !cleanup && !fenceRequested && !releaseRequested && incarnation != nil
    }
    /// When an idle writer looks again: at the next renewal while one can
    /// still be sent, and never later than `writerIdleNanoseconds` from now.
    /// `nextRenewalAt` means nothing before the hello (it is zero) or after a
    /// fence, release or cleanup (it goes stale), so it is ignored then; an
    /// overdue renewal that can be sent is due now.
    static func writerWakeDeadline(now: UInt64, nextRenewalAt: UInt64, renewalCanBeSent: Bool) -> UInt64 {
        let idle = now.addingReportingOverflow(writerIdleNanoseconds)
        let latest = idle.overflow ? UInt64.max : idle.partialValue
        guard renewalCanBeSent else { return latest }
        return max(now, min(latest, nextRenewalAt))
    }
    private func writeLoop(_ pipe: ClusterOwnerPipe) {
        var sequence: UInt64 = 0
        do {
            let now = DispatchTime.now().uptimeNanoseconds
            let firstGrant = localLifetimeDeadlineUptimeNanoseconds
            guard now < firstGrant else { throw ClusterWorkerOwnerError.deadline }
            let offered = firstGrant - now
            lock.withLock { offeredLifetime = offered }
            let open = OwnerWire(kind: "open", epoch: expectedIdentity.membershipEpoch, lease: leaseID,
                incarnation: nil, sequence: 0, clusterID: clusterID, remaining: offered, bootstrapProfile: selectedBootstrapProfile,
                nativeStart: nativeKeyRelay?.start.canonicalBytes ?? relayStart?.canonicalBytes,
                nativeLocalDeadline: nativeKeyRelay == nil ? nil : min(firstGrant, nativeKeyRelay!.deadlineUptimeNanoseconds),
                dataPlaneTrust: dataPlaneTrust)
            try pipe.write(open.encoded(commandStream: true), until: min(firstGrant, now + 5_000_000_000)); sequence += 1
            var sentFence = false, sentRelease = false
            while process.isRunning {
                // Wakes from before this pass looked are answered by it. One
                // that arrives after the drain stays counted, so none is lost.
                while writerWake.wait(timeout: .now()) == .success {}
                let now = DispatchTime.now().uptimeNanoseconds
                if now >= localLifetimeDeadlineUptimeNanoseconds { fail() }
                let work = lock.withLock { () -> (UUID?, Bool, Bool, (ClusterWorkerCommandFrame, UInt64)?, (UInt64, Data)?, Bool) in
                    let bootstrap = !invalid && !bootstrapReplies.isEmpty ? bootstrapReplies.removeFirst() : nil
                    let renew = renewalCanBeSentLocked && now >= nextRenewalAt
                    let next = bootstrap == nil && !renew && !invalid && incarnation != nil && !outgoing.isEmpty ? outgoing.removeFirst() : nil
                    return (incarnation, fenceRequested && !cleanup, releaseRequested, next, bootstrap, renew)
                }
                var wrote = false
                if let incarnation = work.0 {
                    let frame: OwnerWire?
                    var writeDeadline = min(ownerRetirementDeadlineUptimeNanoseconds, now + 500_000_000)
                    if work.2 && !sentRelease {
                        frame = OwnerWire(kind: "release", epoch: expectedIdentity.membershipEpoch, lease: leaseID, incarnation: incarnation, sequence: sequence); sentRelease = true
                    } else if work.1 && !sentFence {
                        frame = OwnerWire(kind: "fence", epoch: expectedIdentity.membershipEpoch, lease: leaseID, incarnation: incarnation, sequence: sequence); sentFence = true
                    } else if work.5 {
                        var renewal = OwnerWire(kind: "renew", epoch: expectedIdentity.membershipEpoch, lease: leaseID,
                            incarnation: incarnation, sequence: sequence)
                        renewal.remaining = ClusterWorkerLease.ttlNanoseconds
                        frame = renewal
                        lock.withLock {
                            renewalsSent += 1; nextRenewalAt = now + ClusterWorkerLease.renewNanoseconds
                            leaseDeadline = max(leaseDeadline, now + ClusterWorkerLease.ttlNanoseconds)
                            // The owner's lease ends no later than the renewal's
                            // arrival plus the time to live, and so its ceiling.
                            let ceiling = (now + ClusterWorkerLease.ttlNanoseconds).addingReportingOverflow(ownerRetirementAllowance)
                            if !ceiling.overflow { ownerCeiling = max(ownerCeiling, ceiling.partialValue + 5_000_000_000) }
                        }
                    } else if let (round, bytes) = work.4 {
                        frame = OwnerWire(kind: "bootstrapReply", epoch: expectedIdentity.membershipEpoch,
                            lease: leaseID, incarnation: incarnation, sequence: sequence,
                            bootstrapSequence: round, bootstrapBytes: bytes)
                        writeDeadline = min(writeDeadline, selectedBootstrapDeadline!)
                    } else if let (command, deadline) = work.3 {
                        guard now < deadline else { throw ClusterWorkerOwnerError.deadline }
                        frame = try OwnerWire.command(command, lease: leaseID, incarnation: incarnation, sequence: sequence, now: now, deliveryDeadline: deadline)
                        writeDeadline = min(writeDeadline, deadline)
                    } else { frame = nil }
                    if let frame {
                        try pipe.write(frame.encoded(commandStream: true), until: writeDeadline)
                        sequence += 1; wrote = true
                    }
                }
                if lock.withLock({ ownerReleased }) { return }
                // A pass that wrote looks again at once: a renewal, a reply or
                // a fence may have held back a queued frame. Otherwise rest
                // until woken or until the next renewal is due.
                if wrote { continue }
                let wake = lock.withLock {
                    Self.writerWakeDeadline(now: DispatchTime.now().uptimeNanoseconds, nextRenewalAt: nextRenewalAt,
                        renewalCanBeSent: renewalCanBeSentLocked)
                }
                _ = writerWake.wait(timeout: .init(uptimeNanoseconds: wake))
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
            // A valid release ACK precedes normal owner return: the owner's
            // child is gone and its journal clear, so two seconds of exit grace
            // are enough. Without that ACK the owner may still be waiting for
            // its child; it keeps its whole retirement ceiling and is not
            // signalled before it. The closed command stream is its fence order.
            let released = lock.withLock { ownerReleased }
            if !released { pipe.closeOutput(); try? input.fileHandleForWriting.close() }
            let entered = DispatchTime.now().uptimeNanoseconds
            let patience = released ? entered + 2_000_000_000 : max(entered, ownerRetirementDeadlineUptimeNanoseconds)
            while process.isRunning && DispatchTime.now().uptimeNanoseconds < patience {
                // The owner may emit its final diagnostic after the released
                // ACK. Keep reading during the bounded exit grace. Unread owner
                // output is discarded so a waiting owner is never blocked on it.
                do { try diagnosticCapture.readAvailable(from: diagnostics.fileHandleForReading.fileDescriptor) } catch { fail() }
                if !released { pipe.discardAvailable() }
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning && !released {
                // Past its ceiling the owner is a control process with nothing
                // left to supervise in contract. SIGTERM first, then SIGKILL.
                process.terminate()
                let grace = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
                while process.isRunning && DispatchTime.now().uptimeNanoseconds < grace { Thread.sleep(forTimeInterval: 0.01) }
            }
            let limit = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            // The owner has exited or was just sent SIGKILL: its exit report
            // follows. As before this wait has no deadline of its own.
            ownerExit.wait()
            lock.withLock { ownerTerminationValue = process.terminationReason == .exit
                ? .exited(process.terminationStatus) : .signalled(process.terminationStatus) }
            diagnosticCapture.drain(diagnostics.fileHandleForReading.fileDescriptor, until: limit)
            try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close(); try? diagnostics.fileHandleForReading.close()
            ownerEnded.leave()
            // The owner, or the transport that carried its records, is gone:
            // no terminal record can reach this endpoint any more, so every
            // wait on it ends now. Nothing is claimed: `nativeCleanupObserved`
            // stays false and ownership stays unresolved (the device journal
            // keeps the record for `cluster recover`); the cause is named (S24).
            let unproven = lock.withLock { () -> Bool in
                guard !cleanup else { return false }
                if unresolvedText == nil {
                    unresolvedText = "no cleanup proof: its owner \(Self.describe(ownerTerminationValue)) before it published its worker's cleanup; ownership unresolved"
                }
                return true
            }
            if unproven { nativeEnded.leave() }
        }
        do {
            while true {
                let now = DispatchTime.now().uptimeNanoseconds
                if now >= localLifetimeDeadlineUptimeNanoseconds { fail() }
                // Keep listening for the terminal and the release ACK until the
                // owner's retirement ceiling: a child that ends itself at the
                // lifetime is reported after it, not before.
                if now >= ownerRetirementDeadlineUptimeNanoseconds { throw ClusterWorkerOwnerError.deadline }
                try diagnosticCapture.readAvailable(from: diagnostics.fileHandleForReading.fileDescriptor)
                // One pool per pass: this loop never returns to a run loop (see ClusterAutorelease).
                try ClusterAutorelease.drained {
                    if let bytes = try pipe.read(until: now + 50_000_000) { try accept(OwnerWire.decode(bytes, commandStream: false)) }
                }
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
                guard nextWireEvent == 0, incarnation == nil, frame.bootstrapProfile == selectedBootstrapProfile, let inc = frame.incarnation, let launch = frame.launchID else { throw OwnerWire.invalid("Repeated owner incarnation") }
                if let start = nativeKeyRelay?.start ?? relayStart {
                    guard inc == start.ownerIncarnation, launch == start.launchID else { throw OwnerWire.invalid("Committed native owner IDs differ") }
                }
                incarnation = inc; launchID = launch
                // The open was the first grant; renewals follow one interval on.
                nextRenewalAt = DispatchTime.now().uptimeNanoseconds + ClusterWorkerLease.renewNanoseconds
                // See ownerRetirementDeadlineUptimeNanoseconds: the owner's own
                // lifetime, and so its ceiling, ends no later than this.
                let latest = DispatchTime.now().uptimeNanoseconds.addingReportingOverflow(offeredLifetime)
                let ceiling = latest.partialValue.addingReportingOverflow(ownerRetirementAllowance)
                if !latest.overflow, !ceiling.overflow { ownerCeiling = max(ownerCeiling, ceiling.partialValue) }
            } else {
                guard incarnation != nil, frame.incarnation == incarnation else { throw OwnerWire.invalid("Remote incarnation differs") }
                switch frame.kind {
                case "bootstrapRound":
                    guard let selectedBootstrapProfile, ready == nil, !cleanup,
                          frame.bootstrapSequence == nextBootstrapSequence, let bytes = frame.bootstrapBytes else {
                        throw OwnerWire.invalid("Unexpected bootstrap round")
                    }
                    try selectedBootstrapProfile.validate(sequence: nextBootstrapSequence, contribution: bytes)
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
                        guard nativeKeyRelay == nil, nextNativeEvent == 0, bootstrapRelay.map({ nextBootstrapSequence == UInt64($0.profile.rounds) }) ?? true,
                              value.identity == expectedIdentity, value.profile == expectedProfile,
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
                    let gathered: Data
                    if let nativeKeyRelay = self.nativeKeyRelay { gathered = try nativeKeyRelay.exchange(sequence: sequence, bytes: bytes) }
                    else { gathered = try self.bootstrapRelay!.exchange(binding: binding, sequence: sequence, contribution: bytes) }
                    try self.lock.withLock {
                        guard !self.invalid, !self.cleanup, self.bootstrapReplies.isEmpty else { throw OwnerWire.invalid("Bootstrap reply queue unavailable") }
                        self.bootstrapReplies.append((sequence, gathered)); self.nextBootstrapSequence += 1; self.bootstrapBusy = false
                    }
                    self.writerWake.signal()
                } catch { self.fail() }
            }
        }
        if complete { nativeEnded.leave() }
        if complete || invalidateEvent { fail() }
        // The hello starts renewals and lets queued commands go out; a
        // terminal asks for the release; a release ACK ends the writer.
        writerWake.signal()
        arrivals.signal()
    }
}
