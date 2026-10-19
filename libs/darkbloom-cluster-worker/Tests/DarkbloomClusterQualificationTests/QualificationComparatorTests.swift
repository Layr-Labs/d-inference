import Foundation
import XCTest
@testable import DarkbloomClusterQualification
import DarkbloomClusterProtocol

private enum ClusterPairQualificationRecordShim {
    static func decode(_ text: String) throws -> [ClusterPairQualificationRecord] { try ClusterPairQualificationRecord.decodeLines(text) }
}

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
    /// Prefix reuse on (the default) runs the last prompt token in a frame of
    /// its own: 4 prefill frames for 40 tokens in frames of 16 instead of 3.
    /// Tokens and frontier equal, the frame counts are compared through each
    /// run's own framing (round 2 read `incomparable` here).
    func testPrefixCacheFramingIsComparedThroughEachRunsOwnPlan() throws {
        var split = Constructed.pair()
        split.completedFrames = 9
        split.prefillPlan = .init(reusedPromptTokens: 0, splitFinalPromptToken: true)
        XCTAssertEqual(split.prefillPlan?.prefillFrames(prompt: 40, chunk: 16), 4)
        let exact = try Constructed.compare(Constructed.reference(), split)
        XCTAssertEqual(exact.verdict, .exact, exact.reasons.joined(separator: "; "))
        XCTAssertEqual(exact.completedFramesEqual, false)
        XCTAssertTrue(exact.reasons.contains { $0.contains("framed differently") }, exact.reasons.joined(separator: "; "))
        var row = Constructed.row; row[4] += 0.125
        var differing = Constructed.pair(row: row)
        differing.completedFrames = 9; differing.prefillPlan = split.prefillPlan
        XCTAssertEqual(try Constructed.compare(Constructed.reference(), differing).verdict, .tokensEqualLogitsDiffer)
        // A cache hit that reused 32 tokens frames [32, 39, 40]: 3 frames.
        var hit = Constructed.pair()
        hit.prefillPlan = .init(reusedPromptTokens: 32, splitFinalPromptToken: true)
        hit.completedFrames = 8
        XCTAssertEqual(try Constructed.compare(Constructed.reference(), hit).verdict, .exact)
    }

    /// A frame difference no recorded plan accounts for stays incomparable.
    func testUnexplainedFrameDifferenceStaysIncomparable() throws {
        var unexplained = Constructed.pair()
        unexplained.completedFrames = 9
        XCTAssertEqual(try Constructed.compare(Constructed.reference(), unexplained).verdict, .incomparable)
        unexplained.prefillPlan = .init(reusedPromptTokens: 16, splitFinalPromptToken: true)  // 3 frames, not 4
        XCTAssertEqual(try Constructed.compare(Constructed.reference(), unexplained).verdict, .incomparable)
        var frontier = Constructed.pair()
        frontier.completedFrames = 9; frontier.committedTokens = 46
        frontier.prefillPlan = .init(reusedPromptTokens: 0, splitFinalPromptToken: true)
        XCTAssertEqual(try Constructed.compare(Constructed.reference(), frontier).verdict, .incomparable)
    }

    /// The sidecar's prefix summary becomes the evidence's plan; what each
    /// rank stored differs between the ranks and is not read.
    func testPairEvidenceReadsTheAgreedPrefixPlan() throws {
        func record(rank: Int, stored: [Int]) -> Data {
            var value: [String: Any] = ["schema": PairEvidence.schema, "rank": rank,
                "requestFingerprint": String(repeating: "c", count: 64), "profileFingerprint": String(repeating: "d", count: 64),
                "execution": ["selectedTokenIDs": [1, 2], "completedFrames": 5, "committedTokens": 41, "finishReason": "length",
                    "tokenChainSHA256": String(repeating: "e", count: 64),
                    "prefixCache": ["reusedPromptTokens": 0, "agreedPromptTokens": 0, "splitFinalToken": true,
                                    "storedFrontiers": stored, "cacheEntries": stored.count]],
                "agreement": ["requestID": "r", "sourceConfigurationSHA256": "s", "artifactAggregateSHA256": "a",
                    "storageCommitmentSHA256": "t", "planFingerprint": "p", "stageFingerprints": ["0", "1"],
                    "numericalPolicySHA256": "n"],
                "stateEntries": [["globalLayerIndex": rank, "component": "ssm", "shape": [1], "dtype": "float32",
                    "byteCount": 4, "sha256": String(repeating: "f", count: 64)]],
                "stageStateSHA256": String(repeating: "9", count: 64)]
            if rank == 1 {
                value["finalLogits"] = ["shape": [1, 2], "dtype": "bfloat16", "byteCount": 4,
                    "logicalBytesSHA256": String(repeating: "8", count: 64), "values": [0.5, 1.0]]
            }
            return try! JSONSerialization.data(withJSONObject: value)
        }
        let joined = try PairEvidence.join([PairEvidence.decode(record(rank: 0, stored: [32, 39]), rank: 0),
                                            PairEvidence.decode(record(rank: 1, stored: [39]), rank: 1)])
        XCTAssertEqual(joined.evidence.prefillPlan, .init(reusedPromptTokens: 0, splitFinalPromptToken: true))
    }

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

