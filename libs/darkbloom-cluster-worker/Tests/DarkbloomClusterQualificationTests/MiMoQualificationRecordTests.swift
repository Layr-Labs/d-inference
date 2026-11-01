import Foundation
import XCTest
@testable import DarkbloomClusterQualification
import DarkbloomClusterProtocol

/// MiMo's qualification record: a pair run's decoding-rank step lines held
/// against a `mimo-reference` report (no final row on either side).
/// Constructed rows sit near 20, where one bfloat16 unit in the last place is 0.125.
final class MiMoQualificationRecordTests: XCTestCase {
    private static let model = "registered_mimo_v26_flash_mopd"
    private static let requestID = "93ad1cb8-05c9-48dc-9d62-58d578bd299d"
    private static let artifact = String(repeating: "a", count: 64)
    private static let tokens = [785, 2326, 6028, 7987, 315]

    private func identity(cut: Int = 31) throws -> QualificationIdentity {
        let request = try QualificationRequest(requestID: UUID(uuidString: Self.requestID)!, promptTokenIDs: Array(1...27),
            chunkSize: 512, outputCount: 64, stopTokenIDs: [151643], promptSource: .init(kind: "tokenIDs", description: "constructed"))
        var value = QualificationIdentity(request: request, stageCut: cut, prefillSchedule: "serial_v1", artifactSHA256: Self.artifact,
            configurationSHA256: String(repeating: "b", count: 64), planSHA256: "plan-\(cut)")
        value.modelID = Self.model; value.profileID = Self.model + "_greedy_generation_v1"
        return value
    }

    private func row(_ ordinal: Int, salt: String = "") -> String {
        QualificationHash.sha256(Data("row-\(ordinal)\(salt)".utf8))
    }

    /// Candidates of one row: the selected token leads the runner-up `margin` below it.
    private func candidates(_ token: Int, margin: Float) -> [(Int, Float)] {
        [(token, 20.0), (7, 20.0 - margin), (5, 12.0), (2, 4.0)]
    }

