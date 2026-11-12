import Foundation
import CryptoKit
import DarkbloomClusterRemote
import DarkbloomClusterSecurity

/// One actual committed owner obligation. Cancellation interrupts waits and
/// requests native cleanup immediately; only observed owner proof permits release.
final class NativePairMemberSession: @unchecked Sendable {
    let start: ClusterNativeAuthorizationStart
    let epoch: String
    let generation: UInt64
    let prepareDeadline, lifetimeDeadline, cleanupDeadline: UInt64
    let prepareUnixNanoseconds, expiresUnixNanoseconds: Int64
    private let cancellationPublication = DispatchGroup()
    let connection: NativePairMemberConnection
    private let installation: NativePairMemberInstallation
    private let condition = NSCondition()
    private var stopped = false, committed = false, launched = false
    private var peerBinding: Data?, peerConfirmation: Data?
    private var nextRound: UInt64 = 0
    private var endpoint: ClusterRemoteWorkerEndpoint?
    private var timer: DispatchSourceTimer?
    private var outcome: String = "preparing"
    private let onFinished: @Sendable (NativePairMemberSession, Bool) -> Void
    var status: String { condition.lock(); defer { condition.unlock() }; return outcome }
    init(installation: NativePairMemberInstallation, connection: NativePairMemberConnection,
         message: NativePairMessage, receivedAt: UInt64, wallUnixNanoseconds: Int64,
         onFinished: @escaping @Sendable (NativePairMemberSession, Bool) -> Void) throws {
        let (policy, start) = try NativePairMemberPolicy.preparation(Data(base64Encoded: message.payload)!)
        guard policy.bytes == installation.policy.bytes, start.rank == installation.rank,
              NativePairMemberInstallation.hex(Self.uuidBytes(start.common.epoch)) == message.epoch,
              start.common.membershipGeneration == message.generation,
              let prepare = message.prepareBeforeUnixNano, let expires = message.expiresAtUnixNano,
              wallUnixNanoseconds > 0, prepare > wallUnixNanoseconds, expires > prepare, UInt64(expires) < policy.notAfter else { throw NativePairMemberError.binding }
        // Anchor once on receipt; later start/hello/binding never restart a timer.
        let prepDelta = UInt64(prepare - wallUnixNanoseconds), lifetimeDelta = UInt64(expires - wallUnixNanoseconds)
        guard prepDelta <= 30_000_000_000, lifetimeDelta <= 900_000_000_000,
              receivedAt <= UInt64.max - lifetimeDelta else { throw NativePairMemberError.deadline }
        let cleanup = (receivedAt + lifetimeDelta).addingReportingOverflow(3_000_000_000)
        guard !cleanup.overflow else { throw NativePairMemberError.deadline }
        self.installation = installation; self.connection = connection; self.start = start
        epoch = message.epoch; generation = message.generation
        prepareDeadline = receivedAt + prepDelta; lifetimeDeadline = receivedAt + lifetimeDelta
        cleanupDeadline = cleanup.partialValue
        prepareUnixNanoseconds = prepare; expiresUnixNanoseconds = expires
        self.onFinished = onFinished
    }
    func run() {
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .init(uptimeNanoseconds: lifetimeDeadline))
        timer.setEventHandler { [weak self] in self?.cancel(notify: true) }
        condition.lock(); self.timer = timer; condition.unlock()
        timer.resume()
        DispatchQueue(label: "darkbloom.native-member.owner").async { self.runOwned() }
    }
    func accept(_ message: NativePairMessage, receivedAt: UInt64 = DispatchTime.now().uptimeNanoseconds) throws {
        let payload = Data(base64Encoded: message.payload)!
        condition.lock(); defer { condition.unlock() }
        guard message.epoch == epoch, message.generation == generation,
              message.prepareBeforeUnixNano == prepareUnixNanoseconds, message.expiresAtUnixNano == expiresUnixNanoseconds,
              !stopped, DispatchTime.now().uptimeNanoseconds < lifetimeDeadline else { throw NativePairMemberError.inactive }
        switch message.type {
        case "native_pair_owner_start":
            guard !committed, outcome == "prepared", receivedAt < prepareDeadline,
                  payload == start.canonicalBytes else { throw NativePairMemberError.binding }
            committed = true; outcome = "committed"
        case "native_pair_binding":
            guard committed, nextRound == 0, peerBinding == nil else { throw NativePairMemberError.binding }
            let value = try ClusterNativeKeyBinding(encoded: payload)
            guard value.hellos[start.rank].start.canonicalBytes == start.canonicalBytes else { throw NativePairMemberError.binding }
            peerBinding = payload
        case "native_pair_peer_confirmation":
            guard committed, peerBinding != nil, nextRound <= 1, peerConfirmation == nil, payload.count == 32 else { throw NativePairMemberError.binding }
            peerConfirmation = payload
        default: throw NativePairMemberError.binding
        }
        condition.broadcast()
    }
    func cancel(notify: Bool) {
        condition.lock()
        if stopped || outcome == "released" || outcome == "releasing" { condition.unlock(); return }
        stopped = true; if outcome != "released" { outcome = committed ? "quarantined" : "cancelled" }
        if notify { cancellationPublication.enter() }
        let endpoint = endpoint; condition.broadcast(); condition.unlock()
        endpoint?.requestNativeCleanup() // Independent of SE signing and WebSocket writes.
        if notify { DispatchQueue.global().async {
            defer { self.cancellationPublication.leave() }
            try? self.send("native_pair_cancel", Data([68, 66, 78, 67, 1]), cleanup: true)
        } }
    }
    private func send(_ type: String, _ payload: Data, cleanup: Bool = false) throws {
        let now = DispatchTime.now().uptimeNanoseconds
        let end = cleanup ? cleanupDeadline : lifetimeDeadline
        let sendLimit = now.addingReportingOverflow(500_000_000)
        try connection.send(type: type, epoch: epoch, generation: generation, payload: payload,
            until: min(end, sendLimit.overflow ? end : sendLimit.partialValue))
    }
    private func requireLive() throws {
        guard !stopped, connection.isLive, DispatchTime.now().uptimeNanoseconds < lifetimeDeadline else { throw NativePairMemberError.inactive }
    }
    private func runOwned() {
        var clean = false
        do {
            let pins = try installation.prepare(start: start, deadline: prepareDeadline)
            condition.lock()
            do { try requireLive(); guard DispatchTime.now().uptimeNanoseconds < prepareDeadline else { throw NativePairMemberError.deadline } }
            catch { condition.unlock(); throw error }
            outcome = "prepared"; condition.unlock()
            try send("native_pair_prepared", start.canonicalBytes)
            condition.lock()
            while !stopped && !committed && DispatchTime.now().uptimeNanoseconds < prepareDeadline {
                _ = condition.wait(until: Date(timeIntervalSinceNow: 0.02))
            }
            let mayLaunch = !stopped && committed && connection.isLive && DispatchTime.now().uptimeNanoseconds < prepareDeadline; condition.unlock()
            guard mayLaunch else { throw NativePairMemberError.deadline }
            for pin in pins { try pin.requireUnchanged() }
            let relay = try ClusterOwnerNativeKeyRelay(start: start, deadlineUptimeNanoseconds: lifetimeDeadline,
                exchange: { [weak self] round, bytes in
                    guard let self else { throw NativePairMemberError.inactive }; return try self.exchange(round, bytes)
                }, cancel: { [weak self] in self?.ownerInvalidated() })
            // The committed obligation is retained even if launch throws or a
            // concurrent cancel wins between this check and actual Process.run.
            condition.lock(); let allowed = !stopped && committed; condition.unlock()
            guard allowed else { throw NativePairMemberError.inactive }
            let created = try installation.launch(start: start, until: lifetimeDeadline, relay: relay)
            condition.lock(); endpoint = created; launched = true; let cancelled = stopped; condition.unlock()
            if cancelled { created.requestNativeCleanup() }
            clean = created.waitForOwnerReleased(deadline: cleanupDeadline)
            guard clean, created.nativeCleanupObserved, created.ownerDeviceLeaseReleasedObserved,
                  created.ownerTermination == .exited(0) else { throw NativePairMemberError.inactive }
            condition.lock(); outcome = "releasing"; condition.unlock()
            guard cancellationPublication.wait(timeout: .init(uptimeNanoseconds: cleanupDeadline)) == .success else { throw NativePairMemberError.deadline }
            var receipt = Data([68, 66, 78, 82, 1]); receipt.append(contentsOf: SHA256.hash(data: start.canonicalBytes)); receipt.append(contentsOf: [1, 1, 1])
            try send("native_pair_owner_released", receipt, cleanup: true)
            condition.lock(); outcome = "released"; condition.unlock()
        } catch {
            cancel(notify: true)
            condition.lock(); if outcome != "released" { outcome = committed ? "quarantined" : "cancelled" }; condition.unlock()
        }
        let cancelJoined = cancellationPublication.wait(timeout: .init(uptimeNanoseconds: cleanupDeadline)) == .success
        condition.lock()
        let reusable = cancelJoined && ((!committed && !launched) || (clean && outcome == "released"))
        timer?.cancel(); timer = nil
        condition.unlock()
        onFinished(self, reusable)
    }
    private func ownerInvalidated() {
        condition.lock(); let completedPrelude = nextRound == 3; condition.unlock()
        if !completedPrelude { cancel(notify: true) }
    }
    private func exchange(_ round: UInt64, _ bytes: Data) throws -> Data {
        condition.lock()
        do { try requireLive(); guard committed, round == nextRound else { throw NativePairMemberError.binding } }
        catch { condition.unlock(); throw error }
        condition.unlock()
        if round == 0 {
            let hello = try ClusterNativeKeyHello(encoded: bytes)
            guard hello.start.canonicalBytes == start.canonicalBytes else { throw NativePairMemberError.binding }
            try send("native_pair_hello", bytes)
        } else if round == 1 { try send("native_pair_confirmation", bytes) }
        condition.lock(); defer { condition.unlock() }
        while !stopped && ((round == 0 && peerBinding == nil) || (round == 1 && peerConfirmation == nil)) && DispatchTime.now().uptimeNanoseconds < lifetimeDeadline {
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.02))
        }
        try requireLive()
        let result: Data
        switch round {
        case 0:
            guard let peerBinding else { throw NativePairMemberError.deadline }
            let binding = try ClusterNativeKeyBinding(encoded: peerBinding)
            guard binding.hellos[start.rank].canonicalBytes == bytes else { throw NativePairMemberError.binding }
            result = peerBinding
        case 1: guard let peerConfirmation else { throw NativePairMemberError.deadline }; result = peerConfirmation
        case 2:
            guard let peerBinding, try ClusterNativeKeyBinding(encoded: peerBinding).transcriptSHA256 == bytes else { throw NativePairMemberError.binding }
            outcome = "native-confirmation-observed"; result = bytes
        default: throw NativePairMemberError.binding
        }
        nextRound += 1; return result
    }
    private static func uuidBytes(_ value: UUID) -> Data { withUnsafeBytes(of: value.uuid) { Data($0) } }
}
