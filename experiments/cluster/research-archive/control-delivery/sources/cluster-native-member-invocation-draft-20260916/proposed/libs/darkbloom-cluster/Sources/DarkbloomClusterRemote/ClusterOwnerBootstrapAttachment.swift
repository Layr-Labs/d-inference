import Foundation
import Darwin
import DarkbloomClusterBootstrap
import DarkbloomClusterProcess
import DarkbloomClusterSecurity

/// Created before the configured native child. Only this local triple contains
/// uptime; the authenticated owner wire never forwards it to another Mac.
public final class ClusterOwnerBootstrapAttachment: @unchecked Sendable {
    public let profile: ClusterOwnerBootstrapProfile
    public let deadlineUptimeNanoseconds: UInt64
    public let nativeStart: ClusterNativeAuthorizationStart?
    private let listener: ClusterBootstrapListener
    private let condition = NSCondition()
    private var connection: ClusterBootstrapConnection?
    private var pending: ClusterBootstrapRound?
    private var reply: Data?
    private var failed = false
    private var completed = false

    init(profile: ClusterOwnerBootstrapProfile, deadline: UInt64, nativeStart: ClusterNativeAuthorizationStart? = nil) throws {
        guard (profile == .nativeKeyPrelude) == (nativeStart != nil) else { throw OwnerWire.invalid("Native prelude profile/start differs") }
        self.nativeStart = nativeStart
        self.profile = profile; deadlineUptimeNanoseconds = deadline
        listener = try .init(deadlineUptimeNanoseconds: deadline)
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
        if profile == .mesh2 {
            let start = pending.identity.rank * pending.contribution.count
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
        let round = try ClusterBootstrapRound(identity: identity, sequence: sequence, contribution: bytes)
        condition.lock(); pending = round; reply = nil; condition.unlock()
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
            let connection = try listener.accept(processID: pid,
                identity: .init(membershipEpoch: binding.identity.membershipEpoch, rank: binding.rank),
                deadlineUptimeNanoseconds: deadlineUptimeNanoseconds,
                mode: profile == .mesh2 ? .mesh2 : .nativeKeyPreludeV1)
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
                // The key-only native fixture acknowledges that it retained the
                // confirmed authority before exiting. This is not an RDMA mesh
                // round or a model Ready receipt; it prevents EOF racing the
                // owner's final public publication.
                let receipt = try connection.receiveRound()
                let marker = Data("native-key-prelude-complete-v1".utf8)
                guard receipt.sequence == 0, receipt.contribution == marker else { throw OwnerWire.invalid("Native key-only completion marker differs") }
                try connection.reply(to: receipt, gathered: marker + marker)
            } else { for expected in 0..<profile.rounds {
                let round = try connection.receiveRound()
                guard round.sequence == UInt64(expected) else { throw OwnerWire.invalid("Bootstrap local sequence differs") }
                try profile.validate(sequence: round.sequence, contribution: round.contribution)
                condition.lock(); pending = round; reply = nil; condition.unlock()
                try publish(round.sequence, round.contribution)
                condition.lock()
                while !failed && reply == nil && DispatchTime.now().uptimeNanoseconds < deadlineUptimeNanoseconds {
                    _ = condition.wait(until: Date(timeIntervalSinceNow: 0.02))
                }
                let value = reply; let valid = !failed; condition.unlock()
                guard valid, let value else { throw ClusterWorkerOwnerErrorProxy.deadline }
                try connection.reply(to: round, gathered: value)
                condition.lock(); pending = nil; reply = nil; condition.unlock()
            }
            }
            condition.lock(); completed = true; condition.broadcast(); condition.unlock()
            // Initialization rounds are complete, not proof of native retirement.
            connection.cancel()
        } catch { cancel(); throw error }
    }
}