/// The qualification record a provider's pair-serving grant rests on: made by
/// the runner from a pair report and its single-Mac references, never by hand.
final class PairQualificationRecordTests: XCTestCase {
    private func referenceData(chip: String = "Apple M3 Ultra", margin: Float = 1.5) throws -> Data {
        let request = try Constructed.request()
        return try QualificationReportFiles.encode(ReferenceReport(identity: try Constructed.identity(), evidence: Constructed.reference(margin: margin),
            host: .init(role: "single host", chip: chip, operatingSystem: "27.2"), binarySHA256: nil, metallibSHA256: nil,
            timing: .init(stageLoadSeconds: [1, 2], prefillSeconds: 0.1, prefillTokensPerSecond: 400, decodeSeconds: 0.2,
                          decodeTokensPerSecond: 25, requestWallSeconds: 0.4, totalSeconds: 4, note: "constructed"),
            memory: .init(activeBytesBefore: 0, activeBytesLoaded: 10, peakBytes: 12, activeBytesAfterRelease: 0,
                          cacheBytesAfterRelease: 0, loadedTensorBytes: [4, 6], stageModelsReleased: [true, true]),
            promptSource: request.promptSource, decodedOutput: "text"))
    }
    private func pairData(chips: [String?] = ["Apple M3 Ultra", "Apple M5 Max"], tokens: [Int] = Constructed.tokens,
                          outcome: String = "completed", agree: Bool = true, transport: String? = "jaccl",
                          mode: String? = "phase_split_v1", finalRow: Bool = true, runtimeLines: [[String]?] = [],
                          recording: Bool = true, cut: Int = 12, decode: [Double]? = nil) throws -> Data {
        var ranks = (0..<chips.count).map { PairRankReport(role: "rank \($0)", rank: $0) }
        for (index, chip) in chips.enumerated() { ranks[index].chip = chip; ranks[index].operatingSystem = "27.\(index)" }
        for (index, lines) in runtimeLines.enumerated() where index < ranks.count { ranks[index].runtimeLines = lines }
        let request = try Constructed.request()
        var timing = PairTiming(note: "constructed")
        if let decode {
            timing.decodeTokensPerSecond = decode.first
            timing.repetitions = decode.enumerated().map { index, rate in
                PairRepetitionTiming(requestID: "r\(index)", admissionSeconds: 0.1, firstTokenSeconds: 0.5, prefillTokensPerSecond: 80,
                    decodeSeconds: 1, decodeTokensPerSecond: rate, totalSeconds: 1.5, secondTokenGapSeconds: nil, tokens: 6,
                    selectedTokenIDsSHA256: String(repeating: "9", count: 64), finishReason: "length")
            }
        }
        return try QualificationReportFiles.encode(PairReport(outcome: outcome, failure: nil, identity: try Constructed.identity(cut: cut),
            evidence: Constructed.pair(tokens: tokens, row: finalRow ? Constructed.row : nil), ranks: ranks.reversed(), workerHashesIdentical: true, metallibHashesIdentical: true,
            recording: recording, ranksAgreeOnTokens: agree, bothExitsObserved: true, noWorkerProcessLeft: true,
            progressTimeoutMilliseconds: nil, timing: timing, promptSource: request.promptSource,
            decodedOutput: nil, generationMode: mode, workerTransport: transport))
    }
    private let allowCut = QualificationComparator(allowCutDifference: true)

    func testAPassingRunIsARecordOfChipsCutModeAndVerdicts() throws {
        let pair = try pairData()
        let record = try PairQualificationRecords.make(pairReport: pair,
            references: [try referenceData(), try referenceData(chip: "Apple M5 Max")], comparator: allowCut)
        XCTAssertTrue(record.passed); XCTAssertTrue(record.isConsistent)
        XCTAssertEqual(record.ranks.map(\.chip), ["Apple M3 Ultra", "Apple M5 Max"])
        XCTAssertEqual(record.ranks.map(\.rank), [0, 1])
        XCTAssertEqual(record.cuts, [12]); XCTAssertEqual(record.generationMode, "phase_split_v1"); XCTAssertEqual(record.chunkTokens, 16)
        XCTAssertEqual(Set(record.comparisons.map(\.verdict)).count, 1, "\(record.comparisons)")
        XCTAssertTrue(record.comparisons.allSatisfy { $0.passes && $0.allowed == ["cut"] })
        XCTAssertEqual(record.comparisons.map(\.referenceChip), ["Apple M3 Ultra", "Apple M5 Max"])
        XCTAssertEqual(record.pairReportSHA256, QualificationHash.sha256(pair))
        XCTAssertEqual(record.runtimeModelID, try Constructed.identity().modelID)
        // One JSON line, read back as written.
        let line = try record.encodedLine()
        XCTAssertFalse(line.contains("\n"))
        XCTAssertEqual(try ClusterPairQualificationRecordShim.decode(line + "\n\n" + line), [record, record])
        // Without the cut allowance the reference's own cut makes it another request's reference: refused, not recorded.
        XCTAssertThrowsError(try PairQualificationRecords.make(pairReport: pair, references: [try referenceData()], comparator: .init()))
    }

    func testAFailingComparisonIsARecordThatFails() throws {
        // The pair chose another token where the reference led by 1.5 (12 units in the last place): not a near tie.
        let record = try PairQualificationRecords.make(pairReport: try pairData(tokens: [3, 4, 7, 1, 6, 3]),
            references: [try referenceData()], comparator: allowCut)
        XCTAssertEqual(record.comparisons.map(\.verdict), ["diverged"])
        XCTAssertEqual(record.comparisons.first?.firstDivergenceIndex, 2)
        XCTAssertFalse(record.passed); XCTAssertTrue(record.isConsistent)
        XCTAssertEqual(record.firstFailure?.verdict, "diverged")
        // The same choice at a near tie (margin 0.125 = 1 unit) passes.
        let tie = try PairQualificationRecords.make(pairReport: try pairData(tokens: [3, 4, 7, 1, 6, 3]),
            references: [try referenceData(margin: 0.125)], comparator: allowCut)
        XCTAssertEqual(tie.comparisons.map(\.verdict), ["divergedAtNearTie"]); XCTAssertTrue(tie.passed)
    }

