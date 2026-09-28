import Foundation
import Darwin
import DarkbloomClusterBootstrap
import DarkbloomClusterProcess

/// Created before the configured native child. Only this local triple contains
/// uptime; the authenticated owner wire never forwards it to another Mac.
public final class ClusterOwnerBootstrapAttachment: @unchecked Sendable {
    public let profile: ClusterOwnerBootstrapProfile
    public let deadlineUptimeNanoseconds: UInt64
    private let listener: ClusterBootstrapListener
    private let condition = NSCondition()
    private var connection: ClusterBootstrapConnection?
    private var pending: ClusterBootstrapRound?
    private var reply: Data?
    private var failed = false
    private var completed = false

    init(profile: ClusterOwnerBootstrapProfile, deadline: UInt64) throws {
        self.profile = profile; deadlineUptimeNanoseconds = deadline
        listener = try .init(deadlineUptimeNanoseconds: deadline)
    }
    public var workerArguments: [String] {
        ["--bootstrap-socket-path", listener.socketPath, "--bootstrap-owner-pid", String(getpid()),
         "--bootstrap-deadline-uptime-nanoseconds", String(deadlineUptimeNanoseconds)]
    }
    func cancel() {
        condition.lock(); failed = true; let value = connection; condition.broadcast(); condition.unlock()
        listener.cancel(); value?.cancel()
    }
    func acceptReply(sequence: UInt64, bytes: Data) throws {
        condition.lock(); defer { condition.unlock() }
        guard !failed, let pending, pending.sequence == sequence, reply == nil,
              bytes.count == pending.contribution.count * 2 else { throw OwnerWire.invalid("Unexpected bootstrap reply") }
        let start = pending.identity.rank * pending.contribution.count
        guard Data(bytes.dropFirst(start).prefix(pending.contribution.count)) == pending.contribution else { throw OwnerWire.invalid("Bootstrap reply changed local contribution") }
        // Check both native scalar rows before they can influence allocation.
        for rank in 0..<2 { try profile.validate(sequence: sequence, contribution: Data(bytes.dropFirst(rank * pending.contribution.count).prefix(pending.contribution.count))) }
        reply = bytes; condition.broadcast()
    }
    func requireCompleted() throws {
        condition.lock(); defer { condition.unlock() }
        while !failed && !completed && DispatchTime.now().uptimeNanoseconds < deadlineUptimeNanoseconds {
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.02))
        }
        guard completed && !failed else { throw OwnerWire.invalid("Native readiness precedes authenticated bootstrap completion") }
    }
    func run(child: ClusterWorkerProcess, binding: ClusterOwnerBinding,
             publish: @Sendable (UInt64, Data) throws -> Void) throws {
        do {
            guard let pid = child.launchedProcessIdentifier else { throw OwnerWire.invalid("Bootstrap lacks actual child PID") }
            let connection = try listener.accept(processID: pid,
                identity: .init(membershipEpoch: binding.identity.membershipEpoch, rank: binding.rank),
                deadlineUptimeNanoseconds: deadlineUptimeNanoseconds)
            condition.lock()
            guard !failed else { condition.unlock(); connection.cancel(); throw ClusterBootstrapError.closed }
            self.connection = connection; condition.unlock()
            for expected in 0..<profile.rounds {
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
            condition.lock(); completed = true; condition.broadcast(); condition.unlock()
            // Initialization rounds are complete, not proof of native retirement.
            connection.cancel()
        } catch { cancel(); throw error }
    }
}
