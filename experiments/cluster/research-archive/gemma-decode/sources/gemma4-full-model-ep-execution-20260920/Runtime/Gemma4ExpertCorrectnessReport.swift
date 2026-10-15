import Foundation

/// Exact bounded encoder shared by live publication and the CPU size fixture.
enum Gemma4ExpertCorrectnessReport {
    static let limit = 1_048_576
    static func intermediate(input: Gemma4ExpertCorrectnessInput,
                             expected: Gemma4ExpertCorrectnessDescription,
                             execution: [String:Any], observations: [Gemma4ExpertExchangeObservation],
                             sentTensorBytes: Int, receivedTensorBytes: Int,
                             controlRecordsSent: Int, controlRecordsReceived: Int) throws -> Data {
        guard observations.count == (input.job.rank == nil ? 0 : 150),
              sentTensorBytes >= 0, receivedTensorBytes >= 0,
              controlRecordsSent == (input.job.rank == nil ? 0 : Gemma4ExpertResourceTerms.expectedControlRecords),
              controlRecordsReceived == controlRecordsSent else {
            throw ProbeError("Gemma EP report lacks its complete exchange evidence")
        }
        return try encode(["schema":"gemma4_full_expert_result_v1", "mode":input.job.mode,
            "expected":try JSONSerialization.jsonObject(with: canonicalJSONData(expected)),
            "execution":execution, "modelReleased":true,
            "exchangeObservations":try JSONSerialization.jsonObject(with: canonicalJSONData(observations)),
            "sentTensorBytes":sentTensorBytes, "receivedTensorBytes":receivedTensorBytes,
            "controlRecordsSent":controlRecordsSent, "controlRecordsReceived":controlRecordsReceived,
            "nativeExecuted":true, "collectiveCreated":input.job.rank != nil,
            "physicalProcessOrLeaseRetirementEstablished":false, "runtimeServingEnabled":false,
            "numericalComparisonPerformed":false, "throughputMeasurementValid":false,
            "encryptedRDMAEstablished":false])
    }
    static func finish(_ intermediate: Data, resources: Gemma4ShortResourceReceipt,
                       collectiveCreated: Bool, cacheBytes: Int) throws -> Data {
        guard cacheBytes == 0, var report = try JSONSerialization.jsonObject(with: intermediate) as? [String:Any] else {
            throw ProbeError("Gemma EP final report type/cache retirement differs")
        }
        report["resources"] = try JSONSerialization.jsonObject(with: canonicalJSONData(resources))
        report["collectiveReleased"] = collectiveCreated
        report["nativeCacheBytesAfterRelease"] = cacheBytes
        return try encode(report)
    }
    private static func encode(_ report: [String:Any]) throws -> Data {
        let encoded = try JSONSerialization.data(withJSONObject: report, options:[.sortedKeys,.withoutEscapingSlashes])
        guard encoded.count <= limit else { throw ProbeError("Gemma EP report exceeds fixed output bound") }
        return encoded
    }
}
