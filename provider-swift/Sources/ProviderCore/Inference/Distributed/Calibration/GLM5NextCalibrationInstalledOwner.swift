import CryptoKit
import Foundation
import DarkbloomClusterProcess
import DarkbloomClusterProtocol
import DarkbloomClusterSecurity
@_spi(OwnerService) import DarkbloomClusterRemote

/// One PRIVATE local finite rank. The authenticated dispatcher/relay is a
/// required parent-owned dependency; this type implements no control protocol.
final class GLM5NextCalibrationInstalledOwner: @unchecked Sendable {
    typealias CompletedQuote = GLM5NextCalibrationInstalledQuote.Completed
    typealias Resources = GLM5NextCalibrationInstalledOwnerResources

    struct CommitContext: Sendable {
        let requestID: UUID
        let expiresUnixSeconds: Int64
        let starts: [ClusterNativeAuthorizationStart] // exact native rank order
        let binding: ClusterOwnerBinding
        let transport: Resources.TransportSelection // bounded metadata; not payload custody
        var localStart: ClusterNativeAuthorizationStart { starts[binding.rank] }
    }
    enum Phase: String, Sendable { case prepared, admitted, committed, launchQueued, running, retired, unresolved }
    /// Diagnostic observation only. No checkpoint authorizes launch or retirement.
    enum LaunchCheckpoint: String, Sendable {
        case notQueued, localContext, peerCommits, currentBeforeSetup, orphanCheck, linkReady
        case currentBeforeAttachment, attachment, launchSpecification, supervisorSpecification
        case currentBeforeJournal, journal, currentBeforeSpawn, documentBeforeSpawn, processLaunch, running
    }
    struct Status: Sendable {
        let phase: Phase
        let requestID: UUID
        let rank: Int
        let launchAttempted: Bool
        let cancelled: Bool
        let bootstrapCompleted: Bool
        let observedExit: Bool
        let provisionalReportReceived: Bool
        let journalResolved: Bool
        let failure: String? // closed local codes; no child output/credential
        let launchCheckpoint: LaunchCheckpoint
    }
    /// Local supervisor observation only. Parent must bind/authenticate it on
    /// the exact control channel; no wire authentication or pair refund implied.
    struct ActualExit: Sendable {
        let context: CommitContext
        let termination: ClusterWorkerProcessTermination
        let observedAtUptimeNanoseconds: UInt64
        let localJournalResolved: Bool
    }
    typealias RequireBothAuthenticatedCommits = @Sendable (
        _ exactPair: GLM5NextCalibrationInstalledPair, _ context: CommitContext,
        _ localDeadline: UInt64) throws -> Void
    typealias Publish = @Sendable (_ context: CommitContext, _ sequence: UInt64, _ publicBytes: Data) throws -> Void

    let outboundDocument: Data
    let experimentDeadline: UInt64
    private let quotation: CompletedQuote
    private let authorized: GLM5NextCalibrationAuthorizer.Authorized
    private let resources: Resources
    private let transport: Resources.TransportSelection
    private var localDevice: String { transport.device }
    /// Rechecks channel/cohort incarnation and retained metadata selection.
    /// NOT a tensor payload-hash receipt; native SDK LOAD remains authoritative.
    private let requireCurrentAuthenticatedCustody: () throws -> Void
    private let lock = NSRecursiveLock()
    private let launchQueue = DispatchQueue(label: "darkbloom.glm.finite-owner.launch")
    private let bootstrapQueue = DispatchQueue(label: "darkbloom.glm.finite-owner.bootstrap")
    private var phase: Phase = .prepared
    private var cancelled = false, launchAttempted = false, bootstrapCompleted = false
    private var failure: String?
    private var launchCheckpoint: LaunchCheckpoint = .notQueued
    private var admission: GLM5NextCalibrationNativeStart.Admission?
    private var committed: GLM5NextCalibrationNativeStart.Committed?
    private var context: CommitContext?
    private var attachment: ClusterOwnerBootstrapAttachment?
    private var child: ClusterCalibrationProcess?
    private var exitObservation: ActualExit?

    static func prepare(completed: CompletedQuote, peer: GLM5NextCalibrationPeerQuote.PeerAdmitted,
                        requireCurrentAuthenticatedCustody: @escaping () throws -> Void) throws -> GLM5NextCalibrationInstalledOwner {
        try prepare(completed: completed, peer: peer, environment: .production(),
            requireCurrentAuthenticatedCustody: requireCurrentAuthenticatedCustody)
    }

