import Foundation
import DarkbloomClusterProtocol
import DarkbloomClusterRemote
import DarkbloomClusterSecurity

/// Minted only by the actual driver, after both exact authenticated retirement
/// receipts and their digest acknowledgments. It cannot authorize another run.
struct GLM5NextCalibrationDispatchTerminalReceipt {
    let sessionID: UUID
    let archive: Data
    fileprivate init(sessionID: UUID, archive: Data) { self.sessionID = sessionID; self.archive = archive }
}

/// Dedicated blocking driver. No setup responder, event-reader or bootstrap
/// publication thread ever waits here for the other owner.
final class GLM5NextCalibrationDispatch: @unchecked Sendable {
    typealias W = GLM5NextCalibrationDispatchWire
    typealias Owner = GLM5NextCalibrationInstalledOwner
    let completed: GLM5NextCalibrationInstalledQuote.Completed
    let channel: GLM5NextCalibrationPairedControl
    let sessionID: UUID
    private let fenceDirectory: URL
    private let lock = NSLock()
    private let driver = DispatchQueue(label: "darkbloom.glm.finite.dispatch")
    private let localRounds = DispatchQueue(label: "darkbloom.glm.finite.local-rounds")
    private let peerRounds = DispatchQueue(label: "darkbloom.glm.finite.peer-rounds")
    private var owner: Owner?
    private var relay: ClusterOwnerBootstrapRelay?
    private var cancelled = false
    private var relayFailed = false
    private var cancellationQueued = false
    private var localRound: UInt64 = 0
    private var peerRound: UInt64 = 0
    private var terminalOutcome: Bool?
    private let ownerEnvironment: Owner.Resources.Environment?
    private let observe: (@Sendable (Observation) throws -> Void)?
    /// Execution observers only. Values originate from the real owner/driver;
    /// no observer return value can authorize a launch or retirement.
    enum Observation: Sendable {
        case prepared(Owner), committed(Owner.CommitContext), beforeLaunch, bootstrapPublished(UInt64)
        case beforeTerminalConsume, terminalAuthenticated, archiveSynced, returning
        case localResultPublished, peerResultValidated
    }
    static func isolatedTests(completed: GLM5NextCalibrationInstalledQuote.Completed,
                              channel: GLM5NextCalibrationPairedControl, sessionID: UUID,
                              fenceDirectory: URL, environment: Owner.Resources.Environment,
                              observe: @escaping @Sendable (Observation) throws -> Void) throws -> GLM5NextCalibrationDispatch {
        try Self(completed: completed, channel: channel, sessionID: sessionID,
                 fenceDirectory: fenceDirectory, environment: environment, observe: observe)
    }

