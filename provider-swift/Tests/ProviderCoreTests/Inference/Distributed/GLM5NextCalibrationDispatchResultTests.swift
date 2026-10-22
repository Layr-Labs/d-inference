import Foundation
import Testing
@testable import ProviderCore

/// UNRUN content/fence regression drafts. Reuses actual held isolated owners,
/// actual own Completed per Mac and their genuine signed finite documents.
/// Synthetic report content is not native execution or a two-owner wire receipt.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_GLM_METADATA_BINDING_REQUIRED"] == "1"))
struct GLM5NextCalibrationDispatchResultTests {
    typealias W = GLM5NextCalibrationDispatchWire
    typealias R = GLM5NextCalibrationDispatchResult
    final class Fixture {
        let owners: GLM5NextCalibrationInstalledOwnerFixture
        let validator: R
        let digest: String
        let bytes: Data
        init() throws {
            let f = try GLM5NextCalibrationInstalledOwnerFixture()
            var handedOff = false
            defer { if !handedOff { f.cleanup() } }
            owners = f
            let context = try f.commit()
            // Test-only content scope. This is NOT the production commit/ack
            // transcript and cannot mint its private CommitProof or fence receipt.
            let digest = W.hash(try W.canonical(context.starts.map(\.canonicalBytes)))
            self.digest = digest
            let summary = try GLM5NextCalibrationPeerQuote.outbound(completed: f.peerQuote,
                now: Int64(Date().timeIntervalSince1970), deadline: DispatchTime.now().uptimeNanoseconds + 1_000_000_000)
            validator = try R(completed: f.localQuote, peerSummary: summary, peerDocument: f.peer.outboundDocument, commitSHA256: digest)
            let document = try JSONDecoder().decode(GLM5NextCalibrationDocument.SignedDocument.self, from: f.peer.outboundDocument)
            let body = try JSONDecoder().decode(GLM5NextCalibrationDocument.Body.self, from: document.payload)
            let a = body.authorization, p = body.selection, q = f.peerQuote.response
            let phases = ["before-load", "loaded"] + Array(repeating: "committed-token", count: p.rank == 0 ? a.outputCount : 0) + ["request-finished"]
            let object: [String: Any] = ["nativeHardCapBytes": a.nativeHardCapBytes, "hostBudgetBytes": a.hostBudgetBytes,
                "osHeadroomBytes": a.osHeadroomBytes, "committedTokens": a.promptTokenIDs.count + a.outputCount - 1,
                "qualifiesMaximumEnvelope": false, "requiresProcessExit": true,
                "observations": phases.map { ["phase": $0, "nativeActiveBytes": 10, "nativePeakBytes": 20,
                    "host": ["mallocBytes": 10, "processFootprintBytes": 20]] as [String: Any] },
                "quote": ["authorizationSHA256": W.hash(document.payload), "descriptorSHA256": q.descriptorSHA256,
                    "cut": q.cut, "rank": q.rank, "nativeBytes": q.nativeBytes, "hostBytes": q.hostBytes,
                    "loadCapacityBytes": q.loadCapacityBytes, "requestCapacityBytes": q.requestCapacityBytes,
                    "inventorySHA256": q.inventorySHA256, "configurationSHA256": q.normalizedConfigurationSHA256,
                    "numericalPolicySHA256": q.numericalPolicySHA256, "executionEnvironmentSHA256": q.executionEnvironmentSHA256,
                    "qualifiesMaximumEnvelope": false]]
            let raw = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            bytes = try W.canonical(JSONDecoder().decode(GLM5NextCalibrationReport.Report.self, from: raw))
            handedOff = true
        }
        deinit { owners.cleanup() }
        func result(_ data: Data? = nil, commit: String? = nil, journal: Bool = true) -> W.Result {
            let report = data ?? bytes
            return W.Result(commitSHA256: commit ?? digest, termination: .exited, code: 0,
                journalResolved: journal, bootstrapCompleted: true, report: report, reportSHA256: W.hash(report))
        }
    }
    @Test func detailedContentCanValidateWithoutClaimingLocalProcessExit() throws {
        let f = try Fixture()
        #expect(try f.validator.validate(f.result()))
        #expect(f.owners.local.actualExit() == nil && f.owners.peer.actualExit() == nil)
        #expect(!f.owners.local.status().launchAttempted && !f.owners.peer.status().launchAttempted)
        // There is no constructor from these values to DispatchTerminalReceipt.
        #expect(throws: (any Error).self) { try f.validator.validate(f.result(commit: String(repeating: "f", count: 64))) }
        #expect(throws: (any Error).self) { try f.validator.validate(f.result(journal: false)) }
    }
    @Test func reportMutationsAndUnknownNestedClaimsRefuse() throws {
        let f = try Fixture()
        for mode in ["frontier", "native", "unknown", "maximum"] {
            var object = try JSONSerialization.jsonObject(with: f.bytes) as! [String: Any]
            switch mode {
            case "frontier": object["committedTokens"] = (object["committedTokens"] as! Int) + 1
            case "maximum": object["qualifiesMaximumEnvelope"] = true
            default:
                var observations = object["observations"] as! [[String: Any]]
                if mode == "native" { observations[0]["nativePeakBytes"] = Int.max }
                else { var host = observations[0]["host"] as! [String: Any]; host["payloadVerified"] = true; observations[0]["host"] = host }
                object["observations"] = observations
            }
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            #expect(throws: (any Error).self) { try f.validator.validate(f.result(data)) }
        }
    }
    @Test func anExistingRetiredSessionCannotLaunchAgain() throws {
        let f = try GLM5NextCalibrationPeerQuoteFixture()
        let root = f.base.device.deletingLastPathComponent().appendingPathComponent("retired-dispatch-fences")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let session = UUID(), request = f.local.authorized.request
        // Refusal fixture only: no constructor mints a verified terminal receipt.
        let archive = root.appendingPathComponent(session.uuidString.lowercased() + ".finite-result.json")
        try Data("{}".utf8).write(to: archive)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archive.path)
        #expect(throws: (any Error).self) {
            try GLM5NextCalibrationDispatchFence(directory: root, pair: f.local.pair,
                sessionID: session, epoch: request.selection.epoch, requestID: request.authorization.requestID)
        }
    }
    @Test func stickyPairFenceSurvivesDropAndRefusesReplacementWithoutBothReceipts() throws {
        let f = try GLM5NextCalibrationPeerQuoteFixture()
        let root = f.base.device.deletingLastPathComponent().appendingPathComponent("dispatch-pair-fences")
        let session = UUID(), request = f.local.authorized.request
        var first: GLM5NextCalibrationDispatchFence? = try .init(directory: root, pair: f.local.pair,
            sessionID: session, epoch: request.selection.epoch, requestID: request.authorization.requestID)
        #expect(first != nil)
        #expect(throws: (any Error).self) {
            try GLM5NextCalibrationDispatchFence(directory: root, pair: f.local.pair, sessionID: UUID(), epoch: request.selection.epoch, requestID: request.authorization.requestID)
        }
        first = nil // Flock is released; unresolved durable quarantine remains.
        #expect(throws: (any Error).self) {
            try GLM5NextCalibrationDispatchFence(directory: root, pair: f.local.pair, sessionID: session, epoch: request.selection.epoch, requestID: request.authorization.requestID)
        }
        #expect(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).contains { $0.lastPathComponent.hasSuffix("finite-pending.json") })
    }
}
