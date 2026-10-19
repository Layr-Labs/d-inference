import CryptoKit
import Foundation
import DarkbloomClusterProcess
import DarkbloomClusterProtocol

/// Detailed local result validation. Pair completion still requires the peer's
/// authenticated report and actual exit; no serving or resource refund is minted.
enum GLM5NextCalibrationReport {
    struct Quote: Codable {
        let authorizationSHA256: String
        let descriptorSHA256: String
        let cut: Int
        let rank: Int
        let nativeBytes: Int
        let hostBytes: Int
        let loadCapacityBytes: Int
        let requestCapacityBytes: Int
        let inventorySHA256: String
        let configurationSHA256: String
        let numericalPolicySHA256: String
        let executionEnvironmentSHA256: String
        let qualifiesMaximumEnvelope: Bool
    }
    struct Host: Codable { let mallocBytes: Int; let processFootprintBytes: Int }
    struct Observation: Codable {
        let phase: String
        let nativeActiveBytes: Int
        let nativePeakBytes: Int
        let host: Host
    }
    struct Report: Codable {
        let nativeHardCapBytes: Int
        let hostBudgetBytes: Int
        let osHeadroomBytes: Int
        let quote: Quote
        let observations: [Observation]
        let committedTokens: Int
        let qualifiesMaximumEnvelope: Bool
        let requiresProcessExit: Bool
    }

    static func completed(child: ClusterCalibrationProcess,
                          authorized: GLM5NextCalibrationAuthorizer.Authorized,
                          quotation: GLM5NextCalibrationInstalledQuote.Completed) throws -> Report {
        // The supervisor enforces drained stdout and directly observed zero exit.
        let data = try child.successfulReport()
        guard child.expectedIdentity == authorized.identity,
              child.rank == authorized.body.selection.rank,
              child.expectedProfile == authorized.body.binding.profile.workerProfile,
              child.executionPlanSHA256 == authorized.body.binding.executionPlanSHA256 else {
            throw invalid("Actual child differs from authorized member")
        }
        return try validate(data, authorized: authorized, quotation: quotation)
    }

    /// Content-only seam. A valid value is not evidence of process retirement.
    static func validate(_ data: Data, authorized: GLM5NextCalibrationAuthorizer.Authorized,
                         quotation completed: GLM5NextCalibrationInstalledQuote.Completed) throws -> Report {
        guard !data.isEmpty, data.count <= 65_536 else { throw invalid("Report exceeds bound") }
        let report = try JSONDecoder().decode(Report.self, from: data)
        let encoded = try GLM5NextCalibrationQuoteDocument.canonical(report)
        try requireClosed(received: JSONSerialization.jsonObject(with: data),
                          expected: JSONSerialization.jsonObject(with: encoded))
        let p = authorized.body.selection, a = authorized.body.authorization, r = report.quote
        try requireQuotation(completed, authorized: authorized)
        let q = completed.response
        // Runtime completion counts prompt plus committed decode forwards. With
        // no stop IDs and the calibration callback always returning true, the
        // final selected output has no following decode: P + O - 1.
        let expectedFrontier = a.promptTokenIDs.count + a.outputCount - 1
        // Only rank 0 publishes tokens and invokes onCommittedToken. Rank 1
        // commits the same frontier but samples only before/after the request.
        let tokenSamples = p.rank == 0 ? a.outputCount : 0
        let signed = try JSONDecoder().decode(GLM5NextCalibrationDocument.SignedDocument.self,
                                              from: authorized.document)
        let digest = SHA256.hash(data: signed.payload).map { String(format: "%02x", $0) }.joined()
        guard r.authorizationSHA256 == digest, r.rank == p.rank, r.cut == p.cut,
              q.rank == p.rank, q.cut == p.cut, q.repository == p.repository,
              q.revision == p.revision, q.artifactSHA256 == p.artifactSHA256,
              q.rawConfigurationFileSHA256 == authorized.identity.configurationSHA256,
              !q.payloadVerified, !q.qualifiesMaximumEnvelope,
              r.descriptorSHA256 == q.descriptorSHA256,
              r.inventorySHA256 == q.inventorySHA256,
              r.configurationSHA256 == q.normalizedConfigurationSHA256,
              r.numericalPolicySHA256 == q.numericalPolicySHA256,
              r.executionEnvironmentSHA256 == q.executionEnvironmentSHA256,
              r.nativeBytes == q.nativeBytes, r.hostBytes == q.hostBytes,
              r.loadCapacityBytes == q.loadCapacityBytes,
              r.requestCapacityBytes == q.requestCapacityBytes,
              r.loadCapacityBytes == p.loadCapacityBytes,
              r.requestCapacityBytes == p.requestCapacityBytes,
              report.nativeHardCapBytes == a.nativeHardCapBytes,
              report.hostBudgetBytes == a.hostBudgetBytes,
              report.osHeadroomBytes == a.osHeadroomBytes,
              !r.qualifiesMaximumEnvelope, !report.qualifiesMaximumEnvelope,
              report.requiresProcessExit,
              report.committedTokens == expectedFrontier,
              report.observations.map(\.phase) == ["before-load", "loaded"]
                + Array(repeating: "committed-token", count: tokenSamples) + ["request-finished"],
              let baseline = report.observations.first?.host,
              baseline.mallocBytes >= 0, baseline.processFootprintBytes >= 0 else {
            throw invalid("Report differs from admitted quote or bounded request")
        }
        let total = [baseline.processFootprintBytes, a.nativeHardCapBytes,
                     a.hostBudgetBytes, a.osHeadroomBytes].reduce(into: (value: 0, overflow: false)) { result, n in
            let next = result.value.addingReportingOverflow(n)
            result = (next.partialValue, result.overflow || next.overflow)
        }
        guard !total.overflow, total.value <= p.environment.memoryBytes else {
            throw invalid("Observed baseline exceeds physical-memory admission")
        }
        for observation in report.observations {
            let h = observation.host
            guard observation.nativeActiveBytes >= 0, observation.nativePeakBytes >= 0,
                  observation.nativeActiveBytes <= a.nativeHardCapBytes,
                  observation.nativePeakBytes <= a.nativeHardCapBytes,
                  h.mallocBytes >= 0, h.processFootprintBytes >= 0,
                  h.mallocBytes <= baseline.mallocBytes
                    || h.mallocBytes - baseline.mallocBytes <= a.hostBudgetBytes,
                  h.processFootprintBytes <= p.environment.memoryBytes - a.osHeadroomBytes else {
                throw invalid("Observed native, host or OS memory bound exceeded")
            }
        }
        return report
    }