    convenience init(completed: GLM5NextCalibrationInstalledQuote.Completed, channel: GLM5NextCalibrationPairedControl,
         sessionID: UUID, fenceDirectory: URL) throws {
        try self.init(completed: completed, channel: channel, sessionID: sessionID,
                      fenceDirectory: fenceDirectory, environment: nil, observe: nil)
    }
    private init(completed: GLM5NextCalibrationInstalledQuote.Completed, channel: GLM5NextCalibrationPairedControl,
                 sessionID: UUID, fenceDirectory: URL, environment: Owner.Resources.Environment?,
                 observe: (@Sendable (Observation) throws -> Void)?) throws {
        try channel.requireContext(completed: completed, sessionID: sessionID)
        ownerEnvironment = environment; self.observe = observe
        self.completed = completed; self.channel = channel; self.sessionID = sessionID; self.fenceDirectory = fenceDirectory
        channel.onFailure { [weak self] in self?.cancelLocal() }
    }
    func cancel() {
        guard !lock.withLock({ terminalOutcome != nil }) else { return }
        cancelLocal()
        let first = lock.withLock { () -> Bool in
            guard !cancellationQueued else { return false }; cancellationQueued = true; return true
        }
        guard first else { return }
        // Signal callbacks never wait for network IO. The real bounded channel
        // sends cancellation; its connection failure also cancels the peer owner.
        DispatchQueue.global().async { [self] in
            try? channel.send(.cancel, W.canonical(W.Empty()), deadline: DispatchTime.now().uptimeNanoseconds + 2_000_000_000)
        }
    }
    private func cancelLocal() {
        let values = lock.withLock { () -> (Owner?, ClusterOwnerBootstrapRelay?) in
            guard terminalOutcome == nil else { return (nil, nil) }
            cancelled = true; return (owner, relay)
        }
        values.1?.cancel(); values.0?.cancel()
    }
    func run() throws -> Data {
        try driver.sync {
            do { return try execute() }
            catch {
                cancel()
                // No command timeout, report, PID inference or dropped caller
                // may exit the installed owner process with a live native child.
                drainLocalOwnership()
                channel.close()
                throw error
            }
        }
    }
    private func requireOperation(_ deadline: UInt64) throws {
        guard !lock.withLock({ cancelled || relayFailed }) else { throw W.invalid("finite dispatch cancelled") }
        try completed.requireUnchanged(deadline: deadline)
        try channel.requireCurrent(pair: completed.pair)
    }
    private func wait(_ kind: W.Kind, deadline: UInt64) throws -> Data {
        while DispatchTime.now().uptimeNanoseconds < deadline {
            try requireOperation(deadline)
            if let packet = try channel.receive(deadline: min(deadline, DispatchTime.now().uptimeNanoseconds + 100_000_000)) {
                if packet.kind == .cancel {
                    _ = try W.decode(W.Empty.self, packet.payload)
                    cancelLocal(); throw W.invalid("peer cancelled finite dispatch")
                }
                guard packet.kind == kind else { throw W.invalid("finite dispatch phase/replay") }
                return packet.payload
            }
        }
        throw W.invalid("finite dispatch phase deadline")
    }
    private func exchange(_ kind: W.Kind, _ data: Data, deadline: UInt64) throws -> Data {
        try requireOperation(deadline)
        try channel.send(kind, data, deadline: deadline)
        return try wait(kind, deadline: deadline)
    }
    private func execute() throws -> Data {
        let p = completed.authorized.request.selection
        let rank = p.rank
        let now = DispatchTime.now().uptimeNanoseconds
        let seconds = min(30.0, Double(p.expiresUnixSeconds) - Date().timeIntervalSince1970 - 1)
        guard seconds > 0 else { throw W.invalid("finite dispatch expired before connection") }
        let admissionDeadline = now + UInt64(seconds * 1e9)
        try channel.connect(deadline: admissionDeadline)
        let hello = try exchange(.hello, W.canonical(W.Empty()), deadline: admissionDeadline)
        _ = try W.decode(W.Empty.self, hello)
        let outgoing = try GLM5NextCalibrationPeerQuote.outbound(completed: completed,
            now: Int64(Date().timeIntervalSince1970), deadline: admissionDeadline)
        let peerSummary = try exchange(.quotation, outgoing, deadline: admissionDeadline)
        let peer = try GLM5NextCalibrationPeerQuote.admit(completed: completed,
            receiveFromAuthenticatedPair: { pair, _ in
                try self.channel.requireCurrent(pair: pair)
                // These are ONLY the bytes just received on this frozen channel.
                return peerSummary
            }, now: Int64(Date().timeIntervalSince1970), deadline: admissionDeadline)
        let fence = try GLM5NextCalibrationDispatchFence(directory: fenceDirectory, pair: completed.pair,
            sessionID: sessionID, epoch: p.epoch, requestID: completed.authorized.request.authorization.requestID)
        // Both actual metadata children have finished BEFORE finite exclusion.
        let retainedChannel = channel, retainedPair = completed.pair
        let custody = { try retainedChannel.requireCurrent(pair: retainedPair) }
        let owner: Owner
        if let ownerEnvironment {
            owner = try Owner.prepare(completed: completed, peer: peer, environment: ownerEnvironment,
                                      requireCurrentAuthenticatedCustody: custody)
        } else {
            owner = try Owner.prepare(completed: completed, peer: peer, requireCurrentAuthenticatedCustody: custody)
        }
        lock.withLock { self.owner = owner }
        try observe?(.prepared(owner))
        let deadline = owner.experimentDeadline
        let peerDocument = try exchange(.document, owner.outboundDocument, deadline: deadline)
        let start = try owner.admit(peerDocument: peerDocument)
        let peerStart = try ClusterNativeAuthorizationStart(encoded: exchange(.start, start.canonicalBytes, deadline: deadline))
        let context = try owner.commit(peerStart: peerStart) // ACTUAL local native factory commit.
        try observe?(.committed(context))
        let localCommit = W.Commit(starts: context.starts.map(\.canonicalBytes), planSHA256: context.binding.executionPlanSHA256,
            profileSHA256: W.hex(context.localStart.common.profileSHA256), matrixSHA256: context.transport.matrixSHA256,
            coordinator: context.transport.coordinator, interface: context.transport.localInterface, device: context.transport.device)
        let localBytes = try W.canonical(localCommit)
        let peerBytes = try exchange(.commit, localBytes, deadline: deadline)
        let remote = try W.decode(W.Commit.self, peerBytes)
        guard remote.starts == localCommit.starts, remote.planSHA256 == localCommit.planSHA256,
              remote.profileSHA256 == localCommit.profileSHA256, remote.matrixSHA256 == localCommit.matrixSHA256,
              remote.coordinator == localCommit.coordinator, remote.interface == completed.pair.record.link.peerInterface,
              remote.device == "rdma_" + completed.pair.record.link.peerInterface else { throw W.invalid("peer native commit/transport differs") }
        let orderedCommits = rank == 0 ? [localBytes, peerBytes] : [peerBytes, localBytes]
        let commitSHA = W.hash(try W.canonical(orderedCommits))
        let ack = try W.canonical(W.Digest(sha256: commitSHA))
        guard try exchange(.commitAck, ack, deadline: deadline) == ack else { throw W.invalid("peer native commit acknowledgment") }
        // The peer can emit this ONLY after receiving both actual commits and
        // both commit acknowledgments. Neither side has launched yet.
        guard try exchange(.launchBarrier, ack, deadline: deadline) == ack else { throw W.invalid("peer launch barrier") }
        let proof = CommitProof(channel: channel, completed: completed, context: context, digest: commitSHA)
        let relay = try ClusterOwnerBootstrapRelay(identity: context.binding.identity,
            executionPlanSHA256: context.binding.executionPlanSHA256, profile: .nativeKeyPreludeMesh2,
            deadlineUptimeNanoseconds: deadline, nativeStarts: context.starts)
        lock.withLock { self.relay = relay }
        let remoteStart = context.starts[1 - rank]
        let remoteBinding = try ClusterOwnerBinding(clusterID: completed.pair.clusterID,
            ownerIncarnation: remoteStart.ownerIncarnation, leaseID: remoteStart.leaseID,
            identity: context.binding.identity, profile: context.binding.profile, rank: 1 - rank,
            executionPlanSHA256: context.binding.executionPlanSHA256)
        let peerResult = try GLM5NextCalibrationDispatchResult(completed: completed, peerSummary: peerSummary,
            peerDocument: peerDocument, commitSHA256: commitSHA)
        try observe?(.beforeLaunch)
        try owner.launch(requireBothAuthenticatedCommits: { pair, context, deadline in
            try proof.require(pair: pair, context: context, deadline: deadline)
        }, publish: { [self] actual, sequence, bytes in
            try proof.require(pair: completed.pair, context: actual, deadline: deadline)
            try lock.withLock {
                guard sequence == localRound, sequence < 7 else { throw W.invalid("local bootstrap sequence") }
                localRound += 1
            }
            try channel.send(.bootstrap, W.canonical(W.Bootstrap(sequence: sequence, bytes: bytes)), deadline: deadline)
            try observe?(.bootstrapPublished(sequence))
            localRounds.async { [self] in deliver(relay: relay, owner: owner, binding: context.binding, sequence: sequence, bytes: bytes) }
        })
        var ownResult: W.Result?, remoteResult: W.Result?
        var peerSuccess = false, sentCancellation = false
        while ownResult == nil || remoteResult == nil {
            if lock.withLock({ cancelled || relayFailed }) || DispatchTime.now().uptimeNanoseconds >= deadline {
                cancelLocal()
                if !sentCancellation {
                    sentCancellation = true
                    try channel.send(.cancel, W.canonical(W.Empty()), deadline: terminalDeadline())
                }
            }
            if ownResult == nil, let result = try localResult(owner: owner, commit: commitSHA) {
                try GLM5NextCalibrationDispatchResult.retired(result, expectedCommit: commitSHA)
                try channel.send(.result, W.canonical(result), deadline: terminalDeadline())
                ownResult = result
                try observe?(.localResultPublished)
            }
            // Both retirements are complete. Only the terminal exchange may
            // consume the peer's acknowledgment, including one already queued.
            if ownResult != nil && remoteResult != nil { break }
            if let packet = try channel.receive(deadline: DispatchTime.now().uptimeNanoseconds + 100_000_000) {
                switch packet.kind {
                case .bootstrap:
                    guard remoteResult == nil, !lock.withLock({ cancelled }), DispatchTime.now().uptimeNanoseconds < deadline else { throw W.invalid("late finite bootstrap") }
                    let item = try W.decode(W.Bootstrap.self, packet.payload)
                    guard item.sequence == peerRound, item.sequence < 7, item.bytes.count <= 131_072 else { throw W.invalid("peer bootstrap sequence/size") }
                    peerRound += 1
                    // Blocking existing relay waits use separate per-rank queues.
                    // Never the channel event reader or setup serial command work.
                    peerRounds.async { [self, sequence = item.sequence, bytes = item.bytes] in
                        deliver(relay: relay, owner: nil, binding: remoteBinding, sequence: sequence, bytes: bytes)
                    }
                case .result:
                    guard remoteResult == nil else { throw W.invalid("duplicate peer result") }
                    let result = try W.decode(W.Result.self, packet.payload)
                    peerSuccess = try peerResult.validate(result); remoteResult = result
                    try observe?(.peerResultValidated)
                    if !peerSuccess { cancelLocal() }
                case .cancel:
                    _ = try W.decode(W.Empty.self, packet.payload); cancelLocal()
                default: throw W.invalid("unexpected finite running phase")
                }
            }
        }
        guard let ownResult, let remoteResult else { throw W.invalid("missing finite retirements") }
        let results = rank == 0 ? [ownResult, remoteResult] : [remoteResult, ownResult]
        struct Archive: Codable {
            let version: Int
            let sessionID: UUID
            let epoch: UUID
            let requestID: UUID
            let expiresUnixSeconds: Int64
            let commits: [Data]
            let signedFiniteDocuments: [Data]
            let completedSummarySHA256: [String]
            let results: [W.Result]
        }
        let documents = rank == 0 ? [owner.outboundDocument, peerDocument] : [peerDocument, owner.outboundDocument]
        let summaries = rank == 0 ? [outgoing, peerSummary] : [peerSummary, outgoing]
        let archive = try W.canonical(Archive(version: 1, sessionID: sessionID, epoch: p.epoch,
            requestID: context.requestID, expiresUnixSeconds: context.expiresUnixSeconds,
            commits: orderedCommits, signedFiniteDocuments: documents,
            completedSummarySHA256: summaries.map(W.hash), results: results))
        let resultAck = try W.canonical(W.Digest(sha256: W.hash(archive)))
        // Both actual retirements, detailed-result validation and the exact
        // archive are established BEFORE enabling the narrow terminal path.
        drainLocalOwnership()
        let peerCancelled = try channel.exchangeTerminalAcknowledgment(resultAck, deadline: terminalDeadline()) {
            try self.observe?(.beforeTerminalConsume)
        }
        var success = false
        try channel.authenticateTerminalRetirement {
            lock.withLock {
                // Linearized with channel poison; an already-authenticated
                // retirement cannot be rewritten by expected close during fsync.
                success = ownResult.termination == .exited && ownResult.code == 0 && ownResult.bootstrapCompleted
                    && ownResult.report != nil && peerSuccess && !peerCancelled && !cancelled && !relayFailed
                terminalOutcome = success
            }
        }
        try observe?(.terminalAuthenticated)
        let receipt = GLM5NextCalibrationDispatchTerminalReceipt(sessionID: sessionID, archive: archive)
        let archiveURL = try fence.finish(receipt, afterArchiveSynced: { try self.observe?(.archiveSynced) })
        try channel.closeRetired()
        try observe?(.returning)
        struct Summary: Encodable {
            let schema: String; let sessionID: UUID; let success: Bool; let actualLocalExitObserved: Bool
            let peerAuthenticatedRetirementClaim: Bool; let detailedReportArchive: String
            let servingGrant: Bool; let qualifiesMaximumEnvelope: Bool
        }
        return try W.canonical(Summary(schema: "darkbloom_glm_finite_dispatch_result_v1", sessionID: sessionID,
            success: success, actualLocalExitObserved: ownResult.termination != .noLaunch,
            peerAuthenticatedRetirementClaim: true, detailedReportArchive: archiveURL.path,
            servingGrant: false, qualifiesMaximumEnvelope: false))
    }
    /// Minted only after the real channel's two commit+ack+barrier exchanges.
    private struct CommitProof: @unchecked Sendable {
        let channel: GLM5NextCalibrationPairedControl
        let completed: GLM5NextCalibrationInstalledQuote.Completed
        let context: Owner.CommitContext
        let digest: String
        func require(pair: GLM5NextCalibrationInstalledPair, context actual: Owner.CommitContext, deadline: UInt64) throws {
            try channel.requireCurrent(pair: pair); try completed.requireUnchanged(deadline: deadline)
            guard actual.requestID == context.requestID, actual.expiresUnixSeconds == context.expiresUnixSeconds,
                  actual.starts.map(\.canonicalBytes) == context.starts.map(\.canonicalBytes),
                  actual.binding.route == context.binding.route, actual.binding.identity == context.binding.identity,
                  actual.binding.profile == context.binding.profile,
                  actual.binding.executionPlanSHA256 == context.binding.executionPlanSHA256,
                  actual.transport.matrixSHA256 == context.transport.matrixSHA256,
                  actual.transport.coordinator == context.transport.coordinator,
                  actual.transport.localInterface == context.transport.localInterface,
                  actual.transport.device == context.transport.device,
                  GLM5NextCalibrationDocument.hashSyntax(digest) else { throw W.invalid("native commit proof changed") }
        }
    }
    private func deliver(relay: ClusterOwnerBootstrapRelay, owner: Owner?, binding: ClusterOwnerBinding, sequence: UInt64, bytes: Data) {
        do {
            let reply = try relay.exchange(binding: binding, sequence: sequence, contribution: bytes)
            if let owner { try owner.acceptBootstrapReply(sequence: sequence, bytes: reply) }
        } catch {
            lock.withLock { relayFailed = true }; cancelLocal()
        }
    }
    private func localResult(owner: Owner, commit: String) throws -> W.Result? {
        let status = owner.status()
        if let exit = owner.actualExit() {
            guard exit.localJournalResolved else { return nil }
            let termination: W.Termination, code: Int32?
            switch exit.termination {
            case .exited(let value): termination = .exited; code = value
            case .signalled(let value): termination = .signalled; code = value
            case .launchFailed: termination = .noLaunch; code = nil
            }
            // Zero-exit may precede the bootstrap queue's final local completion.
            if termination == .exited && code == 0 && !status.bootstrapCompleted && status.failure == nil
                && !status.cancelled && DispatchTime.now().uptimeNanoseconds < owner.experimentDeadline { return nil }
            let report = try? W.canonical(owner.completed())
            return W.Result(commitSHA256: commit, termination: termination, code: code,
                journalResolved: true, bootstrapCompleted: status.bootstrapCompleted,
                report: report, reportSHA256: report.map(W.hash))
        }
        if status.phase == .retired && !status.observedExit && status.journalResolved {
            return W.Result(commitSHA256: commit, termination: .noLaunch, code: nil,
                journalResolved: true, bootstrapCompleted: false, report: nil, reportSHA256: nil)
        }
        return nil
    }
    private func drainLocalOwnership() {
        guard let owner = lock.withLock({ owner }) else { return }
        while true {
            let status = owner.status()
            if status.phase == .retired && status.journalResolved {
                if !status.observedExit || owner.actualExit()?.localJournalResolved == true { return }
            }
            // Deliberately no PID inference or elapsed-time release. The actual
            // supervisor retains its child/resources; an unresolved journal stays held.
            Thread.sleep(forTimeInterval: 0.02)
        }
    }
    private func terminalDeadline() -> UInt64 { DispatchTime.now().uptimeNanoseconds + 2_000_000_000 }
}
