import Foundation
import XCTest
@testable import DarkbloomClusterQualification

/// Constructed reports: a 6-token run over an 8-entry vocabulary whose logits
/// sit near 20, where one bfloat16 unit in the last place is 0.125.
private enum Constructed {
    static let tokens = [3, 4, 3, 1, 6, 3]
    static let row: [Float] = [0.5, 1.5, -2.0, 20.0, 18.5, 0.0, -0.25, 3.0]

    static func request(prompt: [Int] = Array(1...40)) throws -> QualificationRequest {
        try .init(requestID: UUID(uuidString: "0f1e2d3c-4b5a-4978-8695-a4b3c2d1e0f9")!, promptTokenIDs: prompt,
                  chunkSize: 16, outputCount: 6, stopTokenIDs: [], promptSource: .init(kind: "tokenIDs", description: "constructed"))
    }
    static func identity(cut: Int = 8, prompt: [Int] = Array(1...40)) throws -> QualificationIdentity {
        var value = QualificationIdentity(request: try request(prompt: prompt), stageCut: cut, prefillSchedule: "serial_v1",
            artifactSHA256: String(repeating: "a", count: 64), configurationSHA256: String(repeating: "b", count: 64),
            planSHA256: QualificationHash.sha256(Data("plan-\(cut)".utf8)))
        value.requestFingerprint = String(repeating: "c", count: 64)
        return value
    }
    static func logits(_ values: [Float] = row) -> QualificationFinalLogits {
        var bytes = Data()
        for value in values { withUnsafeBytes(of: value.bitPattern) { bytes.append(contentsOf: $0) } }
        return .init(shape: [1, values.count], dtype: "bfloat16", byteCount: values.count * 2,
                     logicalBytesSHA256: QualificationHash.sha256(bytes), values: values)
    }
    static func state(_ digest: String = "d") -> [QualificationStateEntry] {
        [.init(globalLayerIndex: 0, component: "ssm", shape: [1, 2], dtype: "float32", byteCount: 8, sha256: String(repeating: "e", count: 64)),
         .init(globalLayerIndex: 3, component: "kv.keys", shape: [1, 4, 45, 256], dtype: "bfloat16", byteCount: 92_160, sha256: String(repeating: digest, count: 64))]
    }
    /// The reference: every step's winner leads the runner-up by `margin`.
    static func reference(margin: Float = 1.5) -> QualificationEvidence {
        let steps = tokens.enumerated().map { ordinal, token in
            QualificationStep(ordinal: ordinal, frameSequence: 2 + ordinal, committedTokens: 40 + ordinal, tokenID: token,
                topTokenIDs: [token, 7, 5, 2], topLogits: [20.0, 20.0 - margin, 12.0, 4.0], maximumTieCount: 1,
                rowSHA256: String(repeating: "f", count: 64))
        }
        return .init(selectedTokenIDs: tokens, finishReason: "length", completedFrames: 8, committedTokens: 45,
                     steps: steps, finalLogits: logits(), stateEntries: state(), stateSHA256: String(repeating: "1", count: 64))
    }
    /// A pair's evidence: no per-step rows, a final row and joined state.
    static func pair(tokens: [Int] = tokens, row: [Float]? = Constructed.row, stateDigest: String = "d") -> QualificationEvidence {
        .init(selectedTokenIDs: tokens, finishReason: "length", completedFrames: 8, committedTokens: 40 + tokens.count - 1,
              steps: nil, finalLogits: row.map { logits($0) }, stateEntries: state(stateDigest),
              stateSHA256: String(repeating: stateDigest == "d" ? "1" : "2", count: 64))
    }
    static func compare(_ reference: QualificationEvidence, _ candidate: QualificationEvidence,
                        candidateIdentity: QualificationIdentity? = nil,
                        comparator: QualificationComparator = .init()) throws -> QualificationComparison {
        try comparator.compare(reference: .init(label: "reference", identity: try identity(), evidence: reference),
            candidate: .init(label: "pair", identity: try candidateIdentity ?? identity(), evidence: candidate))
    }
}

final class QualificationComparatorTests: XCTestCase {
    func testExactWhenTokensFinalRowAndStateAreIdentical() throws {
        let result = try Constructed.compare(Constructed.reference(), Constructed.pair())
        XCTAssertEqual(result.verdict, .exact)
        XCTAssertTrue(result.identityMatches); XCTAssertNil(result.tokens.firstDivergenceIndex)
        XCTAssertEqual(result.tokens.equalPrefixLength, 6)
        XCTAssertEqual(result.logits?.bytesEqual, true); XCTAssertEqual(result.logits?.maximumAbsoluteDifference, 0)
        XCTAssertEqual(result.state?.differingEntries, []); XCTAssertEqual(result.state?.fingerprintsEqual, true)
        XCTAssertEqual(result.completedFramesEqual, true); XCTAssertEqual(result.committedTokensEqual, true)
        XCTAssertTrue(QualificationComparator.render(result).hasSuffix("verdict: exact"))
    }