    private func referenceData(tokens: [Int] = tokens, margin: Float = 1.5, cut: Int = 31, requestID: String = requestID,
                               artifact: String = artifact, chip: String? = "Apple M5 Ultra", dropRow: Int? = nil,
                               rowSalt: String = "", request: [String: Any]? = nil) throws -> Data {
        var steps: [[String: Any]] = []
        for (ordinal, token) in tokens.enumerated() where ordinal != dropRow {
            steps.append(["ordinal": ordinal, "boundarySHA256": String(repeating: "c", count: 64), "rowSHA256": row(ordinal, salt: rowSalt),
                          "rowDType": "bfloat16",
                          "top": candidates(token, margin: margin).map { ["tokenID": $0.0, "logit": $0.1, "logitBits": String(format: "%08x", $0.1.bitPattern)] }])
        }
        var object: [String: Any] = ["schema": "mimo_staged_reference_v2", "runtimeModelID": Self.model, "stageCut": cut,
            "requestID": requestID, "promptTokens": 27, "selectedTokenIDs": tokens, "finishReason": "length",
            "boundaryChainSHA256": String(repeating: "d", count: 64), "steps": steps, "verifiedAggregateSHA256": artifact,
            "planSHA256": "plan-\(cut)", "storageCommitmentSHA256": String(repeating: "e", count: 64), "modelsReleased": [true, true]]
        if let chip { object["host"] = ["role": "single host", "chip": chip, "operatingSystem": "27.0.1"] }
        if let request { object["request"] = request }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func stepLine(rank: Int, ordinal: Int, token: Int, margin: Float, rowSalt: String) -> String {
        let top = candidates(token, margin: margin).map { "\($0.0)_" + String(format: "%08x", $0.1.bitPattern) }.joined(separator: "_")
        return "darkbloom-mimo-step-v1 rank=\(rank) i=\(ordinal) boundary=\(String(repeating: "c", count: 16)) "
            + "row=\(row(ordinal, salt: rowSalt).prefix(16)) dtype=bfloat16 top=\(top)"
    }

    private func pairData(tokens: [Int] = tokens, stepLines: Bool = true, dropLine: Int? = nil, rowSalt: String = "",
                          lineMargin: Float = 1.5, cut: Int = 31) throws -> Data {
        var ranks = [PairRankReport(role: "rank 0 local", rank: 0), PairRankReport(role: "rank 1 remote", rank: 1)]
        ranks[0].chip = "Apple M3 Ultra"; ranks[1].chip = "Apple M5 Ultra"
        ranks[0].runtimeLines = ["darkbloom-stage-loaded-range-v1 rank=0 model=\(Self.model) first=0 end=\(cut) layers=\(cut)"]
        if stepLines {
            ranks[1].runtimeLines = ["darkbloom-stage-loaded-range-v1 rank=1 model=\(Self.model) first=\(cut) end=48 layers=\(48 - cut)"]
                + tokens.enumerated().filter { $0.offset != dropLine }.reversed().map {
                    stepLine(rank: 1, ordinal: $0.offset, token: $0.element, margin: lineMargin, rowSalt: rowSalt)
                }
        }
        let request = try QualificationRequest(requestID: UUID(uuidString: Self.requestID)!, promptTokenIDs: Array(1...27),
            chunkSize: 512, outputCount: 64, stopTokenIDs: [151643], promptSource: .init(kind: "tokenIDs", description: "constructed"))
        return try QualificationReportFiles.encode(PairReport(outcome: "completed", failure: nil, identity: try identity(cut: cut),
            evidence: .init(selectedTokenIDs: tokens, finishReason: "length"), ranks: ranks, workerHashesIdentical: true,
            metallibHashesIdentical: true, recording: false, ranksAgreeOnTokens: nil, bothExitsObserved: true,
            noWorkerProcessLeft: true, progressTimeoutMilliseconds: nil, timing: .init(note: "constructed"),
            promptSource: request.promptSource, decodedOutput: nil, generationMode: "pipeline_v1", workerTransport: "jaccl"))
    }

    func testEqualRowsAreAnExactPassingRecordNamingTheReferenceChip() throws {
        let record = try PairQualificationRecords.make(pairReport: try pairData(), references: [try referenceData()], comparator: .init())
        XCTAssertEqual(record.comparisons.map(\.verdict), ["exact"])
        XCTAssertTrue(record.passed); XCTAssertTrue(record.isConsistent)
        XCTAssertEqual(record.runtimeModelID, Self.model); XCTAssertEqual(record.cuts, [31]); XCTAssertEqual(record.generationMode, "pipeline_v1")
        XCTAssertEqual(record.ranks.map(\.chip), ["Apple M3 Ultra", "Apple M5 Ultra"])
        XCTAssertEqual(record.comparisons.first?.referenceChip, "Apple M5 Ultra")
        XCTAssertEqual(record.comparisons.first?.allowed, ["request-by-id"])
        // A reference written before the report named its Mac records no chip, and still compares.
        let older = try PairQualificationRecords.make(pairReport: try pairData(), references: [try referenceData(chip: nil)], comparator: .init())
        XCTAssertNil(older.comparisons.first?.referenceChip); XCTAssertTrue(older.passed)
    }

    func testEqualTokensWithAnyOtherRowAreTokensEqualLogitsDiffer() throws {
        let record = try PairQualificationRecords.make(pairReport: try pairData(rowSalt: "pair"), references: [try referenceData()],
                                                       comparator: .init())
        XCTAssertEqual(record.comparisons.map(\.verdict), ["tokensEqualLogitsDiffer"]); XCTAssertTrue(record.passed)
    }

    func testADivergenceIsJudgedOnTheReferencesOwnCandidates() throws {
        let different = [785, 2326, 7, 7987, 315]
        // The reference led by 1.5 (12 units in the last place): not a near tie, the record fails.
        let failed = try PairQualificationRecords.make(pairReport: try pairData(tokens: different), references: [try referenceData()],
                                                       comparator: .init())
        XCTAssertEqual(failed.comparisons.map(\.verdict), ["diverged"]); XCTAssertEqual(failed.comparisons.first?.firstDivergenceIndex, 2)
        XCTAssertFalse(failed.passed); XCTAssertTrue(failed.isConsistent); XCTAssertEqual(failed.outcome, .diverged)
        // The same choice where the reference led by one unit (0.125) is a near tie: the record passes.
        let tie = try PairQualificationRecords.make(pairReport: try pairData(tokens: different, lineMargin: 0.125),
                                                    references: [try referenceData(margin: 0.125)], comparator: .init())
        XCTAssertEqual(tie.comparisons.map(\.verdict), ["divergedAtNearTie"]); XCTAssertTrue(tie.passed)
        XCTAssertEqual(tie.comparisons.first?.gapInULPs, 1)
    }

    func testWhatCannotQualifyMiMoIsRefused() throws {
        let reference = try referenceData()
        for (label, pair) in [("a timing run: no step lines", try pairData(stepLines: false)),
                              ("a truncated tail: a step line missing", try pairData(dropLine: 0))] {
            XCTAssertThrowsError(try PairQualificationRecords.make(pairReport: pair, references: [reference], comparator: .init()), label)
        }
        for (label, other) in [("another request", try referenceData(requestID: "0f1e2d3c-4b5a-4978-8695-a4b3c2d1e0f9")),
                               ("another artifact", try referenceData(artifact: String(repeating: "9", count: 64))),
                               ("another cut without the cut allowance", try referenceData(cut: 34)),
                               ("a reference missing a row", try referenceData(dropRow: 3))] {
            XCTAssertThrowsError(try PairQualificationRecords.make(pairReport: try pairData(), references: [other], comparator: .init()), label)
        }
        // With the cut allowance a reference at another cut compares (the plan follows the cut).
        let cut = try PairQualificationRecords.make(pairReport: try pairData(), references: [try referenceData(cut: 34)],
                                                    comparator: .init(allowCutDifference: true))
        XCTAssertEqual(cut.comparisons.first?.allowed, ["cut", "request-by-id"]); XCTAssertTrue(cut.passed)
    }

    /// The request fields a reference names, as `mimo-reference` writes them since 2026-10-14.
    private func requestBlock(prompt: [Int] = Array(1...27), chunk: Int = 512, outputs: Int = 64,
                              stops: [Int] = [151643]) -> [String: Any] {
        ["promptTokenIDsSHA256": QualificationHash.tokenIDs(prompt), "chunkSize": chunk, "outputCount": outputs, "stopTokenIDs": stops]
    }

    /// A reference that names its request is bound to it: the prompt, chunk,
    /// outputs and stops are compared with the pair's, as for every other
    /// family, and no request-by-ID allowance is listed. One that differs in
    /// any of them is another request, whatever its request ID.
    func testAReferenceThatNamesItsRequestIsComparedOnIt() throws {
        let bound = try PairQualificationRecords.make(pairReport: try pairData(),
            references: [try referenceData(request: requestBlock())], comparator: .init())
        XCTAssertEqual(bound.comparisons.map(\.verdict), ["exact"]); XCTAssertTrue(bound.passed)
        XCTAssertEqual(bound.comparisons.first?.allowed, [])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mimo-bound-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("pair.json")
        try QualificationFiles.writeNew(try pairData(), to: file)
        let pair = try QualificationReportFiles.subject(file)
        for (label, block) in [("another prompt of the same length", requestBlock(prompt: Array(2...28))),
                               ("another chunk", requestBlock(chunk: 256)),
                               ("another output count", requestBlock(outputs: 32)),
                               ("other stops", requestBlock(stops: [2]))] {
            XCTAssertThrowsError(try PairQualificationRecords.make(pairReport: try pairData(),
                references: [try referenceData(request: block)], comparator: .init()), label)
            let subject = try MiMoQualificationEvidence.reference(try referenceData(request: block), comparableWith: pair.identity).subject
            XCTAssertFalse(try QualificationComparator().compare(reference: subject, candidate: pair).identityMatches, label)
        }
        // A malformed request block is refused, not ignored.
        var malformed = requestBlock(); malformed["promptTokenIDsSHA256"] = "not-a-digest"
        XCTAssertThrowsError(try PairQualificationRecords.make(pairReport: try pairData(),
            references: [try referenceData(request: malformed)], comparator: .init()))
    }

    func testTheComparatorReadsMiMoPairReportsFromTheirFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mimo-qualification-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("pair.json")
        try QualificationFiles.writeNew(try pairData(), to: file)
        let pair = try QualificationReportFiles.subject(file)
        XCTAssertEqual(pair.evidence.steps?.count, Self.tokens.count)
        let reference = try MiMoQualificationEvidence.reference(try referenceData(), comparableWith: pair.identity).subject
        XCTAssertEqual(try QualificationComparator().compare(reference: reference, candidate: pair).verdict, .exact)
    }
}
