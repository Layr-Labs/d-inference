import DarkbloomClusterProtocol
import DarkbloomClusterRuntime
import DarkbloomClusterSecurity
import Foundation

/// Private qualification adapter. Cancellation is the resident's thread-safe
/// operation; every other method stays on the worker's native executor.
final class GLM5NextWorkerRuntime: WorkerRuntime, @unchecked Sendable {
    private let owner: GLM5NextResidentRuntime
    private let attachment: WorkerOwnerAttachment?

    init(configuration: WorkerConfiguration, document: String,
         credential: ClusterDataPlaneCredential, attachment: WorkerOwnerAttachment?) throws {
        let prepared = try GLM5NextWorkerQualification.prepare(path: document,
            configuration: configuration, credential: credential)
        self.attachment = attachment
        owner = try .init(configuration: configuration.load, descriptor: prepared.descriptor,
            resources: prepared.resources)
        // Retain the bootstrap attachment and owner even if load throws. This
        // worker has no peer-fence receipt; process exit is its cleanup authority.
        Self.quarantine.retain(owner, attachment)
        try owner.load(dataPlane: credential)
        try JACCLOwnerBootstrap.requireConsumedIfInstalled()
    }
    var readiness: ClusterWorkerReady? { owner.readiness }
    func reserve(_ id: UUID, _ value: ClusterWorkerReservation) throws -> Int {
        try owner.reserve(requestID: id, request: value)
    }
    func start(_ id: UUID, token: (Int, Int, Int) throws -> Bool) throws -> ClusterWorkerFinishReason {
        let result = try owner.start(requestID: id, onCommittedToken: token)
        guard result.bothRequestStatesRetired else {
            throw WorkerFailure.invalid("GLM request did not retire both peer states")
        }
        return result.finishReason
    }
    func cancel(_ id: UUID) { owner.cancel(requestID: id) }
    func releaseReservation(_ id: UUID) throws { try owner.releaseReservation(requestID: id) }
    func shutdown() throws { throw Self.shutdownRefusal() }
    static func shutdownRefusal() -> WorkerFailure {
        .invalid("GLM worker has no authenticated peer-fence receipt; retain resident roots and terminate process")
    }
    func keepWarmPulse() throws -> UInt64 {
        throw WorkerFailure.invalid("GLM private qualification does not implement keep-warm pulses")
    }
    func dataPlanePing() throws -> UInt64 {
        throw WorkerFailure.invalid("GLM private qualification does not implement idle data-plane pings")
    }

    private static let quarantine = Quarantine()
    private final class Quarantine: @unchecked Sendable {
        private let lock = NSLock()
        private var roots: [AnyObject] = []
        func retain(_ owner: GLM5NextResidentRuntime, _ attachment: WorkerOwnerAttachment?) {
            lock.lock(); defer { lock.unlock() }
            roots.append(owner)
            if let attachment { roots.append(attachment) }
        }
    }
}