    func testTokensEqualLogitsDifferReportsTheLargestDifference() throws {
        var row = Constructed.row
        row[4] += 0.125; row[1] -= 0.0625
        let result = try Constructed.compare(Constructed.reference(), Constructed.pair(row: row))
        XCTAssertEqual(result.verdict, .tokensEqualLogitsDiffer)
        XCTAssertNil(result.tokens.firstDivergenceIndex)
        XCTAssertEqual(result.logits?.bytesEqual, false)
        XCTAssertEqual(result.logits?.maximumAbsoluteDifference, 0.125)
        XCTAssertEqual(result.logits?.indexOfMaximumDifference, 4)
        XCTAssertEqual(result.logits?.differingValueCount, 2)
        XCTAssertEqual(result.logits?.argmaxEqual, true)
        // The reference's own top-1/top-2 margin on that row, for scale.
        XCTAssertEqual(result.logits?.referenceTop1Top2Margin, 1.5)
        XCTAssertTrue(QualificationComparator.render(result).contains("max |difference| 0.125 at token 4"))
    }

    func testIdenticalFinalRowWithDifferentStateIsNotExact() throws {
        let result = try Constructed.compare(Constructed.reference(), Constructed.pair(stateDigest: "9"))
        XCTAssertEqual(result.verdict, .tokensEqualLogitsDiffer)
        XCTAssertEqual(result.logits?.bytesEqual, true)
        XCTAssertEqual(result.state?.differingEntries, ["3|kv.keys"]); XCTAssertEqual(result.state?.fingerprintsEqual, false)
    }

    func testDivergedAtNearTieWhenTheCandidateTookTheReferenceRunnerUpWithinTheThreshold() throws {
        // Reference margin 0.25 = 2 ulp at 20.0; the candidate chose the runner-up (token 7) at index 3.
        var tokens = Constructed.tokens; tokens[3] = 7; tokens[4] = 2
        let result = try Constructed.compare(Constructed.reference(margin: 0.25), Constructed.pair(tokens: tokens))
        XCTAssertEqual(result.verdict, .divergedAtNearTie)
        XCTAssertEqual(result.tokens.firstDivergenceIndex, 3); XCTAssertEqual(result.tokens.equalPrefixLength, 3)
        let detail = try XCTUnwrap(result.divergence)
        XCTAssertEqual(detail.referenceTokenID, 1); XCTAssertEqual(detail.candidateTokenID, 7)
        XCTAssertEqual(detail.referenceTop2TokenID, 7); XCTAssertEqual(detail.referenceTop1Top2Margin, 0.25)
        XCTAssertEqual(detail.ulpAtTop1, 0.125); XCTAssertEqual(detail.gapInULPs, 2)
        XCTAssertEqual(detail.candidateTokenReferenceRank, 2); XCTAssertTrue(detail.nearTie)
        // State at different histories is not compared.
        XCTAssertNil(result.state)
        // A stricter threshold calls the same run a plain divergence.
        let strict = try Constructed.compare(Constructed.reference(margin: 0.25), Constructed.pair(tokens: tokens),
                                             comparator: .init(nearTieULPs: 1))
        XCTAssertEqual(strict.verdict, .diverged)
    }

    func testDivergedWhenTheReferenceHadAClearWinner() throws {
        var tokens = Constructed.tokens; tokens[2] = 7
        let result = try Constructed.compare(Constructed.reference(margin: 1.5), Constructed.pair(tokens: tokens))
        XCTAssertEqual(result.verdict, .diverged)
        XCTAssertEqual(result.tokens.firstDivergenceIndex, 2)
        XCTAssertEqual(result.divergence?.gapInULPs, 12); XCTAssertEqual(result.divergence?.nearTie, false)
        // A token the reference did not even rank is a divergence, with the reason stated.
        tokens[2] = 0
        let unranked = try Constructed.compare(Constructed.reference(margin: 0.125), Constructed.pair(tokens: tokens))
        XCTAssertEqual(unranked.verdict, .diverged)
        XCTAssertNil(unranked.divergence?.referenceGapToCandidateToken)
        XCTAssertTrue(unranked.reasons.contains { $0.contains("not among the reference's recorded top values") })
        // A shorter history is a divergence at its end.
        let short = try Constructed.compare(Constructed.reference(), Constructed.pair(tokens: Array(Constructed.tokens.prefix(4))))
        XCTAssertEqual(short.verdict, .diverged); XCTAssertEqual(short.tokens.firstDivergenceIndex, 4)
        XCTAssertNil(short.divergence?.candidateTokenID)
    }

