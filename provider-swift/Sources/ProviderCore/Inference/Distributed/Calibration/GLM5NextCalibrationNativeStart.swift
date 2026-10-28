import CryptoKit
import Foundation
import DarkbloomClusterProtocol
import DarkbloomClusterSecurity

/// Owner-local admission only. No launch, lease, custody, serving capability or
/// native key is created. BOTH owners must call this with their own Completed,
/// exchange their exact documents/starts, and commit before bootstrap.
/// Prior finite signing must separately admit the authenticated peer quotation
/// summary/actual-exit claim. This factory cannot observe a remote process exit
/// and does not reconstruct peer Authorized or Completed values.
enum GLM5NextCalibrationNativeStart {
    private typealias D = GLM5NextCalibrationDocument

    static func admit(completed: GLM5NextCalibrationInstalledQuote.Completed,
                      localAuthorization: GLM5NextCalibrationAuthorizer.Authorized,
                      peerDocument: Data, now: Int64, deadline: UInt64) throws -> Admission {
        let common = try derive(completed: completed, localAuthorization: localAuthorization,
            peerDocument: peerDocument, now: now, deadline: deadline)
        // Local UUIDs are minted once. No leader supplies the other owner's
        // incarnation/lease/launch. All six are checked at commit.
        let start = try ClusterNativeAuthorizationStart(common: common,
            rank: localAuthorization.body.selection.rank, ownerIncarnation: UUID(), leaseID: UUID(), launchID: UUID())
        return Admission(common: common, localStart: start, completed: completed,
            localAuthorization: localAuthorization, peerDocument: peerDocument)
    }

    struct Admission {
        let common: ClusterNativeAuthorizationCommon
        let localStart: ClusterNativeAuthorizationStart
        private let completed: GLM5NextCalibrationInstalledQuote.Completed
        private let localAuthorization: GLM5NextCalibrationAuthorizer.Authorized
        private let peerDocument: Data
        // Shared by value copies of Admission: copying cannot reset consumption.
        private let consumption = Consumption()

        fileprivate init(common: ClusterNativeAuthorizationCommon, localStart: ClusterNativeAuthorizationStart,
                         completed: GLM5NextCalibrationInstalledQuote.Completed,
                         localAuthorization: GLM5NextCalibrationAuthorizer.Authorized, peerDocument: Data) {
            self.common = common; self.localStart = localStart; self.completed = completed
            self.localAuthorization = localAuthorization; self.peerDocument = peerDocument
        }

        mutating func commit(peerStart: ClusterNativeAuthorizationStart, now: Int64, deadline: UInt64) throws -> Committed {
            try consumption.once {
                let current = try GLM5NextCalibrationNativeStart.derive(completed: completed,
                    localAuthorization: localAuthorization, peerDocument: peerDocument, now: now, deadline: deadline)
                guard current.canonicalBytes == common.canonicalBytes,
                      peerStart.common.canonicalBytes == current.canonicalBytes,
                      peerStart.rank == 1 - localStart.rank else { throw ClusterNativeKeyError.wrongContext }
                let starts = localStart.rank == 0 ? [localStart, peerStart] : [peerStart, localStart]
                let nonces = starts.flatMap { [$0.ownerIncarnation, $0.leaseID, $0.launchID] }
                guard Set(nonces).count == 6 else { throw ClusterNativeKeyError.invalidBinding }
                return Committed(identity: localAuthorization.identity,
                    profile: localAuthorization.body.binding.profile.workerProfile,
                    executionPlanSHA256: localAuthorization.body.binding.executionPlanSHA256,
                    starts: starts, localRank: localStart.rank, completed: completed)
            }
        }
    }

    struct Committed {
        let identity: ClusterWorkerIdentity
        let profile: ClusterWorkerProfile
        let executionPlanSHA256: String
        let starts: [ClusterNativeAuthorizationStart]
        let localRank: Int
        private let completed: GLM5NextCalibrationInstalledQuote.Completed

        fileprivate init(identity: ClusterWorkerIdentity, profile: ClusterWorkerProfile, executionPlanSHA256: String,
                         starts: [ClusterNativeAuthorizationStart], localRank: Int,
                         completed: GLM5NextCalibrationInstalledQuote.Completed) {
            self.identity = identity; self.profile = profile; self.executionPlanSHA256 = executionPlanSHA256
            self.starts = starts; self.localRank = localRank; self.completed = completed
        }

        /// Supply this independent-owner check to the existing native prelude.
        /// Parent dispatcher still owns exclusion, bounded lease, exact-once
        /// launch/request, cancellation, actual exit and journal resolution.
        func validateLocalStart(_ start: ClusterNativeAuthorizationStart, now: Int64) throws {
            guard start.rank == localRank, start.canonicalBytes == starts[localRank].canonicalBytes,
                  case .finiteCalibrationV1(let finite) = start.common.permission,
                  now >= 0, now < finite.expiresUnixSeconds else { throw ClusterNativeKeyError.wrongContext }
            // A new short check deadline, not the expired quotation deadline.
            // requireUnchanged bounds it against the actual wall clock too.
            let seconds = UInt64(min(5, finite.expiresUnixSeconds - now))
            try completed.requireUnchanged(deadline: DispatchTime.now().uptimeNanoseconds + seconds * 1_000_000_000)
        }
    }

    private final class Consumption {
        private let lock = NSLock()
        private var consumed = false
        func once<T>(_ body: () throws -> T) throws -> T {
            lock.lock(); defer { lock.unlock() }
            guard !consumed else { throw ClusterNativeKeyError.alreadyConsumed }
            let value = try body(); consumed = true; return value
        }
    }

    private static func derive(completed: GLM5NextCalibrationInstalledQuote.Completed,
                               localAuthorization: GLM5NextCalibrationAuthorizer.Authorized,
                               peerDocument: Data, now: Int64, deadline: UInt64) throws -> ClusterNativeAuthorizationCommon {
        try completed.requireUnchanged(deadline: deadline)
        let expected = try GLM5NextCalibrationQuoteAuthorizer.experimentBody(response: completed.responseData,
            authorized: completed.authorized, now: now, expectedVocabularySize: completed.pinnedVocabularySize)
        guard localAuthorization.identity == completed.authorized.identity,
              localAuthorization.expectedVocabularySize == completed.pinnedVocabularySize,
              try canonical(localAuthorization.body) == canonical(expected) else {
            throw D.invalid("Finite authorization differs from the actual completed local quotation")
        }
        let common = try GLM5NextCalibrationNativeDocuments.common(
            documents: localAuthorization.body.selection.rank == 0
                ? [localAuthorization.document, peerDocument] : [peerDocument, localAuthorization.document],
            identity: localAuthorization.identity, pair: completed.pair,
            localRank: localAuthorization.body.selection.rank,
            expectedVocabularySize: completed.pinnedVocabularySize, now: now)
        try completed.requireUnchanged(deadline: deadline)
        return common
    }

    fileprivate static func canonical<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}