    func testWhatCannotQualifyAPairIsRefused() throws {
        let reference = try referenceData()
        for (label, pair) in [("one Mac over a loopback socket", try pairData(transport: "local-socket-test")),
                              ("ranks disagree", try pairData(agree: false)),
                              ("did not complete", try pairData(outcome: "failed")),
                              ("a rank without a chip", try pairData(chips: ["Apple M3 Ultra", nil])),
                              ("an unknown mode", try pairData(mode: "tensor_parallel_v9")),
                              ("a timing run without a final row", try pairData(finalRow: false))] {
            XCTAssertThrowsError(try PairQualificationRecords.make(pairReport: pair, references: [reference], comparator: allowCut), label)
        }
        XCTAssertThrowsError(try PairQualificationRecords.make(pairReport: try pairData(), references: [], comparator: allowCut))
        // A pair report is not a reference, and a reference is not a pair.
        XCTAssertThrowsError(try PairQualificationRecords.make(pairReport: try pairData(), references: [try pairData()], comparator: allowCut))
        XCTAssertThrowsError(try PairQualificationRecords.make(pairReport: reference, references: [reference], comparator: allowCut))
        // Reports from before the transport and mode fields existed ran over JACCL as a pipeline.
        let old = try PairQualificationRecords.make(pairReport: try pairData(transport: nil, mode: nil), references: [reference], comparator: allowCut)
        XCTAssertEqual(old.transport, "jaccl"); XCTAssertEqual(old.generationMode, "pipeline_v1")
    }

    /// The product's tensor-parallel worker records no final row (no recording
    /// worker), so its served run is the record: tokens against each reference
    /// by the near-tie rule, and the layout each rank's load line names.
    private func tensorParallelLoad(rank: Int, shares: String = "1-3", sealed: Int = 1,
                                    plan: String = "qwen_dense_heads_and_channels_v1") -> [String] {
        ["darkbloom-link-probe-v1 rank=\(rank) transport=jaccl keyed=1",
         "darkbloom-tensor-parallel-load-v1 rank=\(rank) plan=\(plan) shares=\(shares) shard_bytes=10 source_bytes=20 tensors=3 load_ns=4 sealed=\(sealed)"]
    }

    func testAServedTensorParallelRunIsARecordOfItsLayout() throws {
        // The driver keeps each rank's tensor-parallel lines (and the worker's collective wait) as runtime lines.
        let sync = "darkbloom-collective-sync-v1 fast_synch=1 source=worker"
        XCTAssertEqual(PairDriver.runtimeLines(([sync] + tensorParallelLoad(rank: 0)).joined(separator: "\n") + "\nother output"),
                       [sync] + tensorParallelLoad(rank: 0))
        let loads = [tensorParallelLoad(rank: 0), tensorParallelLoad(rank: 1)]
        let pair = try pairData(mode: "tensor_parallel_v1", finalRow: false, runtimeLines: loads)
        let record = try PairQualificationRecords.make(pairReport: pair,
            references: [try referenceData(), try referenceData(chip: "Apple M5 Max")], comparator: allowCut)
        XCTAssertTrue(record.passed); XCTAssertTrue(record.isConsistent)
        XCTAssertEqual(record.generationMode, "tensor_parallel_v1"); XCTAssertEqual(record.cuts, [])
        // Equal tokens without a final row: all a tensor-parallel run can show (as the tp-check record says).
        XCTAssertEqual(record.comparisons.map(\.verdict), ["tokensEqualLogitsDiffer", "tokensEqualLogitsDiffer"])
        XCTAssertEqual(record.tensorParallelLayout,
            "plan=qwen_dense_heads_and_channels_v1;partials=float32;shares=1:3;reduction=sealed_all_gather_sum_v1")
        // A near tie passes, a clear winner taken differently fails: a record either way.
        let tie = try PairQualificationRecords.make(pairReport: try pairData(tokens: [3, 4, 7, 1, 6, 3], mode: "tensor_parallel_v1",
            finalRow: false, runtimeLines: loads), references: [try referenceData(margin: 0.125)], comparator: allowCut)
        XCTAssertEqual(tie.comparisons.map(\.verdict), ["divergedAtNearTie"]); XCTAssertTrue(tie.passed)
        let clear = try PairQualificationRecords.make(pairReport: try pairData(tokens: [3, 4, 7, 1, 6, 3], mode: "tensor_parallel_v1",
            finalRow: false, runtimeLines: loads), references: [try referenceData()], comparator: allowCut)
        XCTAssertEqual(clear.comparisons.map(\.verdict), ["diverged"]); XCTAssertFalse(clear.passed)
        // Equal shares are named as such.
        let equal = try PairQualificationRecords.make(pairReport: try pairData(mode: "tensor_parallel_v1", finalRow: false,
            runtimeLines: [tensorParallelLoad(rank: 0, shares: "1-1"), tensorParallelLoad(rank: 1, shares: "1-1")]),
            references: [try referenceData()], comparator: allowCut)
        XCTAssertEqual(equal.tensorParallelLayout,
            "plan=qwen_dense_heads_and_channels_v1;partials=float32;shares=equal;reduction=sealed_all_gather_sum_v1")
    }