    /// Explicit isolated path/probe seam; no injected authorization, process,
    /// Completed, peer grant, report, kernel-lock success or bootstrap success.
    static func prepare(completed: CompletedQuote, peer: GLM5NextCalibrationPeerQuote.PeerAdmitted,
                        environment: Resources.Environment,
                        requireCurrentAuthenticatedCustody: @escaping () throws -> Void) throws -> GLM5NextCalibrationInstalledOwner {
        let deadline = try finiteDeadline(expires: completed.authorized.request.selection.expiresUnixSeconds)
        let resources = try Resources(environment: environment, deadline: deadline)
        do {
            let transport = try resources.retainMatrix(completed: completed, deadline: deadline)
            let device = transport.device
            func current() throws {
                try resources.requireHeld()
                try completed.requireUnchanged(deadline: deadline)
                try requireCurrentAuthenticatedCustody()
                try environment.requirePhysicalInterface(device, completed.pair.record.link.localInterface)
                try resources.requireHeld()
            }
            try current()
            let authorized = try peer.authorizeOwn(completed: completed, now: unixNow(), deadline: deadline,
                requireHeldExclusionAndCustody: current)
            try resources.write(authorized)
            try current()
            let owner = GLM5NextCalibrationInstalledOwner(quotation: completed, authorized: authorized,
                deadline: deadline, resources: resources, transport: transport,
                requireCurrentAuthenticatedCustody: requireCurrentAuthenticatedCustody)
            // Started before exposing the owner, covering caller drop even
            // before launch. This task owns ALL resources, not just the pumps.
            Task {
                await owner.retainUntilSafeRetirement()
                withExtendedLifetime(owner) {}
            }
            return owner
        } catch {
            // No journal/spawn has been attempted during prepare.
            try? resources.retireAfterExitOrNoLaunch()
            throw error
        }
    }

    private init(quotation: CompletedQuote, authorized: GLM5NextCalibrationAuthorizer.Authorized,
                 deadline: UInt64, resources: Resources, transport: Resources.TransportSelection,
                 requireCurrentAuthenticatedCustody: @escaping () throws -> Void) {
        self.quotation = quotation; self.authorized = authorized; self.resources = resources
        outboundDocument = authorized.document; experimentDeadline = deadline; self.transport = transport
        self.requireCurrentAuthenticatedCustody = requireCurrentAuthenticatedCustody
    }

    func admit(peerDocument: Data) throws -> ClusterNativeAuthorizationStart {
        try lock.withLock {
            guard phase == .prepared, !cancelled else { throw invalid("Finite admission already consumed or cancelled") }
            try requireBoundary()
            let value = try GLM5NextCalibrationNativeStart.admit(completed: quotation,
                localAuthorization: authorized, peerDocument: peerDocument, now: Self.unixNow(), deadline: experimentDeadline)
            admission = value; phase = .admitted
            return value.localStart
        }
    }

    func commit(peerStart: ClusterNativeAuthorizationStart) throws -> CommitContext {
        try lock.withLock {
            guard phase == .admitted, !cancelled, var admission else { throw invalid("Finite commit is unavailable") }
            try requireBoundary()
            let value = try admission.commit(peerStart: peerStart, now: Self.unixNow(), deadline: experimentDeadline)
            let local = value.starts[value.localRank]
            let binding = try ClusterOwnerBinding(clusterID: quotation.pair.clusterID,
                ownerIncarnation: local.ownerIncarnation, leaseID: local.leaseID,
                identity: value.identity, profile: value.profile, rank: value.localRank,
                executionPlanSHA256: value.executionPlanSHA256)
            let context = CommitContext(requestID: authorized.body.authorization.requestID,
                expiresUnixSeconds: authorized.body.selection.expiresUnixSeconds,
                starts: value.starts, binding: binding, transport: transport)
            self.admission = nil; committed = value; self.context = context; phase = .committed
            return context
        }
    }