    func testIncomparableWhenTheRunsAreNotTheSameRequest() throws {
        let other = try Constructed.identity(prompt: Array(2...41))
        let result = try Constructed.compare(Constructed.reference(), Constructed.pair(), candidateIdentity: other)
        XCTAssertEqual(result.verdict, .incomparable)
        XCTAssertFalse(result.identityMatches); XCTAssertEqual(result.identityDifferences, ["promptTokenIDsSHA256"])
        // Agreement is still reported, only not judged.
        XCTAssertNil(result.tokens.firstDivergenceIndex); XCTAssertEqual(result.logits?.bytesEqual, true)
    }

    func testCutIsPartOfTheIdentityUnlessExplicitlyAllowed() throws {
        let cut16 = try Constructed.identity(cut: 16)
        let refused = try Constructed.compare(Constructed.reference(), Constructed.pair(), candidateIdentity: cut16)
        XCTAssertEqual(refused.verdict, .incomparable)
        XCTAssertEqual(refused.identityDifferences, ["stageCut", "planSHA256"])
        let allowed = try Constructed.compare(Constructed.reference(), Constructed.pair(), candidateIdentity: cut16,
                                              comparator: .init(allowCutDifference: true))
        XCTAssertEqual(allowed.verdict, .exact)
        XCTAssertTrue(allowed.reasons.contains { $0.contains("stage cuts differ (8 and 16)") })
    }

    func testPrefillScheduleIsPartOfTheIdentityUnlessExplicitlyAllowed() throws {
        var lookahead = try Constructed.identity()
        lookahead.prefillSchedule = "one_chunk_lookahead_v1"
        let refused = try Constructed.compare(Constructed.reference(), Constructed.pair(), candidateIdentity: lookahead)
        XCTAssertEqual(refused.verdict, .incomparable); XCTAssertEqual(refused.identityDifferences, ["prefillSchedule"])
        let allowed = try Constructed.compare(Constructed.reference(), Constructed.pair(), candidateIdentity: lookahead,
                                              comparator: .init(allowScheduleDifference: true))
        XCTAssertEqual(allowed.verdict, .exact)
        XCTAssertTrue(allowed.reasons.contains { $0.contains("prefill schedules differ (serial_v1 and one_chunk_lookahead_v1)") })
    }

    func testIncomparableWhenEqualTokensHaveNoFinalRowToSettleThem() throws {
        let result = try Constructed.compare(Constructed.reference(), Constructed.pair(row: nil))
        XCTAssertEqual(result.verdict, .incomparable)
        XCTAssertNil(result.tokens.firstDivergenceIndex); XCTAssertNil(result.logits)
        XCTAssertEqual(result.logitsNotCompared, "the candidate report has no final row")
        XCTAssertTrue(result.reasons.contains { $0.contains("all 6 tokens are equal") })
        // Missing tokens altogether, and a frame count that contradicts equal tokens.
        XCTAssertEqual(try Constructed.compare(Constructed.reference(), Constructed.pair(tokens: [])).verdict, .incomparable)
        var frames = Constructed.pair(); frames.completedFrames = 9
        XCTAssertEqual(try Constructed.compare(Constructed.reference(), frames).verdict, .incomparable)
    }

    func testOptionalIdentityFieldsAreComparedOnlyWhenBothSidesHaveThem() throws {
        var a = try Constructed.identity(), b = try Constructed.identity()
        b.requestFingerprint = nil; a.storageCommitmentSHA256 = String(repeating: "5", count: 64)
        XCTAssertEqual(a.differences(from: b).differing, [])
        XCTAssertEqual(a.differences(from: b).notCompared, ["requestFingerprint", "storageCommitmentSHA256"])
        b.requestFingerprint = String(repeating: "6", count: 64)
        XCTAssertEqual(a.differences(from: b).differing, ["requestFingerprint"])
    }