    func testWhatCannotQualifyAServedTensorParallelRunIsRefused() throws {
        let reference = try referenceData()
        for (label, lines) in [("no load line", [nil, nil] as [[String]?]),
                               ("one rank's load line", [tensorParallelLoad(rank: 0), nil]),
                               ("ranks loaded other shares", [tensorParallelLoad(rank: 0), tensorParallelLoad(rank: 1, shares: "1-1")]),
                               ("ranks loaded other plans", [tensorParallelLoad(rank: 0), tensorParallelLoad(rank: 1, plan: "other_v1")]),
                               ("an unsealed all-sum", [tensorParallelLoad(rank: 0, sealed: 0), tensorParallelLoad(rank: 1, sealed: 0)]),
                               ("rank lines swapped", [tensorParallelLoad(rank: 1), tensorParallelLoad(rank: 0)])] {
            let pair = try pairData(mode: "tensor_parallel_v1", finalRow: false, runtimeLines: lines)
            XCTAssertThrowsError(try PairQualificationRecords.make(pairReport: pair, references: [reference], comparator: allowCut), label)
        }
        // Without a final row only tensor parallel is a record; any other mode's timing run still is not.
        XCTAssertThrowsError(try PairQualificationRecords.make(pairReport: try pairData(mode: "pipeline_v1", finalRow: false,
            runtimeLines: [tensorParallelLoad(rank: 0), tensorParallelLoad(rank: 1)]), references: [reference], comparator: allowCut))
    }

    /// A speculative pipeline's record may carry what timed runs of its own
    /// placement and request measured: its mode's decode against the plain
    /// pipeline's, the speed-up the planner credits it with.
    func testASpeculativePipelineRecordCarriesItsMeasuredSpeedUp() throws {
        let reference = try referenceData()
        let pair = try pairData(mode: "pipeline_mtp_v1")
        let modeTimed = try pairData(mode: "pipeline_mtp_v1", finalRow: false, recording: false, decode: [66.5, 59.1, 66.3])
        let plainTimed = try pairData(mode: "pipeline_v1", finalRow: false, recording: false, decode: [34.5, 36.1, 36.1])
        let record = try PairQualificationRecords.make(pairReport: pair, references: [reference], comparator: allowCut,
            timing: (mode: modeTimed, plain: plainTimed))
        XCTAssertTrue(record.passed); XCTAssertTrue(record.isConsistent)
        XCTAssertEqual(record.measuredDecode?.modeTokensPerSecond, 66.3)
        XCTAssertEqual(record.measuredDecode?.plainPipelineTokensPerSecond, 36.1)
        XCTAssertEqual(record.measuredDecode?.modeReportSHA256, QualificationHash.sha256(modeTimed))
        XCTAssertEqual(record.measuredPipelineSpeculativeSpeedup ?? 0, 66.3 / 36.1, accuracy: 1e-9)
        // It survives the record's one JSON line; a record without timing writes no such field.
        let line = try record.encodedLine()
        XCTAssertEqual(try ClusterPairQualificationRecordShim.decode(line), [record])
        let untimed = try PairQualificationRecords.make(pairReport: pair, references: [reference], comparator: allowCut)
        XCTAssertNil(untimed.measuredDecode); XCTAssertNil(untimed.measuredPipelineSpeculativeSpeedup)
        XCTAssertFalse(try untimed.encodedLine().contains("measuredDecode"))
        // Another family's record is never credited a speculative speed-up.
        let plainRecord = try PairQualificationRecords.make(pairReport: try pairData(mode: "pipeline_v1"), references: [reference],
            comparator: allowCut, timing: (mode: plainTimed, plain: plainTimed))
        XCTAssertNil(plainRecord.measuredPipelineSpeculativeSpeedup)
        // Timing runs of another placement, mode or kind are refused, not recorded.
        for (label, mode, plain) in [
            ("a recording as timing", try pairData(mode: "pipeline_mtp_v1", recording: true, decode: [60]), plainTimed),
            ("another cut", try pairData(mode: "pipeline_mtp_v1", finalRow: false, recording: false, cut: 16, decode: [60]), plainTimed),
            ("another order", try pairData(chips: ["Apple M5 Max", "Apple M3 Ultra"], mode: "pipeline_mtp_v1", finalRow: false,
                                           recording: false, decode: [60]), plainTimed),
            ("the mode run in another mode", plainTimed, plainTimed),
            ("the plain run in the mode", modeTimed, modeTimed),
            ("no decode rate", try pairData(mode: "pipeline_mtp_v1", finalRow: false, recording: false), plainTimed),
            ("over a loopback socket", try pairData(transport: "local-socket-test", mode: "pipeline_mtp_v1", finalRow: false,
                                                    recording: false, decode: [60]), plainTimed)] {
            XCTAssertThrowsError(try PairQualificationRecords.make(pairReport: pair, references: [reference], comparator: allowCut,
                timing: (mode: mode, plain: plain)), label)
        }
    }

    func testARecordWhoseStoredVerdictDisagreesWithItsComparisonsIsInconsistent() throws {
        let record = try PairQualificationRecords.make(pairReport: try pairData(tokens: [3, 4, 7, 1, 6, 3]),
            references: [try referenceData()], comparator: allowCut)
        let edited = try record.encodedLine().replacingOccurrences(of: "\"passed\":false", with: "\"passed\":true")
        let read = try XCTUnwrap(try ClusterPairQualificationRecordShim.decode(edited).first)
        XCTAssertTrue(read.passed); XCTAssertFalse(read.passesNearTieRule); XCTAssertFalse(read.isConsistent)
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
        // Derived from the protocol and the declared 262,144-token context:
        // the long-context sizes the owner asked for, and the protocol's edges.
        for prompt in [5120, 10_240, 20_480, 30_720] { XCTAssertNoThrow(try make(prompt: prompt, chunk: 512, output: 128)) }
        XCTAssertNoThrow(try make(prompt: 32_767, chunk: 512, output: 1)); XCTAssertNoThrow(try make(prompt: 28_672, output: 4096))
        XCTAssertNoThrow(try make(stops: [248_044, 248_046]))
        XCTAssertThrowsError(try make(prompt: 0)); XCTAssertThrowsError(try make(prompt: 32_769, output: 1))
        XCTAssertNoThrow(try make(prompt: 32_768, output: 32_768))
        XCTAssertThrowsError(try make(chunk: 513)); XCTAssertThrowsError(try make(chunk: 0))
        XCTAssertThrowsError(try make(output: 32_769)); XCTAssertThrowsError(try make(output: 0))
        XCTAssertThrowsError(try make(first: 248_320)); XCTAssertThrowsError(try make(first: -1))
        XCTAssertThrowsError(try make(stops: [9, 3])); XCTAssertThrowsError(try make(stops: [3, 3]))
        // A stored request is checked again when read, including its prompt hash.
        var stored = try make()
        let data = try stored.encoded()
        XCTAssertEqual(try JSONDecoder().decode(QualificationRequest.self, from: data), stored)
        stored.promptTokenIDs[0] = 6
        XCTAssertThrowsError(try stored.validate())
    }

