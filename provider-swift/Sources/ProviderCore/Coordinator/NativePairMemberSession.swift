import Foundation
import CryptoKit
import DarkbloomClusterProtocol
import DarkbloomClusterRemote
import DarkbloomClusterSecurity
import Logging

/// Why a committed session ended early. Errors only; no request payload.
private let nativeMemberLog = Logger(label: "darkbloom.native-member")

/// One actual committed owner obligation. Cancellation interrupts waits and
/// requests native cleanup immediately; only observed owner proof permits release.
final class NativePairMemberSession: @unchecked Sendable {
    /// The coordinator's grant lease (S15): every session holds one, renewed
    /// by `native_pair_lease`; there is no fixed lifetime. A grant or renewal
    /// that leaves more than its time to live plus the clock allowance on this
    /// Mac's clock is refused, which bounds how long an owner can outlive the
    /// coordinator's expiry.
    static let leaseTimeToLiveNanoseconds: UInt64 = 120_000_000_000
    static let clockAllowanceNanoseconds: UInt64 = 5_000_000_000
    /// How long an established session waits for its member's control
    /// connection to come back, matching the coordinator's grace; its lease
    /// ends it sooner if that comes first.
    static let disconnectGraceNanoseconds: UInt64 = 90_000_000_000
    /// The combined bootstrap (prelude through the coordinator, then the mesh
    /// rounds through the link) completes within this of the owner's launch,
    /// or the owner is cleaned up and the session releases.
    static let bootstrapAllowanceNanoseconds: UInt64 = 30_000_000_000
    let start: ClusterNativeAuthorizationStart
    let epoch: String
    let generation: UInt64
    let prepareDeadline: UInt64
    let prepareUnixNanoseconds: Int64
    private let cancellationPublication = DispatchGroup()
    private var currentConnection: NativePairMemberConnection
    var connection: NativePairMemberConnection { condition.lock(); defer { condition.unlock() }; return currentConnection }
    private let installation: NativePairMemberInstallation
    private let condition = NSCondition()
    private var leaseDeadline: UInt64
    private var leaseExpiresUnix: Int64
    private var leaseRenewal: UInt64 = 0
    private var detachedAt: UInt64?
    /// The current grant's end on this Mac's uptime clock, and as the frames carry it.
    var lifetimeDeadline: UInt64 { condition.lock(); defer { condition.unlock() }; return leaseDeadline }
    var expiresUnixNanoseconds: Int64 { condition.lock(); defer { condition.unlock() }; return leaseExpiresUnix }
    /// Native cleanup has three seconds past the current grant.
    var cleanupDeadline: UInt64 { lifetimeDeadline &+ 3_000_000_000 }
    private var stopped = false, committed = false, launched = false
    private var peerBinding: Data?, peerConfirmation: Data?
    private var nextRound: UInt64 = 0
    private var endpoint: ClusterRemoteWorkerEndpoint?
    private var timer: DispatchSourceTimer?
    private var outcome: String = "preparing"
    /// Set once `runOwned` returned: the receipt was sent, or the session
    /// ended without one.
    private var ownedRunFinished = false
    /// What serves this start once its owner launched (S10); nil keeps the
    /// session to the key prelude and release, as before.
    private let servingHost: (any NativePairMemberServingHost)?
    private var serving = false
    private let onFinished: @Sendable (NativePairMemberSession, Bool) -> Void
    var status: String { condition.lock(); defer { condition.unlock() }; return outcome }
    /// S16: nil unless this session's owner is launched and not stopped;
    /// then what its worker published in its readiness (both false before it
    /// is ready, or when its data plane is not keyed).
    var dataPlaneObservation: (encrypted: Bool, peerVerified: Bool)? {
        condition.lock(); let live = launched && !stopped, endpoint = endpoint; condition.unlock()
        guard live, let endpoint else { return nil }
        let plane = endpoint.readiness?.dataPlane
        return (plane?.protection == ClusterWorkerDataPlane.encrypted, plane?.encryptedAndVerified == true)
    }
    /// Whether a dropped control connection leaves this session in its grace:
    /// committed, keys exchanged, owner launched, not stopped.
    var survivesDisconnect: Bool {
        condition.lock(); defer { condition.unlock() }
        return committed && launched && nextRound == 3 && !stopped
    }
    init(installation: NativePairMemberInstallation, connection: NativePairMemberConnection,
         message: NativePairMessage, receivedAt: UInt64, wallUnixNanoseconds: Int64,
         servingHost: (any NativePairMemberServingHost)? = nil,
         onFinished: @escaping @Sendable (NativePairMemberSession, Bool) -> Void) throws {
        let (policy, start) = try NativePairMemberPolicy.preparation(Data(base64Encoded: message.payload)!)
        try installation.requireStart(start)
        guard policy.bytes == installation.policy.bytes, start.rank == installation.rank,
              NativePairMemberInstallation.hex(Self.uuidBytes(start.common.epoch)) == message.epoch,
              start.common.membershipGeneration == message.generation,
              let prepare = message.prepareBeforeUnixNano, let expires = message.expiresAtUnixNano,
              wallUnixNanoseconds > 0, prepare > wallUnixNanoseconds, expires > prepare, UInt64(expires) < policy.notAfter else { throw NativePairMemberError.binding }
        // Anchor once on receipt; later start/hello/binding never restart a
        // timer. Only a lease renewal moves the grant.
        let prepDelta = UInt64(prepare - wallUnixNanoseconds), lifetimeDelta = UInt64(expires - wallUnixNanoseconds)
        guard prepDelta <= 30_000_000_000, lifetimeDelta <= Self.leaseTimeToLiveNanoseconds + Self.clockAllowanceNanoseconds,
              receivedAt <= UInt64.max - lifetimeDelta - 3_000_000_000 else { throw NativePairMemberError.deadline }
        self.installation = installation; currentConnection = connection; self.start = start
        epoch = message.epoch; generation = message.generation
        prepareDeadline = receivedAt + prepDelta; leaseDeadline = receivedAt + lifetimeDelta
        prepareUnixNanoseconds = prepare; leaseExpiresUnix = expires
        self.servingHost = servingHost
        self.onFinished = onFinished
    }
    func run() {
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .init(uptimeNanoseconds: lifetimeDeadline))
        timer.setEventHandler { [weak self] in self?.leaseTimerFired() }
        condition.lock(); self.timer = timer; condition.unlock()
        timer.resume()
        DispatchQueue(label: "darkbloom.native-member.owner").async { self.runOwned() }
    }
    /// The grant's end: stop the owner unless a renewal moved it meanwhile.
    private func leaseTimerFired() {
        condition.lock()
        let now = DispatchTime.now().uptimeNanoseconds
        if now < leaseDeadline {
            timer?.schedule(deadline: .init(uptimeNanoseconds: leaseDeadline)); condition.unlock(); return
        }
        condition.unlock()
        nativeMemberLog.warning("committed session \(start.common.epoch): grant lease expired")
        cancel(notify: true)
    }

    /// Waits until the owned run returned (its release receipt sent, or the
    /// session ended without one) or the deadline passed. Returns whether it
    /// returned. Blocks the calling thread.
    func waitUntilFinished(deadline: Date) -> Bool {
        condition.lock(); defer { condition.unlock() }
        while !ownedRunFinished {
            if !condition.wait(until: deadline) { return ownedRunFinished }
        }
        return true
    }

    /// A dropped control connection: an established session keeps its owner
    /// for the disconnect grace (and never past its grant); anything else
    /// ends now.
    func detached(now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Bool {
        guard survivesDisconnect else { cancel(notify: false); return false }
        condition.lock(); detachedAt = now; condition.unlock()
        DispatchQueue.global().asyncAfter(deadline: .init(uptimeNanoseconds: now + Self.disconnectGraceNanoseconds)) { [weak self] in
            guard let self else { return }
            self.condition.lock(); let away = self.detachedAt == now; self.condition.unlock()
            if away { self.cancel(notify: false) }
        }
        return true
    }

    /// The member's new control connection, after its registration claimed
    /// this session (`resume`); the coordinator renews the grant on it.
    func reattach(_ connection: NativePairMemberConnection) throws {
        condition.lock(); defer { condition.unlock() }
        guard !stopped, detachedAt != nil, DispatchTime.now().uptimeNanoseconds < leaseDeadline else { throw NativePairMemberError.inactive }
        currentConnection = connection; detachedAt = nil
    }

    /// The claim this member registers on a new connection while away.
    var resumeClaim: ClusterMembership.Resume? {
        condition.lock(); defer { condition.unlock() }
        guard detachedAt != nil, !stopped else { return nil }
        return .init(epoch: epoch, generation: generation)
    }

    func accept(_ message: NativePairMessage, receivedAt: UInt64 = DispatchTime.now().uptimeNanoseconds,
                wallUnixNanoseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1e9)) throws {
        let payload = Data(base64Encoded: message.payload)!
        condition.lock(); defer { condition.unlock() }
        guard message.epoch == epoch, message.generation == generation,
              message.prepareBeforeUnixNano == prepareUnixNanoseconds,
              message.type == "native_pair_lease" || message.expiresAtUnixNano == leaseExpiresUnix,
              !stopped, DispatchTime.now().uptimeNanoseconds < leaseDeadline else { throw NativePairMemberError.inactive }
        switch message.type {
        case "native_pair_lease":
            // "DBNL" v1: renewal ordinal, new expiry; the frame repeats it
            // (`NativePairLeaseRenewal`, the coordinator's shared vector).
            guard committed, let lease = NativePairLeaseRenewal(payload: payload) else { throw NativePairMemberError.binding }
            let expiry = lease.expiresAtUnixNano
            guard lease.renewal > leaseRenewal, expiry == message.expiresAtUnixNano,
                  expiry > wallUnixNanoseconds, UInt64(expiry - wallUnixNanoseconds)
                    <= Self.leaseTimeToLiveNanoseconds + Self.clockAllowanceNanoseconds else { throw NativePairMemberError.deadline }
            leaseRenewal = lease.renewal; leaseExpiresUnix = expiry
            leaseDeadline = max(leaseDeadline, receivedAt + UInt64(expiry - wallUnixNanoseconds))
            timer?.schedule(deadline: .init(uptimeNanoseconds: leaseDeadline))
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
        let endpoint = endpoint, host = serving ? servingHost : nil; condition.broadcast(); condition.unlock()
        // Close the served slot's admission now; the owner's cleanup below
        // ends a request still running, and `runOwned` waits for the slot's
        // retirement before any receipt.
        if let host { let epoch = start.common.epoch; Task.detached { await host.stopServingCommittedStart(epoch: epoch) } }
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
    /// The caller holds `condition`.
    private func requireLive() throws {
        guard !stopped, currentConnection.isLive, DispatchTime.now().uptimeNanoseconds < leaseDeadline else { throw NativePairMemberError.inactive }
    }
    private func runOwned() {
        var clean = false
        do {
            // Declined before `prepared`, so the coordinator never commits a
            // start this Mac's owner would refuse.
            guard installation.ownerServesCommittedStart else { throw NativePairMemberError.unconfigured }
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
            let mayLaunch = !stopped && committed && currentConnection.isLive && DispatchTime.now().uptimeNanoseconds < prepareDeadline; condition.unlock()
            guard mayLaunch else { throw NativePairMemberError.deadline }
            for pin in pins { try pin.requireUnchanged() }
            // The owner is opened with one rank-lease grant, never past the
            // coordinator's current one; its endpoint renews it until this
            // session stops it, which the coordinator's lease decides.
            let now = DispatchTime.now().uptimeNanoseconds
            let firstGrant = min(lifetimeDeadline, now + ClusterWorkerLease.maximumNanoseconds)
            let prelude: @Sendable (UInt64, Data) throws -> Data = { [weak self] round, bytes in
                guard let self else { throw NativePairMemberError.inactive }; return try self.exchange(round, bytes)
            }
            // The combined profile (S10): the prelude through this session, the
            // mesh rounds through the serving host, all before the bootstrap
            // bound. The prelude alone publishes no readiness (fixtures).
            var bootstrap: ClusterOwnerCommittedBootstrap?
            var relay: ClusterOwnerNativeKeyRelay?
            switch installation.bootstrap {
            case .preludeThenMesh:
                bootstrap = try ClusterOwnerCommittedBootstrap(start: start, identity: installation.sessionIdentity(start),
                    executionPlanSHA256: installation.executionPlanSHA256,
                    deadlineUptimeNanoseconds: min(firstGrant, now + Self.bootstrapAllowanceNanoseconds),
                    prelude: prelude, invalidated: { [weak self] in self?.ownerInvalidated() })
            case .nativeKeyPrelude:
                relay = try ClusterOwnerNativeKeyRelay(start: start, deadlineUptimeNanoseconds: firstGrant,
                    exchange: prelude, cancel: { [weak self] in self?.ownerInvalidated() })
            }
            // The committed obligation is retained even if launch throws or a
            // concurrent cancel wins between this check and actual Process.run.
            condition.lock(); let allowed = !stopped && committed; condition.unlock()
            guard allowed else { throw NativePairMemberError.inactive }
            // S16: a roster member keys its worker's data plane with a
            // credential its own Secure Enclave key certifies, pinned to the
            // peer member's roster key (never issued by another Mac).
            let trust = try installation.roster.map { try $0.dataPlaneTrust(start: start, signer: connection.memberSigner) }
            let created = try bootstrap.map { try installation.launch(start: start, until: firstGrant, bootstrap: $0,
                    dataPlaneTrust: trust) }
                ?? installation.launch(start: start, until: firstGrant, relay: relay!)
            condition.lock(); endpoint = created; launched = true; let cancelled = stopped
            if !cancelled, servingHost != nil { serving = true }
            condition.unlock()
            if cancelled { created.requestNativeCleanup() }
            else if let host = servingHost { beginServing(host, endpoint: created, mesh: bootstrap) }
            // No fixed lifetime: wait in slices, each up to the current
            // grant's cleanup bound, which every renewal moves on.
            while true {
                let limit = cleanupDeadline
                if created.waitForOwnerReleased(deadline: min(limit, DispatchTime.now().uptimeNanoseconds + 1_000_000_000)) { clean = true; break }
                if created.ownerTermination != nil || DispatchTime.now().uptimeNanoseconds >= limit { break }
            }
            guard clean, created.nativeCleanupObserved, created.ownerDeviceLeaseReleasedObserved,
                  created.ownerTermination == .exited(0) else { throw NativePairMemberError.inactive }
            // Nothing this start served outlives its receipt.
            stopServing()
            condition.lock(); outcome = "releasing"; condition.unlock()
            guard cancellationPublication.wait(timeout: .init(uptimeNanoseconds: cleanupDeadline)) == .success else { throw NativePairMemberError.deadline }
            var receipt = Data([68, 66, 78, 82, 1]); receipt.append(contentsOf: SHA256.hash(data: start.canonicalBytes)); receipt.append(contentsOf: [1, 1, 1])
            try send("native_pair_owner_released", receipt, cleanup: true)
            condition.lock(); outcome = "released"; condition.unlock()
        } catch {
            nativeMemberLog.warning("committed session \(start.common.epoch) rank \(installation.rank) ended (launched \(condition.withLock { launched })): \(error)")
            cancel(notify: true)
            stopServing()
            condition.lock(); if outcome != "released" { outcome = committed ? "quarantined" : "cancelled" }; condition.unlock()
        }
        // The owner's own diagnostics (its worker's stderr tail) are the only
        // record of why a pair did not form or a worker ended: keep them.
        if let tail = condition.withLock({ endpoint })?.diagnosticTail, !tail.isEmpty {
            nativeMemberLog.info("committed session \(start.common.epoch) rank \(installation.rank) owner diagnostics: \(Self.diagnosticSummary(tail))")
        }
        let cancelJoined = cancellationPublication.wait(timeout: .init(uptimeNanoseconds: cleanupDeadline)) == .success
        condition.lock()
        let reusable = cancelJoined && ((!committed && !launched) || (clean && outcome == "released"))
        timer?.cancel(); timer = nil
        ownedRunFinished = true; condition.broadcast()
        condition.unlock()
        onFinished(self, reusable)
    }
    /// The last 4 KiB of an owner's diagnostics on one line, control characters removed.
    static func diagnosticSummary(_ tail: Data, limit: Int = 4096) -> String {
        let text = String(decoding: tail.suffix(limit), as: UTF8.self)
        let lines = text.split(whereSeparator: \.isNewline).map { line in
            String(String.UnicodeScalarView(line.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 }))
        }
        return (tail.count > limit ? "... " : "") + lines.filter { !$0.isEmpty }.joined(separator: " | ")
    }
    /// Hands the launched owner to the serving host. A host that cannot serve
    /// ends the session: cancellation, native cleanup, release.
    private func beginServing(_ host: any NativePairMemberServingHost, endpoint: ClusterRemoteWorkerEndpoint,
                              mesh: ClusterOwnerCommittedBootstrap?) {
        let value = NativePairMemberServingStart(start: start, identity: installation.sessionIdentity(start),
            profile: installation.profile, executionPlanSHA256: installation.executionPlanSHA256,
            endpoint: endpoint, leaseDeadlineUptimeNanoseconds: lifetimeDeadline, mesh: mesh)
        Task.detached { [weak self] in
            do { try await host.serveCommittedStart(value) } catch {
                nativeMemberLog.warning("committed session \(value.start.common.epoch): serving host failed: \(String(reflecting: error))")
                self?.cancel(notify: true)
            }
        }
    }

    /// Waits, bounded by the cleanup deadline, until the host retired what it
    /// served for this start. Called before every receipt and every finish.
    private func stopServing() {
        let host = condition.withLock { serving ? servingHost : nil }
        guard let host else { return }
        let done = DispatchSemaphore(value: 0), epoch = start.common.epoch
        Task.detached { await host.stopServingCommittedStart(epoch: epoch); done.signal() }
        _ = done.wait(timeout: .init(uptimeNanoseconds: cleanupDeadline))
        condition.withLock { serving = false }
    }

    private func ownerInvalidated() {
        condition.lock(); let completedPrelude = nextRound == 3; condition.unlock()
        if !completedPrelude {
            nativeMemberLog.warning("committed session \(start.common.epoch): owner invalidated before the prelude completed")
            cancel(notify: true)
        }
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
        while !stopped && ((round == 0 && peerBinding == nil) || (round == 1 && peerConfirmation == nil)) && DispatchTime.now().uptimeNanoseconds < leaseDeadline {
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
