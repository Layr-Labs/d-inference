import Foundation
import Testing
@testable import ProviderCore

/// UNRUN content-only cases. Public metadata never mints installed authority.
@Suite struct GLM5NextCalibrationDispatchWireTests {
    typealias W = GLM5NextCalibrationDispatchWire
    func header() -> W.Header {
        W.Header(version: 1, purpose: "finiteCalibration", pair: .init(clusterID: "fixture",
            generation: 1, rosterSHA256: String(repeating: "a", count: 64),
            ceremonyTranscriptSHA256: String(repeating: "b", count: 64), linkEpoch: UUID(), edgeID: UUID()),
            sessionID: UUID(), epoch: UUID(), requestID: UUID(), expiresUnixSeconds: 1100, rank: 0,
            senderIncarnation: UUID(), receiverIncarnation: UUID(), connectionGeneration: 1, sequence: 1)
    }
    @Test func exactClosedWireRejectsNestedUnknownsAndOversizedInput() throws {
        let h = header(), packet = W.Packet(header: h, kind: .hello, payload: try W.canonical(W.Empty()))
        let original = try W.canonical(packet)
        let decoded = try W.decode(W.Packet.self, original)
        try W.validate(decoded, expected: h, now: 1000)
        var object = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        var header = object["header"] as! [String: Any]; header["untrusted"] = true; object["header"] = header
        #expect(throws: (any Error).self) { try W.decode(W.Packet.self, JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) }
        #expect(throws: (any Error).self) { try W.decode(W.Packet.self, original + Data([32])) }
        #expect(throws: (any Error).self) { try W.decode(W.Packet.self, Data(repeating: 32, count: W.maximumBytes + 1)) }
    }
    @Test func epochSessionRankSequenceAndConnectionCannotBeSubstituted() throws {
        let expected = header()
        let original = try W.canonical(expected)
        for key in ["epoch", "sessionID", "requestID", "senderIncarnation", "receiverIncarnation"] {
            var object = try JSONSerialization.jsonObject(with: original) as! [String: Any]
            object[key] = UUID().uuidString
            let h = try JSONDecoder().decode(W.Header.self, from: JSONSerialization.data(withJSONObject: object))
            #expect(throws: (any Error).self) { try W.validate(.init(header: h, kind: .hello, payload: Data()), expected: expected, now: 1000) }
        }
        for (key, value) in [("rank", 1), ("sequence", 2), ("connectionGeneration", 2), ("expiresUnixSeconds", 1099)] {
            var object = try JSONSerialization.jsonObject(with: original) as! [String: Any]; object[key] = value
            let h = try JSONDecoder().decode(W.Header.self, from: JSONSerialization.data(withJSONObject: object))
            #expect(throws: (any Error).self) { try W.validate(.init(header: h, kind: .hello, payload: Data()), expected: expected, now: 1000) }
        }
    }
    @Test func expiredExecutionCannotReviveButTerminalRetirementMayBeRecorded() throws {
        let h = header()
        for kind in [W.Kind.quotation, .document, .start, .commit, .commitAck, .launchBarrier, .bootstrap] {
            #expect(throws: (any Error).self) { try W.validate(.init(header: h, kind: kind, payload: Data()), expected: h, now: 1100) }
        }
        for kind in [W.Kind.result, .resultAck, .cancel] {
            try W.validate(.init(header: h, kind: kind, payload: Data()), expected: h, now: 1200)
        }
    }
    @Test func reportAloneOrUnresolvedJournalNeverSatisfiesRetirement() throws {
        let digest = String(repeating: "a", count: 64)
        let unresolved = W.Result(commitSHA256: digest, termination: .exited, code: 0,
            journalResolved: false, bootstrapCompleted: true, report: nil, reportSHA256: nil)
        #expect(throws: (any Error).self) { try GLM5NextCalibrationDispatchResult.retired(unresolved, expectedCommit: digest) }
        let noLaunchWithReport = W.Result(commitSHA256: digest, termination: .noLaunch, code: nil,
            journalResolved: true, bootstrapCompleted: false, report: Data([1]), reportSHA256: W.hash(Data([1])))
        #expect(throws: (any Error).self) { try GLM5NextCalibrationDispatchResult.retired(noLaunchWithReport, expectedCommit: digest) }
    }
}
