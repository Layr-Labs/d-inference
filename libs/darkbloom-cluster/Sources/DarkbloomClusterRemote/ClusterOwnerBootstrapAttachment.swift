import Foundation
import Darwin
import DarkbloomClusterBootstrap
import DarkbloomClusterProcess
import DarkbloomClusterProtocol
import DarkbloomClusterSecurity

/// Created before the configured native child. Only this local triple contains
/// uptime; the authenticated owner wire never forwards it to another Mac.
public final class ClusterOwnerBootstrapAttachment: @unchecked Sendable {
    public static let maximumBootstrapNanoseconds = ClusterBootstrapListener.maximumLifetimeNanoseconds
    /// The exact finite child lifetime, independently of the bounded bootstrap socket.
    public let calibrationExperimentDeadline: UInt64
    public let profile: ClusterOwnerBootstrapProfile
    public let deadlineUptimeNanoseconds: UInt64
    public let nativeStart: ClusterNativeAuthorizationStart?
    private let listener: ClusterBootstrapListener
    private let condition = NSCondition()
    private var connection: ClusterBootstrapConnection?
    /// The round published and awaiting its reply, by wire sequence.
    private var pending: (sequence: UInt64, contribution: Data, rank: Int)?
    private var reply: Data?
    private var failed = false
    private var completed = false