    func testUnitInLastPlaceFollowsTheRowPrecision() {
        XCTAssertEqual(QualificationComparator.unitInLastPlace(of: 20, dtype: "bfloat16"), 0.125)
        XCTAssertEqual(QualificationComparator.unitInLastPlace(of: -1.5, dtype: "bfloat16"), 0.0078125)
        XCTAssertEqual(QualificationComparator.unitInLastPlace(of: 20, dtype: "float16"), 0.015625)
        XCTAssertEqual(QualificationComparator.unitInLastPlace(of: 20, dtype: "float32"), Float(20).ulp)
        XCTAssertNil(QualificationComparator.unitInLastPlace(of: 0, dtype: "bfloat16"))
        XCTAssertNil(QualificationComparator.unitInLastPlace(of: 20, dtype: "int8"))
    }

    func testReportsRoundTripThroughFilesAndFailedPairReportsAreRefused() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("qualification-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = try Constructed.request()
        let reference = ReferenceReport(identity: try Constructed.identity(), evidence: Constructed.reference(),
            host: .init(role: "single host", chip: "Apple M3 Ultra", operatingSystem: "27.2"), binarySHA256: nil, metallibSHA256: nil,
            timing: .init(stageLoadSeconds: [1, 2], prefillSeconds: 0.1, prefillTokensPerSecond: 400, decodeSeconds: 0.2,
                          decodeTokensPerSecond: 25, requestWallSeconds: 0.4, totalSeconds: 4, note: "constructed"),
            memory: .init(activeBytesBefore: 0, activeBytesLoaded: 10, peakBytes: 12, activeBytesAfterRelease: 0,
                          cacheBytesAfterRelease: 0, loadedTensorBytes: [4, 6], stageModelsReleased: [true, true]),
            promptSource: request.promptSource, decodedOutput: "text")
        func pair(_ outcome: String, _ evidence: QualificationEvidence?) throws -> PairReport {
            var ranks = (0...1).map { PairRankReport(role: PairConfiguration.roles[$0], rank: $0) }
            ranks[0].chip = "Apple M3 Ultra"; ranks[1].chip = "Apple M5 Max"
            return PairReport(outcome: outcome, failure: outcome == "completed" ? nil : "constructed failure",
                identity: try Constructed.identity(), evidence: evidence, ranks: ranks, workerHashesIdentical: true,
                metallibHashesIdentical: true, recording: true, ranksAgreeOnTokens: true, bothExitsObserved: true,
                noWorkerProcessLeft: true, progressTimeoutMilliseconds: nil, timing: .init(note: "constructed"),
                promptSource: request.promptSource, decodedOutput: nil)
        }
        let files = ["reference.json", "pair.json", "failed.json"].map { directory.appendingPathComponent($0) }
        try QualificationFiles.writeNew(QualificationReportFiles.encode(reference), to: files[0])
        try QualificationFiles.writeNew(QualificationReportFiles.encode(try pair("completed", Constructed.pair())), to: files[1])
        try QualificationFiles.writeNew(QualificationReportFiles.encode(try pair("failed", nil)), to: files[2])
        let a = try QualificationReportFiles.subject(files[0]), b = try QualificationReportFiles.subject(files[1])
        XCTAssertEqual(a.label, "single-host reference (Apple M3 Ultra)")
        XCTAssertEqual(b.label, "two-rank pair (Apple M3 Ultra + Apple M5 Max)")
        XCTAssertEqual(try QualificationComparator().compare(reference: a, candidate: b).verdict, .exact)
        XCTAssertThrowsError(try QualificationReportFiles.subject(files[2]))
        // A report is evidence of one run and is never replaced.
        XCTAssertThrowsError(try QualificationFiles.writeNew(Data("x".utf8), to: files[0]))
    }
}

final class QualificationRequestTests: XCTestCase {
    func testSyntheticPromptIsFixedAndInsideTheVocabulary() throws {
        let a = QualificationRequest.syntheticPrompt(count: 4096, seed: 7), b = QualificationRequest.syntheticPrompt(count: 4096, seed: 7)
        XCTAssertEqual(a, b); XCTAssertEqual(Array(a.prefix(3)), [82_143, 17_904, 86_369])
        XCTAssertTrue(a.allSatisfy { (1000..<101_000).contains($0) })
        XCTAssertNotEqual(a, QualificationRequest.syntheticPrompt(count: 4096, seed: 8))
        XCTAssertGreaterThan(Set(a).count, 3900)
    }