    /// A request names one registered model; its profile and cuts follow from
    /// that row, and a pair run takes its cut from the request's model.
    func testRequestNamesOneRegisteredModelAndCarriesThatModelsCuts() throws {
        func make(_ modelID: String? = nil) throws -> QualificationRequest {
            let source = QualificationPromptSource(kind: "tokenIDs", description: "test")
            guard let modelID else {
                return try .init(requestID: UUID(), promptTokenIDs: Array(1...40), chunkSize: 16, outputCount: 4,
                                 stopTokenIDs: [], promptSource: source)
            }
            return try .init(requestID: UUID(), promptTokenIDs: Array(1...40), chunkSize: 16, outputCount: 4,
                             stopTokenIDs: [], promptSource: source, modelID: modelID)
        }
        // The default is the original model, with its original bytes on disk.
        let small = try make()
        XCTAssertEqual(small.modelID, "registered_qwen35_9b"); XCTAssertEqual(small.profileID, "registered_qwen35_9b_greedy_generation_v1")
        XCTAssertEqual(small.supportedCuts, [4, 8, 12, 16]); XCTAssertEqual(try make("registered_qwen35_9b").profileID, small.profileID)
        let large = try make("registered_qwen38_27b")
        XCTAssertEqual(large.profileID, "registered_qwen38_27b_greedy_generation_v1")
        XCTAssertEqual(large.supportedCuts, Array(stride(from: 4, through: 60, by: 4)))
        XCTAssertEqual(try JSONDecoder().decode(QualificationRequest.self, from: try large.encoded()), large)
        XCTAssertEqual(QualificationRequest.registeredModels.map(\.modelID),
                       ["registered_qwen35_9b", "registered_qwen38_27b", "registered_qwen35_35b_a3b",
                        "registered_qwen36_35b_a3b", "registered_ternary_bonsai_2_27b", "registered_nemotron35_lightning",
                        "registered_gpt_oss_20b", "registered_mimo_v26_flash_mopd",
                        "registered_gemma4_26b_qat_4bit", "registered_gemma4_26b", "registered_gemma4_26b_8bit",
                        "registered_glm53_flash"])
        // A model with routed experts adds its route to the three common variables; the others add nothing.
        XCTAssertEqual(small.arithmeticEnvironment.map(\.0), PairConfiguration.arithmeticEnvironment.map(\.0))
        XCTAssertEqual(large.arithmeticEnvironment.map(\.1), PairConfiguration.arithmeticEnvironment.map(\.1))
        let routed = try make("registered_qwen35_35b_a3b")
        XCTAssertEqual(routed.supportedCuts, Array(stride(from: 4, through: 36, by: 4)))
        XCTAssertEqual(routed.arithmeticEnvironment.map { "\($0.0)=\($0.1)" }, ["DARKBLOOM_CBV2_ATTN_QUERY_BLOCK=128",
            "DARKBLOOM_BF16_WEIGHTS=1", "MLX_ENABLE_TF32=1", "MLX_GATHER_QMM_EXPERT_SLICES=trust"])
        // GPT-OSS on its own adapter: its own profile and its own cuts.
        let gptoss = try make("registered_gpt_oss_20b")
        XCTAssertEqual(gptoss.profileID, "registered_gpt_oss_20b_greedy_generation_v1")
        XCTAssertEqual(gptoss.supportedCuts, Array(1...23))
        XCTAssertEqual(try JSONDecoder().decode(QualificationRequest.self, from: try gptoss.encoded()), gptoss)
        // MiMo's row: its own cuts and session bound, and no recording runtime.
        let mimo = try make("registered_mimo_v26_flash_mopd")
        XCTAssertEqual(mimo.profileID, "registered_mimo_v26_flash_mopd_greedy_generation_v1")
        XCTAssertEqual(mimo.supportedCuts, Array(1...47))
        let mimoRow = try XCTUnwrap(QualificationRequest.registeredModel(mimo.modelID))
        XCTAssertFalse(mimoRow.hasRecordingRuntime)
        XCTAssertEqual(QualificationRequest.registeredModel(large.modelID)?.hasRecordingRuntime, true)
        // GLM retains its own profile, every layer boundary, and no recording runtime.
        let glm = try make("registered_glm53_flash")
        XCTAssertEqual(glm.profileID, "registered_glm53_flash_greedy_generation_v1")
        XCTAssertEqual(glm.supportedCuts, Array(1...44))
        XCTAssertFalse(try XCTUnwrap(QualificationRequest.registeredModel(glm.modelID)).hasRecordingRuntime)
        XCTAssertEqual(try JSONDecoder().decode(QualificationRequest.self, from: try glm.encoded()), glm)
        // A Gemma request carries its own vocabulary and its two serving values; a Qwen request keeps the Qwen bound.
        let source = QualificationPromptSource(kind: "tokenIDs", description: "test")
        let gemma = try QualificationRequest(requestID: UUID(), promptTokenIDs: [2, 262_143], chunkSize: 2, outputCount: 4,
            stopTokenIDs: [1, 106], promptSource: source, modelID: "registered_gemma4_26b_qat_4bit")
        XCTAssertEqual(gemma.profileID, "registered_gemma4_26b_qat_4bit_greedy_generation_v1")
        XCTAssertEqual(gemma.supportedCuts, Array(1...29))
        XCTAssertEqual(try JSONDecoder().decode(QualificationRequest.self, from: try gemma.encoded()), gemma)
        XCTAssertThrowsError(try QualificationRequest(requestID: UUID(), promptTokenIDs: [262_144], chunkSize: 1,
            outputCount: 1, stopTokenIDs: [], promptSource: source, modelID: "registered_gemma4_26b"))
        XCTAssertThrowsError(try QualificationRequest(requestID: UUID(), promptTokenIDs: [248_320], chunkSize: 1,
            outputCount: 1, stopTokenIDs: [], promptSource: source))
        XCTAssertEqual(gemma.arithmeticEnvironment.map { "\($0.0)=\($0.1)" }, ["DARKBLOOM_CBV2_ATTN_QUERY_BLOCK=128",
            "DARKBLOOM_BF16_WEIGHTS=1", "MLX_ENABLE_TF32=1", "MLX_GATHER_QMM_EXPERT_SLICES=trust",
            "MLX_GEMMA4_FUSED_WEIGHTED_UNSORT=1"])
        for unknown in ["", "registered_qwen4", "EigenLabs/Qwen3.8-27B-4bit-mtp", "registered_qwen38_27b "] {
            XCTAssertThrowsError(try make(unknown), unknown)
        }
        // A stored request cannot pair one model with the other's profile.
        var crossed = large
        crossed.profileID = small.profileID
        XCTAssertThrowsError(try crossed.validate())
        crossed = small; crossed.modelID = large.modelID
        XCTAssertThrowsError(try crossed.validate())
        crossed = large; crossed.modelID = "registered_qwen4"
        XCTAssertThrowsError(try crossed.validate()); XCTAssertEqual(crossed.supportedCuts, [])

        func pair(_ request: QualificationRequest, cut: Int) throws -> PairConfiguration {
            let side = PairSide(modelDirectory: "/models/registered", workerPath: "/opt/worker/darkbloom-cluster-worker",
                                rdmaDevice: "rdma_en5", scratchDirectory: "/tmp")
            return try .init(request: request, stageCut: cut, local: side, remote: side,
                             remoteTransport: ["/bin/sh", "-c"], coordinator: "10.0.0.5:4499", progressTimeoutMilliseconds: 60_000)
        }
        for cut in stride(from: 4, through: 60, by: 4) {
            let configuration = try pair(large, cut: cut)
            XCTAssertTrue(configuration.launchScript(0, artifactSHA256: String(repeating: "a", count: 64),
                configurationSHA256: String(repeating: "b", count: 64), workerSHA256: String(repeating: "c", count: 64))
                .contains("'--stage-cut' '\(cut)' "))
        }
        XCTAssertTrue(try pair(large, cut: 16).launchScript(1, artifactSHA256: String(repeating: "a", count: 64),
            configurationSHA256: String(repeating: "b", count: 64), workerSHA256: String(repeating: "c", count: 64))
            .contains("'--model-id' 'registered_qwen38_27b'"))
        // Only the routed-expert model's ranks are launched with the expert route set.
        func launch(_ request: QualificationRequest, cut: Int) throws -> String {
            try pair(request, cut: cut).launchScript(0, artifactSHA256: String(repeating: "a", count: 64),
                configurationSHA256: String(repeating: "b", count: 64), workerSHA256: String(repeating: "c", count: 64))
        }
        XCTAssertTrue(try launch(routed, cut: 20).contains("MLX_ENABLE_TF32='1' MLX_GATHER_QMM_EXPERT_SLICES='trust' JACCL_RANK='0'"))
        XCTAssertFalse(try launch(large, cut: 16).contains("MLX_GATHER_QMM_EXPERT_SLICES"))
        XCTAssertFalse(try launch(small, cut: 8).contains("MLX_GATHER_QMM_EXPERT_SLICES"))
        XCTAssertThrowsError(try pair(routed, cut: 40)); XCTAssertThrowsError(try pair(routed, cut: 6))
        for cut in [0, 2, 6, 18, 62, 64] { XCTAssertThrowsError(try pair(large, cut: cut), "27B cut \(cut)") }
        // The Prism Hadamard pack: the 27B's cuts under its own profile, and a
        // rank started with the two switches its arithmetic contract pins. The
        // other models' ranks are started exactly as before.
        let packed = try make("registered_ternary_bonsai_2_27b")
        XCTAssertEqual(packed.profileID, "registered_ternary_bonsai_2_27b_greedy_generation_v1")
        XCTAssertEqual(packed.supportedCuts, large.supportedCuts)
        XCTAssertEqual(try JSONDecoder().decode(QualificationRequest.self, from: try packed.encoded()), packed)
        crossed = packed; crossed.profileID = large.profileID
        XCTAssertThrowsError(try crossed.validate())
        let common = "DARKBLOOM_CBV2_ATTN_QUERY_BLOCK='128' DARKBLOOM_BF16_WEIGHTS='1' MLX_ENABLE_TF32='1' "
        let switches = "DARKBLOOM_BONSAI_F16_CONSTANT_CACHE='1' DARKBLOOM_BONSAI_PREFILL_CARRY_ASYNC='1' "
        for rank in [0, 1] {
            let script = try pair(packed, cut: 24).launchScript(rank, artifactSHA256: String(repeating: "a", count: 64),
                configurationSHA256: String(repeating: "b", count: 64), workerSHA256: String(repeating: "c", count: 64))
            XCTAssertTrue(script.contains(common + switches + "JACCL_RANK='\(rank)' "), script)
            XCTAssertTrue(script.contains("'--model-id' 'registered_ternary_bonsai_2_27b'") && script.contains("'--stage-cut' '24' "))
            for other in [(small, 8), (large, 24)] {
                let plain = try pair(other.0, cut: other.1).launchScript(rank, artifactSHA256: String(repeating: "a", count: 64),
                    configurationSHA256: String(repeating: "b", count: 64), workerSHA256: String(repeating: "c", count: 64))
                XCTAssertTrue(plain.contains(common + "JACCL_RANK='\(rank)' ") && !plain.contains("BONSAI"), plain)
            }
        }
        XCTAssertEqual(packed.arithmeticEnvironment.map(\.0), ["DARKBLOOM_CBV2_ATTN_QUERY_BLOCK", "DARKBLOOM_BF16_WEIGHTS",
            "MLX_ENABLE_TF32", "DARKBLOOM_BONSAI_F16_CONSTANT_CACHE", "DARKBLOOM_BONSAI_PREFILL_CARRY_ASYNC"])
        XCTAssertEqual(large.arithmeticEnvironment.map(\.0), PairConfiguration.arithmeticEnvironment.map(\.0))
        for cut in [4, 8, 12, 16] { XCTAssertNoThrow(try pair(small, cut: cut)) }
        for cut in [20, 32, 60] { XCTAssertThrowsError(try pair(small, cut: cut), "9B cut \(cut)") }
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

    /// Rank 1 of a recorded speculative pipeline records one step per selected
    /// token (the accepted timeline); the joined evidence carries them.
    func testRankOneStepsOfASpeculativePipelineJoinTheEvidence() throws {
        func step(_ ordinal: Int, _ token: Int) -> [String: Any] {
            ["ordinal": ordinal, "frameSequence": 2 + ordinal, "committedTokens": 8 + ordinal, "tokenID": token,
             "topTokenIDs": [token, 1, 2, 3], "topLogits": [9.5, 9.0, 4.0, 1.0], "maximumTieCount": 1,
             "rowSHA256": String(repeating: "\(ordinal)", count: 64), "rowDType": "bfloat16"]
        }
        func record(rank: Int, steps: [[String: Any]]?) -> Data {
            var value: [String: Any] = ["schema": PairEvidence.schema, "rank": rank,
                "requestFingerprint": String(repeating: "a", count: 64), "profileFingerprint": String(repeating: "b", count: 64),
                "execution": ["selectedTokenIDs": [5, 6], "completedFrames": 3, "committedTokens": 9, "finishReason": "length",
                              "tokenChainSHA256": String(repeating: "c", count: 64)],
                "agreement": ["requestID": "r", "sourceConfigurationSHA256": "s", "artifactAggregateSHA256": "t",
                              "storageCommitmentSHA256": "u", "planFingerprint": "p", "stageFingerprints": ["v", "w"],
                              "numericalPolicySHA256": "x"],
                "stateEntries": [["globalLayerIndex": rank * 4, "component": "ssm", "shape": [1, 2], "dtype": "float32",
                                  "byteCount": 8, "sha256": String(repeating: "d", count: 64)]],
                "stageStateSHA256": String(repeating: "e", count: 64)]
            if rank == 1 {
                value["finalLogits"] = ["shape": [1, 3], "dtype": "bfloat16", "byteCount": 6,
                    "logicalBytesSHA256": String(repeating: "f", count: 64), "values": [1.5, -0.25, 7.0]]
            }
            if let steps { value["steps"] = steps }
            return try! JSONSerialization.data(withJSONObject: value)
        }
        let rank0 = try PairEvidence.decode(record(rank: 0, steps: nil), rank: 0)
        let joined = try PairEvidence.join([rank0, try .decode(record(rank: 1, steps: [step(0, 5), step(1, 6)]), rank: 1)])
        XCTAssertEqual(joined.evidence.steps?.map(\.tokenID), [5, 6])
        XCTAssertEqual(joined.evidence.steps?.map(\.rowDType), ["bfloat16", "bfloat16"])
        XCTAssertEqual(joined.evidence.steps?.last?.topLogits, [9.5, 9.0, 4.0, 1.0])
        // A plain record has none; steps on rank 0, a missing step or another token are refused.
        XCTAssertNil(try PairEvidence.join([rank0, try .decode(record(rank: 1, steps: nil), rank: 1)]).evidence.steps)
        XCTAssertThrowsError(try PairEvidence.decode(record(rank: 0, steps: [step(0, 5), step(1, 6)]), rank: 0))
        XCTAssertThrowsError(try PairEvidence.join([rank0, try .decode(record(rank: 1, steps: [step(0, 5)]), rank: 1)]))
        XCTAssertThrowsError(try PairEvidence.join([rank0, try .decode(record(rank: 1, steps: [step(0, 5), step(1, 7)]), rank: 1)]))
    }
}

final class QualificationLongContextTests: XCTestCase {
    func testLimitsAreDerivedFromTheDeclaredContextAndTheProtocol() {
        let dense = QualificationLimits.forModel("registered_qwen38_27b")
        XCTAssertEqual(dense, QualificationLimits.forModel("registered_qwen35_9b"))
        XCTAssertEqual(dense.maximumContextTokens, 32_768); XCTAssertEqual(dense.maximumPromptTokens, 32_767)
        XCTAssertEqual(dense.maximumOutputTokens, 4096); XCTAssertEqual(dense.maximumChunkTokens, 512)
        // A smaller declared context binds before the protocol does.
        let small = QualificationLimits.derived(declaredContextTokens: 4096)
        XCTAssertEqual(small.maximumContextTokens, 4096); XCTAssertEqual(small.maximumPromptTokens, 4095)
        XCTAssertEqual(small.maximumOutputTokens, 4095)
        // A model without a declared context here keeps the earlier reservation.
        XCTAssertEqual(QualificationLimits.forModel("registered_some_other_model"), .reservation)
        XCTAssertNil(dense.refusal(promptTokens: 30_720, outputTokens: 128, chunkTokens: 512))
        XCTAssertEqual(dense.refusal(promptTokens: 30_720, outputTokens: 2049, chunkTokens: 512),
                       "prompt plus output exceeds 32768 tokens")
        XCTAssertNotNil(QualificationLimits.reservation.refusal(promptTokens: 8193, outputTokens: 1, chunkTokens: 512))
    }