    /// Queues one attempt; returns promptly to the authenticated serial responder.
    /// REQUIRED callback authenticates BOTH exact commits on the existing exact-
    /// pair channel, checking current edge/epoch/cohort/incarnations. No default,
    /// Boolean grant, remote Completed or pretend transport proof is supplied.
    func launch(requireBothAuthenticatedCommits: @escaping RequireBothAuthenticatedCommits,
                publish: @escaping Publish) throws {
        try lock.withLock {
            guard phase == .committed, !launchAttempted, !cancelled, context != nil else {
                throw invalid("Duplicate or unavailable finite launch")
            }
            launchAttempted = true; phase = .launchQueued
        }
        launchQueue.async { [self] in
            do { try launchOnOwnerQueue(requireBothAuthenticatedCommits: requireBothAuthenticatedCommits, publish: publish) }
            catch {
                lock.withLock {
                    if failure == nil { failure = "launch-refused" }
                    // A launch() throw from the actual supervisor proves no
                    // spawn. If a child exists, only its exit waiter retires it.
                    if child == nil { retireNoLaunchLocked() }
                }
                // Fixed vocabulary only: never print the caught error, paths,
                // environment, documents, credentials or child output.
                let diagnostic = lock.withLock {
                    "darkbloom-glm-finite-launch-v1 rank=\(authorized.body.selection.rank) checkpoint=\(launchCheckpoint.rawValue)\n"
                }
                try? FileHandle.standardError.write(contentsOf: Data(diagnostic.utf8))
            }
        }
    }

    private func checkpoint(_ value: LaunchCheckpoint) {
        lock.withLock { launchCheckpoint = value }
    }

    private func launchOnOwnerQueue(requireBothAuthenticatedCommits: RequireBothAuthenticatedCommits,
                                    publish: @escaping Publish) throws {
        checkpoint(.localContext)
        let context = try lock.withLock { () throws -> CommitContext in
            guard !cancelled, phase == .launchQueued, let context else { throw invalid("Finite launch cancelled") }
            try requireBoundary()
            return context
        }
        // Never hold the owner mutex across transport/peer work. Cancellation
        // remains available; the dispatcher must bound this callback by deadline.
        checkpoint(.peerCommits)
        try requireBothAuthenticatedCommits(quotation.pair, context, experimentDeadline)
        let launched: (ClusterCalibrationProcess, ClusterOwnerBootstrapAttachment) = try {
            try lock.withLock {
                guard !cancelled, phase == .launchQueued else { throw invalid("Finite launch cancelled") }
            }
            checkpoint(.currentBeforeSetup)
            try requireBoundary()
            checkpoint(.orphanCheck)
            try resources.environment.orphanCheck()
            checkpoint(.linkReady)
            try resources.environment.linkReady(localDevice)
            checkpoint(.currentBeforeAttachment)
            try requireBoundary()
            checkpoint(.attachment)
            let bootstrapNow = DispatchTime.now().uptimeNanoseconds
            guard experimentDeadline > bootstrapNow else { throw invalid("Finite bootstrap has expired") }
            let bootstrapDeadline = bootstrapNow + min(experimentDeadline - bootstrapNow,
                ClusterOwnerBootstrapAttachment.maximumBootstrapNanoseconds)
            let attachment = try ClusterOwnerBootstrapAttachment.calibration(profile: .nativeKeyPreludeMesh2,
                deadline: bootstrapDeadline, experimentDeadline: experimentDeadline, nativeStart: context.localStart)
            lock.withLock { self.attachment = attachment }
            guard let document = resources.document else { throw invalid("Owned finite document is unavailable") }
            let now = DispatchTime.now().uptimeNanoseconds
            let lease = now + ClusterWorkerLease.ttlNanoseconds
            checkpoint(.launchSpecification)
            let launch = try GLM5NextCalibrationLaunch.prepare(authorized: authorized,
                binding: context.binding, document: document,
                installedApp: quotation.installedExecutable, appSHA256: quotation.authorized.request.appSHA256,
                worker: quotation.worker, metallib: quotation.metallib, modelDirectory: quotation.modelDirectory,
                environment: quotation.environment, attachment: attachment,
                leaseDeadline: lease, experimentDeadline: experimentDeadline, nowUptime: now,
                nowUnix: Self.unixNow(), requireCurrentSelection: { try self.requireBoundary() })
            checkpoint(.supervisorSpecification)
            let signed = try JSONDecoder().decode(GLM5NextCalibrationDocument.SignedDocument.self, from: authorized.document)
            let process = try ClusterCalibrationProcess(launch: launch, expectedIdentity: context.binding.identity,
                rank: context.binding.rank, profile: context.binding.profile,
                executionPlanSHA256: context.binding.executionPlanSHA256,
                authorizationSHA256: Self.hash(signed.payload),
                normalizedConfigurationSHA256: quotation.response.normalizedConfigurationSHA256,
                environmentSHA256: quotation.response.executionEnvironmentSHA256,
                initialLeaseDeadline: lease, experimentDeadline: experimentDeadline,
                // Conservative retirement sizing only, never a payload receipt.
                // At least signed physical memory, even for metadata-only fixtures.
                plannedBytes: try plannedRetirementBytes())
            checkpoint(.currentBeforeJournal)
            try requireBoundary()
            checkpoint(.journal)
            try resources.record(binding: context.binding, launchID: context.localStart.launchID)
            // Last checks after durable journal and immediately before spawn.
            try lock.withLock {
                guard !cancelled, phase == .launchQueued else { throw invalid("Finite launch cancelled") }
                checkpoint(.currentBeforeSpawn)
                try requireBoundary()
                checkpoint(.documentBeforeSpawn)
                try GLM5NextCalibrationLaunch.verifyDocument(document, authorized: authorized, deadline: experimentDeadline).requireUnchanged()
                checkpoint(.processLaunch)
                try process.launch()
                child = process; phase = .running
                checkpoint(.running)
            }
            return (process, attachment)
        }()
        bootstrapQueue.async { [self, process = launched.0, attachment = launched.1] in
            do {
                try requireBoundary()
                try attachment.runCalibration(child: process, binding: context.binding) { [self] sequence, bytes in
                    // publish must enqueue/ack bounded existing relay work. It
                    // must not block the serial service responder awaiting peers.
                    try requireBoundary()
                    try publish(context, sequence, bytes)
                }
                lock.withLock { bootstrapCompleted = true }
            } catch {
                lock.withLock { if failure == nil { failure = "bootstrap-failed" } }
                attachment.cancelCalibration(); process.cancel()
            }
        }
    }