    func testRequestBoundsMatchTheRegisteredProfile() throws {
        func make(prompt: Int = 32, chunk: Int = 16, output: Int = 16, stops: [Int] = [], first: Int = 5) throws -> QualificationRequest {
            try .init(requestID: UUID(), promptTokenIDs: Array(repeating: first, count: prompt), chunkSize: chunk,
                      outputCount: output, stopTokenIDs: stops, promptSource: .init(kind: "tokenIDs", description: "test"))
        }
        XCTAssertNoThrow(try make()); XCTAssertNoThrow(try make(prompt: 8192, chunk: 512, output: 128))
        XCTAssertNoThrow(try make(stops: [248_044, 248_046]))
        XCTAssertThrowsError(try make(prompt: 0)); XCTAssertThrowsError(try make(prompt: 8193, output: 1))
        XCTAssertThrowsError(try make(chunk: 513)); XCTAssertThrowsError(try make(chunk: 0))
        XCTAssertThrowsError(try make(output: 129)); XCTAssertThrowsError(try make(output: 0))
        XCTAssertThrowsError(try make(first: 248_320)); XCTAssertThrowsError(try make(first: -1))
        XCTAssertThrowsError(try make(stops: [9, 3])); XCTAssertThrowsError(try make(stops: [3, 3]))
        // A stored request is checked again when read, including its prompt hash.
        var stored = try make()
        let data = try stored.encoded()
        XCTAssertEqual(try JSONDecoder().decode(QualificationRequest.self, from: data), stored)
        stored.promptTokenIDs[0] = 6
        XCTAssertThrowsError(try stored.validate())
    }

    func testRankEvidenceJoinsAndRefusesDisagreement() throws {
        func record(rank: Int, tokens: [Int] = [5, 6], plan: String = "p") -> Data {
            var value: [String: Any] = ["schema": PairEvidence.schema, "rank": rank,
                "requestFingerprint": String(repeating: "a", count: 64), "profileFingerprint": String(repeating: "b", count: 64),
                "execution": ["selectedTokenIDs": tokens, "completedFrames": 3, "committedTokens": 9, "finishReason": "length",
                              "tokenChainSHA256": String(repeating: "c", count: 64), "ignored": true],
                "agreement": ["requestID": "r", "sourceConfigurationSHA256": "s", "artifactAggregateSHA256": "t",
                              "storageCommitmentSHA256": "u", "planFingerprint": plan, "stageFingerprints": ["v", "w"],
                              "numericalPolicySHA256": "x"],
                "stateEntries": [["globalLayerIndex": rank * 4, "component": "ssm", "shape": [1, 2], "dtype": "float32",
                                  "byteCount": 8, "sha256": String(repeating: "d", count: 64)]],
                "stageStateSHA256": String(repeating: "e", count: 64)]
            if rank == 1 {
                value["finalLogits"] = ["shape": [1, 3], "dtype": "bfloat16", "byteCount": 6,
                    "logicalBytesSHA256": String(repeating: "f", count: 64), "values": [1.5, -0.25, 7.0]]
            }
            return try! JSONSerialization.data(withJSONObject: value)
        }
        let joined = try PairEvidence.join([try .decode(record(rank: 0), rank: 0), try .decode(record(rank: 1), rank: 1)])
        XCTAssertEqual(joined.evidence.selectedTokenIDs, [5, 6]); XCTAssertEqual(joined.evidence.committedTokens, 9)
        XCTAssertEqual(try joined.evidence.finalLogits?.values(), [1.5, -0.25, 7.0])
        XCTAssertEqual(joined.evidence.stateEntries?.map(\.key), ["0|ssm", "4|ssm"])
        XCTAssertEqual(joined.identity.planSHA256, "p")
        // The joined fingerprint follows the runtime's line format.
        let lines = "cbv2-owned-state-v1\ntokens=9\n0|ssm|[1, 2]|float32|8|\(String(repeating: "d", count: 64))\n4|ssm|[1, 2]|float32|8|\(String(repeating: "d", count: 64))"
        XCTAssertEqual(joined.evidence.stateSHA256, QualificationHash.sha256(Data(lines.utf8)))
        // A record for the wrong rank, a rank-0 record with a row, and ranks that disagree.
        XCTAssertThrowsError(try PairEvidence.decode(record(rank: 0), rank: 1))
        XCTAssertThrowsError(try PairEvidence.decode(Data("{}".utf8), rank: 0))
        XCTAssertThrowsError(try PairEvidence.join([try .decode(record(rank: 0, tokens: [5, 7]), rank: 0), try .decode(record(rank: 1), rank: 1)]))
        XCTAssertThrowsError(try PairEvidence.join([try .decode(record(rank: 0, plan: "q"), rank: 0), try .decode(record(rank: 1), rank: 1)]))
    }
}