    func testBudgetsScaleWithThePromptAndNeverShrinkBelowTheEarlierValues() throws {
        let large = try XCTUnwrap(QualificationTimeBudget.forModel("registered_qwen38_27b"))
        let small = try XCTUnwrap(QualificationTimeBudget.forModel("registered_qwen35_9b"))
        // Monotone in the prompt, and more than linear: attention grows with context.
        let sizes = [1024, 5120, 10_240, 20_480, 30_720]
        let firsts = sizes.map { large.firstTokenSeconds(promptTokens: $0) }
        XCTAssertEqual(firsts, firsts.sorted()); XCTAssertEqual(Set(firsts).count, firsts.count)
        XCTAssertGreaterThan(large.prefillSeconds(promptTokens: 30_720), 6 * large.prefillSeconds(promptTokens: 5120))
        // The 27B's first token at 30,720 on the slower Mac: 30,720 / 307 s times
        // (1 + 30,720 / 32,768), with half again and 10 s on top.
        XCTAssertEqual(large.firstTokenSeconds(promptTokens: 30_720), 301)
        XCTAssertLessThan(small.firstTokenSeconds(promptTokens: 30_720), large.firstTokenSeconds(promptTokens: 30_720))
        // A fixed 60 s collective limit holds for these models' frames; the
        // limit scales only once a frame on the slower Mac needs it.
        XCTAssertEqual(large.progressTimeoutMilliseconds(promptTokens: 30_720, chunkTokens: 512), 60_000)
        let slow = QualificationTimeBudget(slowestPrefillTokensPerSecond: 20, slowestDecodeTokensPerSecond: 5,
                                           attentionDoublingTokens: 32_768)
        XCTAssertGreaterThan(slow.progressTimeoutMilliseconds(promptTokens: 30_720, chunkTokens: 512), 600_000 - 1)
        // Lifetime: startup plus every request, bounded by the protocol's deadline.
        XCTAssertEqual(large.lifetimeSeconds(promptTokens: 30_720, outputTokens: 128, repetitions: 4, startupSeconds: 150),
                       150 + 4 * large.requestSeconds(promptTokens: 30_720, outputTokens: 128) + 30)
        XCTAssertEqual(large.lifetimeSeconds(promptTokens: 32_000, outputTokens: 4096, repetitions: 8, startupSeconds: 150), 3600)
        XCTAssertNil(QualificationTimeBudget.forModel("registered_some_other_model"))
    }