    init(profile: ClusterOwnerBootstrapProfile, deadline: UInt64, nativeStart: ClusterNativeAuthorizationStart? = nil,
         experimentDeadline: UInt64? = nil) throws {
        guard profile.carriesNativeStart == (nativeStart != nil) else { throw OwnerWire.invalid("Native prelude profile/start differs") }
        let experiment = experimentDeadline ?? deadline
        let now = DispatchTime.now().uptimeNanoseconds
        guard experiment >= deadline, experiment > now,
              experiment - now <= ClusterWorkerLimits.deadlineNanoseconds else {
            throw OwnerWire.invalid("Calibration experiment deadline differs from bounded bootstrap")
        }
        calibrationExperimentDeadline = experiment
        self.nativeStart = nativeStart
        self.profile = profile; deadlineUptimeNanoseconds = deadline
        listener = try .init(deadlineUptimeNanoseconds: deadline)
    }
    /// Private calibration uses the same authenticated socket/profile, but
    /// consumes no READY. No public raw-PID acceptance API is exposed.
    public static func calibration(profile: ClusterOwnerBootstrapProfile, deadline: UInt64,
                                   experimentDeadline: UInt64? = nil,
                                   nativeStart: ClusterNativeAuthorizationStart? = nil) throws -> ClusterOwnerBootstrapAttachment {
        try .init(profile: profile, deadline: deadline, nativeStart: nativeStart,
                  experimentDeadline: experimentDeadline)
    }
    public func cancelCalibration() {
        condition.lock(); let child = calibrationChild; condition.unlock()
        cancel(); child?.cancel()
    }
    public func acceptCalibrationReply(sequence: UInt64, bytes: Data) throws {
        try acceptReply(sequence: sequence, bytes: bytes)
    }
    public func requireCalibrationCompleted() throws { try requireCompleted() }
    private var calibrationStarted = false
    private var calibrationChild: ClusterCalibrationProcess?
    public func runCalibration(child: ClusterCalibrationProcess, binding: ClusterOwnerBinding,
                               publish: @Sendable (UInt64, Data) throws -> Void) throws {
        guard child.expectedIdentity == binding.identity, child.rank == binding.rank,
              child.expectedProfile == binding.profile, child.executionPlanSHA256 == binding.executionPlanSHA256,
              child.experimentDeadline == calibrationExperimentDeadline,
              !child.observedExit, child.fault == nil, let pid = child.launchedProcessIdentifier else {
            throw OwnerWire.invalid("Calibration bootstrap differs from actual child binding")
        }
        condition.lock()
        guard !calibrationStarted, !failed else { condition.unlock(); throw ClusterBootstrapError.closed }
        calibrationStarted = true; calibrationChild = child; condition.unlock()
        // A timed-out caller may drop its reference. Keep both owners alive
        // until the direct-child supervisor actually observes exit, even if
        // cancellation has already closed the bootstrap socket.
        Task { [self, child] in
            _ = await child.waitUntilExited()
            clearExitedCalibrationChild()
            withExtendedLifetime(self) {}
        }
        do { try runOwnedChild(processID: pid, binding: binding, publish: publish) }
        catch { child.cancel(); throw error }
    }
    private func clearExitedCalibrationChild() {
        condition.lock(); defer { condition.unlock() }
        if calibrationChild?.observedExit == true { calibrationChild = nil }
    }
    public var workerArguments: [String] {
        ["--bootstrap-socket-path", listener.socketPath, "--bootstrap-owner-pid", String(getpid()),
         "--bootstrap-deadline-uptime-nanoseconds", String(deadlineUptimeNanoseconds)]
        + (nativeStart.map { ["--native-authorization-start-base64", $0.canonicalBytes.base64EncodedString()] } ?? [])
    }
    func cancel() {
        condition.lock(); failed = true; let value = connection; condition.broadcast(); condition.unlock()
        listener.cancel(); value?.cancel()
    }
    func acceptReply(sequence: UInt64, bytes: Data) throws {
        condition.lock(); defer { condition.unlock() }
        guard !failed, let pending, pending.sequence == sequence, reply == nil,
              bytes.count <= 131_072 else { throw OwnerWire.invalid("Unexpected bootstrap reply") }
        try profile.validateReply(sequence: sequence, contribution: pending.contribution, reply: bytes)
        if !profile.isPrelude(sequence) {
            let start = pending.rank * pending.contribution.count
            guard Data(bytes.dropFirst(start).prefix(pending.contribution.count)) == pending.contribution else { throw OwnerWire.invalid("Bootstrap reply changed local contribution") }
        }
        reply = bytes; condition.broadcast()
    }
    func requireCompleted() throws {
        condition.lock(); defer { condition.unlock() }
        while !failed && !completed && DispatchTime.now().uptimeNanoseconds < deadlineUptimeNanoseconds {
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.02))
        }
        guard completed && !failed else { throw OwnerWire.invalid("Native readiness precedes authenticated bootstrap completion") }
    }
    private func exchangePublic(sequence: UInt64, bytes: Data, identity: ClusterBootstrapIdentity,
                                publish: @Sendable (UInt64, Data) throws -> Void) throws -> Data {
        try profile.validate(sequence: sequence, contribution: bytes)
        condition.lock(); pending = (sequence, bytes, identity.rank); reply = nil; condition.unlock()
        try publish(sequence, bytes)
        condition.lock()
        while !failed && reply == nil && DispatchTime.now().uptimeNanoseconds < deadlineUptimeNanoseconds {
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.02))
        }
        let value = reply; let valid = !failed; pending = nil; reply = nil; condition.unlock()
        guard valid, let value else { throw ClusterWorkerOwnerErrorProxy.deadline }
        return value
    }
    func run(child: ClusterWorkerProcess, binding: ClusterOwnerBinding,
             publish: @Sendable (UInt64, Data) throws -> Void) throws {
        do {
            guard let pid = child.launchedProcessIdentifier else { throw OwnerWire.invalid("Bootstrap lacks actual child PID") }
            try runOwnedChild(processID: pid, binding: binding, publish: publish)
        } catch { cancel(); throw error }
    }
    private func runOwnedChild(processID: Int32, binding: ClusterOwnerBinding,
                               publish: @Sendable (UInt64, Data) throws -> Void) throws {
        do {
            let connection = try listener.accept(processID: processID,
                identity: .init(membershipEpoch: binding.identity.membershipEpoch, rank: binding.rank),
                deadlineUptimeNanoseconds: deadlineUptimeNanoseconds,
                mode: profile.carriesNativeStart ? .nativeKeyPreludeV1 : .mesh2)
            condition.lock()
            guard !failed else { condition.unlock(); connection.cancel(); throw ClusterBootstrapError.closed }
            self.connection = connection; condition.unlock()
            if let nativeStart {
                guard nativeStart.common.epoch == binding.identity.membershipEpoch,
                      nativeStart.rank == binding.rank, nativeStart.ownerIncarnation == binding.route.ownerIncarnation,
                      nativeStart.leaseID == binding.route.leaseID else { throw OwnerWire.invalid("Owned native start binding differs") }
                let context = try connection.beginOwnerKeyPrelude(start: nativeStart.canonicalBytes)
                let hello = try context.receiveHello()
                let bindingBytes = try exchangePublic(sequence: 0, bytes: hello, identity: connection.identity, publish: publish)
                let accepted = try ClusterNativeKeyBinding(encoded: bindingBytes)
                try context.sendBinding(bindingBytes)
                let confirmation = try context.receiveConfirmation()
                try context.sendPeerConfirmation(exchangePublic(sequence: 1, bytes: confirmation, identity: connection.identity, publish: publish))
                try context.requireComplete(transcriptSHA256: accepted.transcriptSHA256)
                _ = try exchangePublic(sequence: 2, bytes: accepted.transcriptSHA256, identity: connection.identity, publish: publish)
                if profile == .nativeKeyPrelude {
                    // The key-only native fixture acknowledges that it retained the
                    // confirmed authority before exiting. This is not an RDMA mesh
                    // round or a model Ready receipt; it prevents EOF racing the
                    // owner's final public publication.
                    let receipt = try connection.receiveRound()
                    let marker = Data("native-key-prelude-complete-v1".utf8)
                    guard receipt.sequence == 0, receipt.contribution == marker else { throw OwnerWire.invalid("Native key-only completion marker differs") }
                    try connection.reply(to: receipt, gathered: marker + marker)
                }
            }
            // The mesh rounds follow the prelude on the same connection; the
            // child numbers them from 0, the wire after the prelude's rounds.
            for expected in 0..<profile.meshRounds {
                let round = try connection.receiveRound()
                guard round.sequence == UInt64(expected) else { throw OwnerWire.invalid("Bootstrap local sequence differs") }
                let wire = profile.wireSequence(meshRound: round.sequence)
                try profile.validate(sequence: wire, contribution: round.contribution)
                condition.lock(); pending = (wire, round.contribution, round.identity.rank); reply = nil; condition.unlock()
                try publish(wire, round.contribution)
                condition.lock()
                while !failed && reply == nil && DispatchTime.now().uptimeNanoseconds < deadlineUptimeNanoseconds {
                    _ = condition.wait(until: Date(timeIntervalSinceNow: 0.02))
                }
                let value = reply; let valid = !failed; condition.unlock()
                guard valid, let value else { throw ClusterWorkerOwnerErrorProxy.deadline }
                try connection.reply(to: round, gathered: value)
                condition.lock(); pending = nil; reply = nil; condition.unlock()
            }
            condition.lock(); completed = true; condition.broadcast(); condition.unlock()
            // Initialization rounds are complete, not proof of native retirement.
            connection.cancel()
        } catch { cancel(); throw error }
    }
}