    /// Completed is minted only by the installed path after observed exit0 and
    /// strict response validation. Bind it to THIS finite signed body; another
    /// valid quote from the same pair is not interchangeable evidence.
    private static func requireQuotation(
        _ completed: GLM5NextCalibrationInstalledQuote.Completed,
        authorized: GLM5NextCalibrationAuthorizer.Authorized
    ) throws {
        let q = completed.response, request = completed.authorized.request
        let body = authorized.body
        guard completed.authorized.identity == authorized.identity,
              authorized.expectedVocabularySize == completed.pinnedVocabularySize,
              body.authorization == request.authorization,
              body.binding == q.binding,
              body.selection.rank == request.selection.rank,
              q.rank == request.selection.rank,
              q.quoteRequestID == request.quoteRequestID,
              q.quoteRequestSHA256 == completed.authorized.requestSHA256,
              body.selection.workspaceEvidence.isEmpty,
              body.selection.loadCapacityBytes == q.loadCapacityBytes,
              body.selection.requestCapacityBytes == q.requestCapacityBytes else {
            throw invalid("Report quotation differs from the signed finite experiment")
        }
        // All shared selected fields must match, including absolute expiry,
        // complete file identities, environment, profile scope and allocator
        // bounds. Only the quote mode and returned finite capacities differ.
        guard var finite = try JSONSerialization.jsonObject(
                with: GLM5NextCalibrationQuoteDocument.canonical(body.selection)) as? [String: Any],
              var quote = try JSONSerialization.jsonObject(
                with: GLM5NextCalibrationQuoteDocument.canonical(request.selection)) as? [String: Any] else {
            throw invalid("Invalid retained quotation scope")
        }
        for key in ["loadCapacityBytes", "requestCapacityBytes", "workspaceEvidence"] { finite.removeValue(forKey: key) }
        quote.removeValue(forKey: "mode")
        let options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        guard try JSONSerialization.data(withJSONObject: finite, options: options)
            == JSONSerialization.data(withJSONObject: quote, options: options) else {
            throw invalid("Retained quotation selection differs from signed finite selection")
        }
    }

    private static func requireClosed(received: Any, expected: Any) throws {
        if let expected = expected as? [String: Any] {
            guard let received = received as? [String: Any], Set(received.keys) == Set(expected.keys) else {
                throw invalid("Unknown report fields")
            }
            for key in expected.keys { try requireClosed(received: received[key]!, expected: expected[key]!) }
        } else if let expected = expected as? [Any] {
            guard let received = received as? [Any], received.count == expected.count else {
                throw invalid("Report sequence differs")
            }
            for (a, b) in zip(received, expected) { try requireClosed(received: a, expected: b) }
        }
    }
    private static func invalid(_ message: String) -> ClusterConfigurationError {
        GLM5NextCalibrationDocument.invalid(message)
    }
}
