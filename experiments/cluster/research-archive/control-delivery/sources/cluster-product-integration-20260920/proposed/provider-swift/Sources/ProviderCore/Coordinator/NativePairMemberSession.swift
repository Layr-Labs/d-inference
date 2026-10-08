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
    let completion = NativePairSessionCompletionSignal()
    let connection: NativePairMemberConnection
    private let installation: NativePairMemberInstallation
    private let condition = NSCondition()
    private var stopped = false, committed = false, launched = false
    private var peerBinding: Data?, peerConfirmation: Data?
    private var keyConfirmationSent = false, meshReady = false
    private var meshContribution: Data?, meshReply: Data?
    private var combinedMesh: Bool { installation.bootstrapProfile == .nativeKeyPreludeMesh2 }
    private var nextRound: UInt64 = 0
    private var endpoint: ClusterRemoteWorkerEndpoint?
    private var requests: NativePairRequestBridge?
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
        guard installation.protectedRuntime == nil || lifetimeDelta <= 300_000_000_000 else {throw NativePairMemberError.deadline}
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
        if message.type == "native_pair_workers_released" {
            try acceptAllWorkersReleased(message, payload: payload); return
        }
        if ["native_pair_worker_ready", "native_pair_worker_command", "native_pair_worker_event"].contains(message.type) {
            condition.lock()
            let current=requests
            let allowed = !stopped && committed && nextRound==7 && message.epoch==epoch && message.generation==generation
                && message.prepareBeforeUnixNano==prepareUnixNanoseconds && message.expiresAtUnixNano==expiresUnixNanoseconds
            condition.unlock()
            guard allowed, let current else {throw NativePairMemberError.inactive}
            try current.receive(message);return
        }
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
        case "native_pair_mesh_ready":
            guard combinedMesh, committed, nextRound == 2, keyConfirmationSent, !meshReady,
                  let peerBinding, payload == (try NativePairMesh.keyConfirmed(ClusterNativeKeyBinding(encoded: peerBinding).transcriptSHA256)) else { throw NativePairMemberError.binding }
            meshReady = true
        case "native_pair_mesh_reply":
            guard combinedMesh, committed, meshReady, (3...6).contains(nextRound),
                  let meshContribution, meshReply == nil, let peerBinding else { throw NativePairMemberError.binding }
            let digest = try ClusterNativeKeyBinding(encoded: peerBinding).transcriptSHA256
            let gathered = try NativePairMesh.decode(payload, transcript: digest, rank: start.rank,
                round: UInt8(nextRound - 3), reply: true)
            guard Data(gathered.dropFirst(start.rank * meshContribution.count).prefix(meshContribution.count)) == meshContribution else { throw NativePairMemberError.binding }
            meshReply = gathered
        default: throw NativePairMemberError.binding
        }
        condition.broadcast()
    }
    func cancel(notify: Bool) {
        condition.lock()
        if stopped || outcome == "released" || outcome == "releasing" { condition.unlock(); return }
        stopped = true; if outcome != "released" { outcome = committed ? "quarantined" : "cancelled" }
        if notify { cancellationPublication.enter() }
        let endpoint = endpoint, requests = requests; condition.broadcast(); condition.unlock()
        requests?.invalidate()
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
        var requestTransportJoined = false, localReleasePublished = false
        var requestViewsReleased = installation.protectedRuntime == nil
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
            let relay = try ClusterOwnerNativeKeyRelay(start: start, deadlineUptimeNanoseconds: lifetimeDeadline, profile: installation.bootstrapProfile,
                exchange: { [weak self] round, bytes in
                    guard let self else { throw NativePairMemberError.inactive }; return try self.exchange(round, bytes)
                }, cancel: { [weak self] in self?.ownerInvalidated() })
            // The committed obligation is retained even if launch throws or a
            // concurrent cancel wins between this check and actual Process.run.
            condition.lock(); let allowed = !stopped && committed; condition.unlock()
            guard allowed else { throw NativePairMemberError.inactive }
            if installation.protectedRuntime != nil {
                var attachment=Data([68,66,78,88,1]);attachment.append(contentsOf:SHA256.hash(data:start.canonicalBytes))
                try send("native_pair_worker_attach",attachment)
            }
            let created = try installation.launch(start: start, until: lifetimeDeadline, relay: relay)
            condition.lock();endpoint=created;launched=true;let cancelledBeforeBridge=stopped;condition.unlock()
            if cancelledBeforeBridge {created.requestNativeCleanup()}
            let bridge: NativePairRequestBridge?
            if installation.protectedRuntime != nil {
                bridge=try NativePairRequestBridge(endpoint:created,installation:installation,start:start,
                    lifetime:lifetimeDeadline,cleanupDeadline:cleanupDeadline,
                    context:{[weak self] in guard let self else {throw NativePairMemberError.inactive};return try self.requestBinding()},
                    send:{[weak self] packet,deadline in
                        guard let self else {throw NativePairMemberError.inactive}
                        let bound=DispatchTime.now().uptimeNanoseconds.addingReportingOverflow(500_000_000)
                        guard !bound.overflow else {throw NativePairMemberError.deadline}
                        try self.connection.send(type:packet.kind.messageType,epoch:self.epoch,generation:self.generation,
                            payload:packet.bytes,until:min(deadline,min(self.lifetimeDeadline,bound.partialValue)))
                    },cancel:{[weak self] in self?.cancel(notify:true)})
            } else {bridge=nil}
            condition.lock(); endpoint = created; requests=bridge; launched = true; let cancelled = stopped; condition.broadcast(); condition.unlock()
            bridge?.run()
            if cancelled { bridge?.invalidate();created.requestNativeCleanup() }
            clean = created.waitForOwnerReleased(deadline: cleanupDeadline)
            guard clean, created.nativeCleanupObserved, created.ownerDeviceLeaseReleasedObserved,
                  created.ownerTermination == .exited(0) else { throw NativePairMemberError.inactive }
            guard bridge?.localOwnerReleased(until:cleanupDeadline) ?? true else {throw NativePairMemberError.deadline}
            requestTransportJoined = true
            condition.lock(); outcome = "releasing"; condition.unlock()
            guard cancellationPublication.wait(timeout: .init(uptimeNanoseconds: cleanupDeadline)) == .success else { throw NativePairMemberError.deadline }
            var receipt = Data([68, 66, 78, 82, 1]); receipt.append(contentsOf: SHA256.hash(data: start.canonicalBytes)); receipt.append(contentsOf: [1, 1, 1])
            try send("native_pair_owner_released", receipt, cleanup: true)
            localReleasePublished = true
            condition.lock(); outcome = "released"; condition.unlock()
            requestViewsReleased = bridge?.waitAllOwnersReleased(until:cleanupDeadline) ?? true
            guard requestViewsReleased else {throw NativePairMemberError.deadline}
        } catch {
            cancel(notify: true)
            condition.lock(); if outcome != "released" || !requestViewsReleased { outcome = committed ? "quarantined" : "cancelled" }; condition.unlock()
        }
        let cancelJoined = cancellationPublication.wait(timeout: .init(uptimeNanoseconds: cleanupDeadline)) == .success
        condition.lock()
        let reusable = cancelJoined && ((!committed && !launched) || (clean && outcome == "released" && requestViewsReleased))
        timer?.cancel(); timer = nil
        condition.unlock()
        condition.lock(); let actual = endpoint; condition.unlock()
        completion.complete(.init(membershipEpoch: start.common.epoch,
            nativeCleanupObserved: actual?.nativeCleanupObserved == true,
            ownerReleaseAcknowledged: actual?.ownerDeviceLeaseReleasedObserved == true,
            ownerExitedNormally: actual?.ownerTermination == .exited(0),
            requestTransportJoined: requestTransportJoined,
            cancellationPublicationJoined: cancelJoined,
            localReleasePublished: localReleasePublished,
            aggregateReleaseObserved: installation.protectedRuntime != nil && requestViewsReleased))
        onFinished(self, reusable)
    }
    private func requestBinding() throws -> ClusterNativeKeyBinding {
        condition.lock();defer{condition.unlock()}
        try requireLive()
        guard committed, nextRound==7, let peerBinding else {throw NativePairMemberError.inactive}
        return try ClusterNativeKeyBinding(encoded:peerBinding)
    }
    private func acceptAllWorkersReleased(_ message: NativePairMessage,payload:Data) throws {
        condition.lock();defer{condition.unlock()}
        guard installation.protectedRuntime != nil, committed, message.epoch==epoch, message.generation==generation,
              message.prepareBeforeUnixNano==prepareUnixNanoseconds,message.expiresAtUnixNano==expiresUnixNanoseconds,
              payload.count==69,payload.prefix(5)==Data([68,66,78,65,1]),let requests,
              endpoint?.nativeCleanupObserved == true,endpoint?.ownerDeviceLeaseReleasedObserved == true,
              endpoint?.ownerTermination == .exited(0) else {throw NativePairMemberError.binding}
        let localDigest=Data(SHA256.hash(data:start.canonicalBytes))
        guard payload.subdata(in:(5+start.rank*32)..<(37+start.rank*32))==localDigest else {throw NativePairMemberError.binding}
        if let peerBinding {
            let binding=try ClusterNativeKeyBinding(encoded:peerBinding)
            for rank in 0..<2 {
                guard payload.subdata(in:(5+rank*32)..<(37+rank*32))==Data(SHA256.hash(data:binding.hellos[rank].start.canonicalBytes)) else {throw NativePairMemberError.binding}
            }
        }
        // Coordinator sends this only from real Registry Released, after both
        // authenticated owner proofs and its terminal publication barriers.
        try requests.observeAllOwnersReleased()
    }
    func requestOwner(profile:DistributedResidentExecutionProfile,until deadline:UInt64) throws -> NativePairRequestExecutionOwner {
        condition.lock()
        while !stopped && requests==nil && DispatchTime.now().uptimeNanoseconds<deadline {_ = condition.wait(until:Date(timeIntervalSinceNow:0.02))}
        let bridge=requests;let allowed = !stopped && committed && start.rank==0;condition.unlock()
        guard allowed,let bridge else {throw NativePairMemberError.inactive}
        return try bridge.requestOwner(profile:profile,until:min(deadline,lifetimeDeadline))
    }
    private func ownerInvalidated() {
        condition.lock(); let completedPrelude = nextRound == UInt64(installation.bootstrapProfile.rounds); condition.unlock()
        if !completedPrelude { cancel(notify: true) }
    }
    private func exchange(_ round: UInt64, _ bytes: Data) throws -> Data {
        condition.lock()
        let publicPacket: (String, Data)?
        do {
            try requireLive()
            guard committed, round == nextRound else { throw NativePairMemberError.binding }
            switch round {
            case 0:
                let hello = try ClusterNativeKeyHello(encoded: bytes)
                guard hello.start.canonicalBytes == start.canonicalBytes else { throw NativePairMemberError.binding }
                publicPacket = ("native_pair_hello", bytes)
            case 1: publicPacket = ("native_pair_confirmation", bytes)
            case 2:
                guard let peerBinding, try ClusterNativeKeyBinding(encoded: peerBinding).transcriptSHA256 == bytes else { throw NativePairMemberError.binding }
                if combinedMesh {
                    guard !keyConfirmationSent else { throw NativePairMemberError.binding }
                    keyConfirmationSent = true
                    publicPacket = ("native_pair_key_confirmed", try NativePairMesh.keyConfirmed(bytes))
                } else { publicPacket = nil }
            case 3...6:
                guard combinedMesh, meshReady, let peerBinding, meshContribution == nil, meshReply == nil else { throw NativePairMemberError.binding }
                let digest = try ClusterNativeKeyBinding(encoded: peerBinding).transcriptSHA256
                let packet = try NativePairMesh.packet(transcript: digest, rank: start.rank, round: UInt8(round - 3), value: bytes)
                meshContribution = bytes
                publicPacket = ("native_pair_mesh", packet)
            default: throw NativePairMemberError.binding
            }
        } catch { condition.unlock(); throw error }
        condition.unlock()
        if let publicPacket { try send(publicPacket.0, publicPacket.1) }
        condition.lock(); defer { condition.unlock() }
        while !stopped && ((round == 0 && peerBinding == nil) || (round == 1 && peerConfirmation == nil)
                || (round == 2 && combinedMesh && !meshReady) || (round >= 3 && meshReply == nil))
                && DispatchTime.now().uptimeNanoseconds < lifetimeDeadline {
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
            guard !combinedMesh || meshReady else { throw NativePairMemberError.deadline }
            outcome = "native-confirmation-observed"; result = bytes
        case 3...6:
            guard let meshReply else { throw NativePairMemberError.deadline }
            result = meshReply; self.meshReply = nil; meshContribution = nil
            if round == 6 { outcome = "native-mesh-rounds-complete" }
        default: throw NativePairMemberError.binding
        }
        nextRound += 1; return result
    }
    private static func uuidBytes(_ value: UUID) -> Data { withUnsafeBytes(of: value.uuid) { Data($0) } }
}
