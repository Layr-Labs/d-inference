import Foundation
import CryptoKit

/// Content validation of authenticated peer OWNER claims. No peer Completed or
/// Authorized is reconstructed and no public DTO represents local process exit.
struct GLM5NextCalibrationDispatchResult {
    typealias W = GLM5NextCalibrationDispatchWire
    typealias D = GLM5NextCalibrationDocument
    typealias Q = GLM5NextCalibrationQuoteDocument
    private let body: D.Body
    private let quote: Q.Response
    private let authorizationSHA256: String
    private let commitSHA256: String

    init(completed: GLM5NextCalibrationInstalledQuote.Completed, peerSummary: Data,
         peerDocument: Data, commitSHA256: String) throws {
        let summary = try GLM5NextCalibrationPeerQuoteDocument.verify(peerSummary, key: completed.pair.peerIdentity)
        let request = try GLM5NextCalibrationPeerQuoteDocument.request(summary.signedRequest, key: completed.pair.peerIdentity)
        let quote = try GLM5NextCalibrationQuoteAuthorizer.validatePublicResponse(summary.response,
            request: request, identity: completed.authorized.identity, now: Int64(Date().timeIntervalSince1970),
            expectedVocabularySize: completed.pinnedVocabularySize)
        let signed = try W.decode(D.SignedDocument.self, peerDocument)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: signed.signature)
        let key = try P256.Signing.PublicKey(x963Representation: completed.pair.peerIdentity)
        guard key.isValidSignature(signature, for: D.domain + signed.payload) else { throw W.invalid("peer finite result signer") }
        let body = try W.decode(D.Body.self, signed.payload)
        try D.validate(body, identity: completed.authorized.identity, rank: 1 - completed.authorized.request.selection.rank,
            now: Int64(Date().timeIntervalSince1970), expectedVocabularySize: completed.pinnedVocabularySize)
        guard summary.responseSHA256 == W.hash(summary.response), body.authorization == request.authorization,
              body.binding == quote.binding, body.selection.loadCapacityBytes == quote.loadCapacityBytes,
              body.selection.requestCapacityBytes == quote.requestCapacityBytes, body.selection.workspaceEvidence.isEmpty else {
            throw W.invalid("peer finite report quotation mismatch")
        }
        var finite = try JSONSerialization.jsonObject(with: Q.canonical(body.selection)) as! [String: Any]
        var selected = try JSONSerialization.jsonObject(with: Q.canonical(request.selection)) as! [String: Any]
        for k in ["loadCapacityBytes", "requestCapacityBytes", "workspaceEvidence"] { finite.removeValue(forKey: k) }
        selected.removeValue(forKey: "mode")
        let options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        guard try JSONSerialization.data(withJSONObject: finite, options: options)
            == JSONSerialization.data(withJSONObject: selected, options: options) else { throw W.invalid("peer finite selection mismatch") }
        self.body = body; self.quote = quote; authorizationSHA256 = W.hash(signed.payload); self.commitSHA256 = commitSHA256
    }
    static func retired(_ result: W.Result, expectedCommit: String) throws {
        guard result.commitSHA256 == expectedCommit, result.journalResolved,
              (result.report == nil) == (result.reportSHA256 == nil) else { throw W.invalid("peer result retirement/commit") }
        if let report = result.report {
            guard report.count <= 65_536, result.reportSHA256 == W.hash(report) else { throw W.invalid("peer report digest") }
        }
        switch result.termination {
        case .noLaunch:
            guard result.code == nil, result.report == nil, !result.bootstrapCompleted else { throw W.invalid("no-launch claim differs") }
        case .exited:
            guard let code = result.code, (0...255).contains(code), code == 0 || result.report == nil else { throw W.invalid("exit claim differs") }
        case .signalled:
            guard let code = result.code, (1...127).contains(code), result.report == nil else { throw W.invalid("signal claim differs") }
        }
    }
    func validate(_ result: W.Result) throws -> Bool {
        try Self.retired(result, expectedCommit: commitSHA256)
        guard result.termination == .exited, result.code == 0, result.bootstrapCompleted,
              let data = result.report else { return false }
        let r = try W.decode(GLM5NextCalibrationReport.Report.self, data)
        let p = body.selection, a = body.authorization, q = r.quote
        let frontier = a.promptTokenIDs.count + a.outputCount - 1
        let samples = p.rank == 0 ? a.outputCount : 0
        guard q.authorizationSHA256 == authorizationSHA256, q.rank == p.rank, q.cut == p.cut,
              q.descriptorSHA256 == quote.descriptorSHA256, q.inventorySHA256 == quote.inventorySHA256,
              q.configurationSHA256 == quote.normalizedConfigurationSHA256,
              q.numericalPolicySHA256 == quote.numericalPolicySHA256,
              q.executionEnvironmentSHA256 == quote.executionEnvironmentSHA256,
              q.nativeBytes == quote.nativeBytes, q.hostBytes == quote.hostBytes,
              q.loadCapacityBytes == quote.loadCapacityBytes, q.requestCapacityBytes == quote.requestCapacityBytes,
              r.nativeHardCapBytes == a.nativeHardCapBytes, r.hostBudgetBytes == a.hostBudgetBytes,
              r.osHeadroomBytes == a.osHeadroomBytes, r.committedTokens == frontier,
              !q.qualifiesMaximumEnvelope, !r.qualifiesMaximumEnvelope, r.requiresProcessExit,
              r.observations.map(\.phase) == ["before-load", "loaded"] + Array(repeating: "committed-token", count: samples) + ["request-finished"],
              let baseline = r.observations.first?.host, baseline.mallocBytes >= 0, baseline.processFootprintBytes >= 0 else {
            throw W.invalid("peer detailed report differs from finite quotation/request")
        }
        var total = baseline.processFootprintBytes
        for n in [a.nativeHardCapBytes, a.hostBudgetBytes, a.osHeadroomBytes] {
            let next = total.addingReportingOverflow(n)
            guard !next.overflow else { throw W.invalid("peer report memory overflow") }; total = next.partialValue
        }
        guard total <= p.environment.memoryBytes else { throw W.invalid("peer report baseline admission") }
        for o in r.observations {
            guard o.nativeActiveBytes >= 0, o.nativePeakBytes >= 0,
                  o.nativeActiveBytes <= a.nativeHardCapBytes, o.nativePeakBytes <= a.nativeHardCapBytes,
                  o.host.mallocBytes >= 0, o.host.processFootprintBytes >= 0,
                  o.host.mallocBytes <= baseline.mallocBytes || o.host.mallocBytes - baseline.mallocBytes <= a.hostBudgetBytes,
                  o.host.processFootprintBytes <= p.environment.memoryBytes - a.osHeadroomBytes else { throw W.invalid("peer report memory bound") }
        }
        return true
    }
}