    /// Existing attachment owns native prelude/mesh validation, sequencing and
    /// local contribution checks; this layer does not implement any key protocol.
    func acceptBootstrapReply(sequence: UInt64, bytes: Data) throws {
        do {
            let value = try lock.withLock { () throws -> ClusterOwnerBootstrapAttachment in
                guard phase == .running, !cancelled, bytes.count <= 131_072, let attachment else {
                    throw invalid("Finite bootstrap reply is unavailable")
                }
                try requireBoundary()
                return attachment
            }
            try value.acceptCalibrationReply(sequence: sequence, bytes: bytes)
        } catch {
            lock.withLock { if failure == nil { failure = "bootstrap-reply-refused" } }
            cancel() // Fence the child; resources still wait for its actual exit.
            throw error
        }
    }

    func cancel() {
        let values = lock.withLock { () -> (ClusterCalibrationProcess?, ClusterOwnerBootstrapAttachment?) in
            if phase == .retired { return (nil, bootstrapCompleted ? nil : attachment) }
            cancelled = true
            if child == nil, phase != .launchQueued { retireNoLaunchLocked() }
            return (child, attachment)
        }
        values.1?.cancelCalibration(); values.0?.cancel()
    }

    func status() -> Status {
        lock.withLock {
            Status(phase: phase, requestID: authorized.body.authorization.requestID,
                rank: authorized.body.selection.rank, launchAttempted: launchAttempted, cancelled: cancelled,
                bootstrapCompleted: bootstrapCompleted, observedExit: child?.observedExit == true,
                provisionalReportReceived: child?.provisionalReport != nil,
                journalResolved: resources.retired, failure: failure, launchCheckpoint: launchCheckpoint)
        }
    }
    func actualExit() -> ActualExit? { lock.withLock { exitObservation } }

    func completed() throws -> GLM5NextCalibrationReport.Report {
        let values = try lock.withLock { () throws -> (ClusterCalibrationProcess, ClusterOwnerBootstrapAttachment) in
            guard !cancelled, failure == nil, bootstrapCompleted,
                  let child, let attachment, child.observedExit else { throw invalid("Finite completion remains provisional or failed") }
            return (child, attachment)
        }
        try values.1.requireCalibrationCompleted()
        return try GLM5NextCalibrationReport.completed(child: values.0, authorized: authorized, quotation: quotation)
    }

