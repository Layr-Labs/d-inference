import Foundation
import DarkbloomClusterProtocol
import DarkbloomClusterProcess

struct CancellationObservation: Codable {
    let phase: String, membershipEpoch: String, requestID: String
    var reservedBytes = 0, bytesAfterEarlyRelease: Int?, bytesAfterRelease: Int?
    var startCalled: UInt64?, cancelCalled: UInt64?, retirementObserved: UInt64?, resourcesReleased: UInt64?
    var tokenIDs: [Int] = [], tokenCountAtCancel: Int?, phaseMatched = false, pairUnavailableAfterCancel = false
    var retiredBeforeCancel: Bool?, finishReason: String?, failureCallback: String?, failure: String?
    var nativeCleanupObserved: [Bool] = [], ownerLeaseReleaseObserved: [Bool] = []
    var cleanupCompleted: UInt64?, ownerLeaseDrainCompleted: UInt64?, completed = false
    var object: [String: Any] { get throws { try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as! [String: Any] } }
}

/// The request callback is synchronous. Cancel at token ordinal 1 is observed
/// by ClusterWorkerRequest before it can send the next token decision.
final class CancellationCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var record: CancellationObservation
    private let expected: [Int]
    private let selectedCase: CancellationCase?
    init(_ record: CancellationObservation, expected: [Int], selectedCase: CancellationCase?) {
        self.record = record; self.expected = expected; self.selectedCase = selectedCase
    }
    var snapshot: CancellationObservation { lock.withLock { record } }
    func markStart() { lock.withLock { record.startCalled = DispatchTime.now().uptimeNanoseconds } }

    func cancel(_ request: ClusterWorkerRequest, pair: ClusterWorkerPair) {
        let perform = lock.withLock { () -> Bool in
            guard record.cancelCalled == nil else { return false }
            record.cancelCalled = DispatchTime.now().uptimeNanoseconds
            record.tokenCountAtCancel = record.tokenIDs.count; record.retiredBeforeCancel = request.isRetired
            let count = selectedCase == .startedBeforeFirstToken ? 0 : 2
            record.phaseMatched = record.startCalled != nil && !request.isRetired && record.finishReason == nil
                && record.failure == nil && record.tokenIDs.count == count
            // Deliberately exercise release before proof; the actual request
            // must retain its charge until acknowledged retirement/native exit.
            request.releaseResources(); record.bytesAfterEarlyRelease = request.bytesInUse
            if !record.phaseMatched || record.bytesAfterEarlyRelease != record.reservedBytes {
                record.failure = record.failure ?? "Selected active cancellation phase or retained charge was not observed"
            }
            return true
        }
        guard perform else { return }
        request.cancel(reason: .callerCancelled)
        lock.withLock { record.pairUnavailableAfterCancel = pair.readiness == nil }
    }

    func accept(_ event: ClusterWorkerRequestEvent, request: ClusterWorkerRequest, pair: ClusterWorkerPair) -> Bool {
        let cancelNow = lock.withLock { () -> Bool in
            switch event {
            case .token(let token):
                let index = record.tokenIDs.count
                record.tokenIDs.append(token)
                if index >= expected.count || expected[index] != token {
                    record.failure = "Selected-token prefix differs from declared sequence"; return true
                }
                if selectedCase == .startedBeforeFirstToken, record.cancelCalled == nil {
                    record.failure = "First token arrived before the selected cancellation delay"; return true
                }
                return selectedCase == .afterFirstDecode && record.tokenIDs.count == 2
            case .finished(let reason): record.finishReason = reason.rawValue
            case .failed(let message): record.failureCallback = String(message.prefix(2048))
            }
            return false
        }
        if cancelNow { cancel(request, pair: pair) }
        return true // Abnormal cancel uses cancel(), never a fabricated clean stop.
    }
}
