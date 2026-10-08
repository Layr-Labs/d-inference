import Foundation
import DarkbloomClusterProcess

struct TimingObservation: Encodable, Sendable {
    let requestID: String, phase: String, iteration: Int
    var reserveBegan: UInt64
    var reserveCompleted: UInt64?
    var startCalled: UInt64?
    var firstToken: UInt64?
    var finalToken: UInt64?
    var finishedCallback: UInt64?
    var retirementObserved: UInt64?
    var resourcesReleased: UInt64?
    var tokenIDs: [Int] = []
    var firstTokenCount: Int?
    var finalTokenCount: Int?
    var finishReason: String?
    var failure: String?
    var completed = false
    var sequenceGuardMatched = false
    var bytesInUseAfterRelease: Int?
    var internalOwnerControlFirstTokenNanoseconds: UInt64?

    mutating func validateCompleted(expected: [Int]) throws {
        guard let reserveCompleted, let startCalled, let firstToken, let finalToken, let finishedCallback,
              let retirementObserved, let resourcesReleased,
              reserveBegan <= reserveCompleted, reserveCompleted <= startCalled, startCalled <= firstToken,
              firstToken <= finalToken, finalToken <= finishedCallback, finishedCallback <= retirementObserved,
              retirementObserved <= resourcesReleased, tokenIDs.count == 128, tokenIDs == expected,
              firstTokenCount == 1, finalTokenCount == 128, finishReason == "length", failure == nil,
              bytesInUseAfterRelease == 0 else { throw QualificationFailure.invalid("Incomplete timing/token/retirement observation") }
        internalOwnerControlFirstTokenNanoseconds = firstToken - startCalled
        sequenceGuardMatched = true; completed = true
    }
    var object: [String: Any] {
        get throws { try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as! [String: Any] }
    }
}

final class TimingCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let expected: [Int]
    private var observation: TimingObservation
    init(_ observation: TimingObservation, expected: [Int]) { self.observation = observation; self.expected = expected }
    func markStart(_ value: UInt64) { lock.withLock { observation.startCalled = value } }
    func accept(_ event: ClusterWorkerRequestEvent, at now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Bool {
        lock.withLock {
            switch event {
            case .token(let id):
                let ordinal = observation.tokenIDs.count
                guard ordinal < 128 else { observation.failure = "Too many committed tokens"; return false }
                if ordinal == 0 { observation.firstToken = now; observation.firstTokenCount = ordinal + 1 }
                observation.tokenIDs.append(id)
                if ordinal == 127 { observation.finalToken = now; observation.finalTokenCount = ordinal + 1 }
                if id != expected[ordinal] { observation.failure = "Committed token differs from declared sequence guard" }
            case .finished(let reason): observation.finishedCallback = now; observation.finishReason = reason.rawValue
            case .failed(let message): observation.failure = observation.failure ?? String(message.prefix(2048))
            }
            return observation.failure == nil
        }
    }
    var snapshot: TimingObservation { lock.withLock { observation } }
}

func timingSummary(_ records: [TimingObservation], warmups: Int, measured: Int) -> [String: Any] {
    let selected = records.filter { $0.phase == "measured" && $0.completed && $0.sequenceGuardMatched }
    let complete = records.count == warmups + measured && records.allSatisfy(\.completed) && selected.count == measured
    var result: [String: Any] = ["complete": complete, "declaredWarmupCount": warmups, "declaredMeasuredCount": measured,
        "completeMeasuredCount": selected.count, "warmupsExcluded": true, "partialRecordsRetained": true,
        "policyEngagementIndependentlyVerified": false, "fullNumericalComparisonPerformed": false,
        "performanceQualification": false, "externalTTFTMeasured": false, "providerCapacityUpdated": false]
    if complete {
        let values = selected.compactMap(\.internalOwnerControlFirstTokenNanoseconds).sorted()
        if values.count == measured {
            result["measuredInternalOwnerControlFirstTokenNanoseconds"] = values
            result["medianInternalOwnerControlFirstTokenNanoseconds"] = values.count % 2 == 1
                ? Double(values[values.count / 2]) : Double(values[values.count / 2 - 1]) / 2 + Double(values[values.count / 2]) / 2
        }
    }
    return result
}