    func testDriverBudgetsDefaultToTheScaledValuesAndKeepTheEarlierFloors() throws {
        func request(_ prompt: Int, model: String) throws -> QualificationRequest {
            try .init(requestID: UUID(), promptTokenIDs: Array(repeating: 5, count: prompt), chunkSize: 512, outputCount: 128,
                      stopTokenIDs: [], promptSource: .init(kind: "tokenIDs", description: "test"), modelID: model)
        }
        let short = PairCheckBudgetsProbe.make(try request(1024, model: "registered_qwen35_9b"), repetitions: 4)
        XCTAssertGreaterThanOrEqual(short.lifetime, 240); XCTAssertLessThan(short.lifetime, 300)
        XCTAssertEqual(short.request, 100); XCTAssertEqual(short.progress, 60_000)
        let long = PairCheckBudgetsProbe.make(try request(30_720, model: "registered_qwen38_27b"), repetitions: 4)
        XCTAssertGreaterThan(long.request, 300); XCTAssertGreaterThan(long.lifetime, 4 * 300)
        XCTAssertLessThanOrEqual(long.lifetime, SoloConfiguration.maximumLifetimeSeconds)
    }
}

/// The driver's budget rule, restated over the library types: the executable
/// target that holds `PairCheckBudgets` is not linked into this test bundle.
enum PairCheckBudgetsProbe {
    static func make(_ request: QualificationRequest, repetitions: Int) -> (lifetime: Int, request: Int, progress: Int) {
        guard let budget = QualificationTimeBudget.forModel(request.modelID) else { return (240, 100, 60_000) }
        let prompt = request.promptTokenIDs.count, output = request.outputCount
        let lifetime = max(240, budget.lifetimeSeconds(promptTokens: prompt, outputTokens: output, repetitions: repetitions, startupSeconds: 120))
        return (lifetime, min(max(100, budget.requestSeconds(promptTokens: prompt, outputTokens: output)), lifetime),
                budget.progressTimeoutMilliseconds(promptTokens: prompt, chunkTokens: request.chunkSize))
    }
}