    /// Called under the owner mutex. Neither the original quotation timeout nor
    /// renewable rank lease can extend this owner's independent finite deadline.
    private func requireBoundary() throws {
        let native = try lock.withLock { () throws -> (GLM5NextCalibrationNativeStart.Committed?, CommitContext?) in
            guard !cancelled, !resources.retired else { throw invalid("Finite ownership is unavailable") }
            return (committed, context)
        }
        try DistributedInstalledFiles.check(experimentDeadline)
        try resources.requireHeld()
        try quotation.requireUnchanged(deadline: experimentDeadline)
        try requireCurrentAuthenticatedCustody()
        try resources.environment.requirePhysicalInterface(localDevice, quotation.pair.record.link.localInterface)
        if let committed = native.0, let context = native.1 { try committed.validateLocalStart(context.localStart, now: Self.unixNow()) }
        if let document = resources.document {
            try GLM5NextCalibrationLaunch.verifyDocument(document, authorized: authorized, deadline: experimentDeadline).requireUnchanged()
        }
        try resources.requireHeld()
        try DistributedInstalledFiles.check(experimentDeadline)
    }

    private func retainUntilSafeRetirement() async {
        while true {
            let state = lock.withLock { (child, phase) }
            if state.1 == .retired { return }
            if let child = state.0 {
                // No timeout: unobserved exit retains resources indefinitely.
                if await child.waitUntilExited() {
                    observeExit(child)
                    if lock.withLock({ phase == .retired }) { return }
                }
                // Failed journal resolution remains sticky even after exit.
                while true {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    withExtendedLifetime(self) {}
                }
            }
            if state.1 == .unresolved {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }
            if DispatchTime.now().uptimeNanoseconds >= experimentDeadline { cancel() }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func observeExit(_ process: ClusterCalibrationProcess) {
        lock.withLock {
            guard process === child, process.observedExit,
                  let termination = process.termination, let context else { return }
            if exitObservation == nil, termination != .exited(0) {
                // [DEBUG-private-glm-native-exit-20261018] Temporary qualification capture.
                let diagnostic = process.diagnosticTail
                let prefix = "[DEBUG-private-glm-native-exit-20261018] rank=\(authorized.body.selection.rank) bytes=\(diagnostic.count)\n"
                try? FileHandle.standardError.write(contentsOf: Data(prefix.utf8))
                try? FileHandle.standardError.write(contentsOf: diagnostic)
                try? FileHandle.standardError.write(contentsOf: Data("\n[DEBUG-private-glm-native-exit-20261018] end\n".utf8))
            }
            let observed = DispatchTime.now().uptimeNanoseconds
            do { try resources.retireAfterExitOrNoLaunch(); phase = .retired }
            catch { phase = .unresolved; if failure == nil { failure = "journal-unresolved" } }
            exitObservation = ActualExit(context: context, termination: termination,
                observedAtUptimeNanoseconds: observed, localJournalResolved: resources.retired)
            // Local retirement says nothing about the peer's process or report.
        }
    }
    private func retireNoLaunchLocked() {
        guard child == nil, !resources.retired, phase != .unresolved else { return }
        attachment?.cancelCalibration()
        do { try resources.retireAfterExitOrNoLaunch(); phase = .retired }
        catch { phase = .unresolved; if failure == nil { failure = "journal-unresolved" } }
    }
    private func plannedRetirementBytes() throws -> UInt64 {
        var total: UInt64 = 0
        for file in authorized.body.selection.files.values {
            guard file.bytes > 0 else { throw invalid("Invalid signed file length") }
            let sum = total.addingReportingOverflow(UInt64(file.bytes))
            guard !sum.overflow else { throw invalid("Signed file lengths overflow retirement bound") }
            total = sum.partialValue
        }
        return max(total, UInt64(authorized.body.selection.environment.memoryBytes))
    }
    private static func finiteDeadline(expires: Int64) throws -> UInt64 {
        let remaining = min(Double(ClusterWorkerLimits.deadlineNanoseconds) / 1_000_000_000,
            Double(expires) - Date().timeIntervalSince1970 - 1)
        guard remaining > 0 else { throw GLM5NextCalibrationDocument.invalid("Finite experiment has expired") }
        return DispatchTime.now().uptimeNanoseconds + UInt64(remaining * 1_000_000_000)
    }
    private static func unixNow() -> Int64 { Int64(Date().timeIntervalSince1970) }
    private static func hash(_ value: Data) -> String { SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined() }
    private func invalid(_ message: String) -> ClusterConfigurationError { GLM5NextCalibrationDocument.invalid(message) }
}
