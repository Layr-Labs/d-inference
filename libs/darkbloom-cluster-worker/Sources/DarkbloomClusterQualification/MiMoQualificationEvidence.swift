import Foundation

/// MiMo V2.6's qualification evidence, read into the comparator's terms.
///
/// MiMo has no recording runtime (`--evidence final-row`). Its single-Mac
/// reference is `darkbloom-cluster-stage-check mimo-reference`
/// (`mimo_staged_reference_v2`: every selected row's digest over its native
/// bytes and its four highest candidates), and a pair run with
/// `--mimo-step-evidence on` carries the same per-row evidence in the
/// decoding rank's `darkbloom-mimo-step-v1` runtime lines. So a MiMo pair is
/// compared like every other family: tokens first; at a different token the
/// near-tie rule on the reference's own candidates at that row; with equal
/// tokens `exact` when every row digest is equal, else `tokensEqualLogitsDiffer`
/// (`QualificationComparator.stepRowsEqual`).
public enum MiMoQualificationEvidence {
    public static let referenceSchema = "mimo_staged_reference_v2"
    public static let stepLinePrefix = "darkbloom-mimo-step-v1 "
    /// What a record lists among its allowances when the reference names its
    /// request by ID only (reports written before 2026-10-14): the request
    /// fields the reference file does not carry (prompt digest, chunk,
    /// outputs, stops) are the pair's, bound by the request ID both runs were
    /// given. A reference that names them (`request`) is compared on them
    /// like every other family's and lists no such allowance.
    public static let requestByIDAllowance = "request-by-id"

    struct ReferenceFile: Decodable {
        struct Step: Decodable {
            struct Candidate: Decodable { let tokenID: Int; let logit: Float; let logitBits: String }
            let ordinal: Int, boundarySHA256: String, rowSHA256: String, rowDType: String
            let top: [Candidate]
        }
        let schema: String, runtimeModelID: String, stageCut: Int, requestID: String, promptTokens: Int
        let selectedTokenIDs: [Int], finishReason: String, steps: [Step]
        let verifiedAggregateSHA256: String, planSHA256: String, storageCommitmentSHA256: String
        /// The Mac that ran it; written by builds after 2026-10-13, absent before.
        let host: QualificationHost?
        /// The request it ran, in the fields a pair's identity compares;
        /// written by builds after 2026-10-14, absent before.
        let request: RequestBinding?
    }

    struct RequestBinding: Decodable {
        let promptTokenIDsSHA256: String, chunkSize: Int, outputCount: Int, stopTokenIDs: [Int]
    }

    public static func isReference(_ data: Data) -> Bool {
        struct Header: Decodable { let schema: String }
        return (try? JSONDecoder().decode(Header.self, from: data))?.schema == referenceSchema
    }

    /// A MiMo reference as a subject the comparator can hold against `pair`.
    /// Compared from the file itself: model, request ID, prompt length, cut,
    /// artifact (the verified aggregate digest), plan, and, when the file
    /// names its request, the prompt digest, chunk, outputs and stops
    /// (`requestBound`). Without that block those fields are taken from
    /// `pair` (`requestByIDAllowance`).
    /// Refused: another model, an evidence row missing or out of order, a row
    /// whose candidates are not two or more in descending order, or a step
    /// whose selected token is not its top candidate (a greedy reference).
    public static func reference(_ data: Data, comparableWith pair: QualificationIdentity) throws
        -> (subject: QualificationSubject, chip: String?, requestBound: Bool) {
        let file = try JSONDecoder().decode(ReferenceFile.self, from: data)
        guard file.schema == referenceSchema else { throw QualificationError("Not a MiMo staged reference") }
        guard !file.selectedTokenIDs.isEmpty, file.steps.map(\.ordinal) == Array(0..<file.selectedTokenIDs.count) else {
            throw QualificationError("The MiMo reference does not carry one evidence row per selected token")
        }
        let steps = try file.steps.map { step -> QualificationStep in
            let ids = step.top.map(\.tokenID), logits = step.top.map(\.logit)
            guard ids.count >= 2, zip(logits, logits.dropFirst()).allSatisfy({ $0 >= $1 }),
                  logits.allSatisfy(\.isFinite), file.selectedTokenIDs[step.ordinal] == ids[0],
                  QualificationComparator.unitInLastPlace(of: 1, dtype: step.rowDType) != nil else {
                throw QualificationError("MiMo reference row \(step.ordinal) is not a greedy row with ordered candidates")
            }
            return .init(ordinal: step.ordinal, frameSequence: step.ordinal, committedTokens: file.promptTokens + step.ordinal,
                         tokenID: ids[0], topTokenIDs: ids, topLogits: logits,
                         maximumTieCount: logits.filter { $0 == logits[0] }.count, rowSHA256: step.rowSHA256,
                         rowDType: step.rowDType)
        }
        var identity = pair
        identity.modelID = file.runtimeModelID; identity.requestID = file.requestID
        identity.promptTokenCount = file.promptTokens; identity.stageCut = file.stageCut
        identity.artifactSHA256 = file.verifiedAggregateSHA256; identity.planSHA256 = file.planSHA256
        identity.storageCommitmentSHA256 = file.storageCommitmentSHA256
        if let request = file.request {
            guard QualificationHash.isSHA256(request.promptTokenIDsSHA256), request.chunkSize > 0, request.outputCount > 0,
                  request.stopTokenIDs == Array(Set(request.stopTokenIDs)).sorted() else {
                throw QualificationError("The MiMo reference names a malformed request")
            }
            identity.promptTokenIDsSHA256 = request.promptTokenIDsSHA256; identity.chunkSize = request.chunkSize
            identity.outputCount = request.outputCount; identity.stopTokenIDs = request.stopTokenIDs
        }
        identity.stageSHA256 = nil; identity.requestFingerprint = nil; identity.profileFingerprint = nil
        identity.arithmeticSHA256 = nil; identity.generationMode = nil
        let chip = file.host?.chip
        return (.init(label: "MiMo single-host reference (\(chip ?? "chip not recorded"))", identity: identity,
                      evidence: .init(selectedTokenIDs: file.selectedTokenIDs, finishReason: file.finishReason, steps: steps)), chip,
                file.request != nil)
    }

    /// The decoding rank's step lines of a MiMo pair report as steps, one per
    /// selected token in order; nil when the report has no step lines. Thrown
    /// when it has some but not one per selected token (a truncated tail).
    public static func pairSteps(_ report: PairReport) throws -> [QualificationStep]? {
        guard let evidence = report.evidence, let last = report.ranks.map(\.rank).max(),
              let lines = report.ranks.first(where: { $0.rank == last })?.runtimeLines else { return nil }
        let stepLines = lines.filter { $0.hasPrefix(stepLinePrefix) }
        guard !stepLines.isEmpty else { return nil }
        let steps = try stepLines.map { try step($0, rank: last) }.sorted { $0.ordinal < $1.ordinal }
        let tokens = evidence.selectedTokenIDs
        guard steps.map(\.ordinal) == Array(0..<tokens.count), zip(steps, tokens).allSatisfy({ $0.tokenID == $1 }) else {
            throw QualificationError("The pair report's MiMo step lines do not cover every selected token once, in order "
                + "(\(steps.count) lines for \(tokens.count) tokens)")
        }
        return steps
    }

    /// `darkbloom-mimo-step-v1 rank=R i=N boundary=HEX row=HEX dtype=D top=ID_BITS_ID_BITS...`
    static func step(_ line: String, rank: Int) throws -> QualificationStep {
        var fields: [String: String] = [:]
        for word in line.dropFirst(stepLinePrefix.count).split(separator: " ") {
            guard let equals = word.firstIndex(of: "=") else { continue }
            fields[String(word[..<equals])] = String(word[word.index(after: equals)...])
        }
        let parts = (fields["top"] ?? "").split(separator: "_").map(String.init)
        guard fields["rank"] == String(rank), let ordinal = fields["i"].flatMap(Int.init), ordinal >= 0,
              let row = fields["row"], row.count >= 16, row.allSatisfy(\.isHexDigit), let dtype = fields["dtype"],
              QualificationComparator.unitInLastPlace(of: 1, dtype: dtype) != nil,
              parts.count >= 4, parts.count % 2 == 0 else {
            throw QualificationError("Malformed MiMo step line: \(line.prefix(120))")
        }
        var ids: [Int] = [], logits: [Float] = []
        for index in stride(from: 0, to: parts.count, by: 2) {
            guard let id = Int(parts[index]), parts[index + 1].count == 8, let bits = UInt32(parts[index + 1], radix: 16) else {
                throw QualificationError("Malformed MiMo step candidate in: \(line.prefix(120))")
            }
            ids.append(id); logits.append(Float(bitPattern: bits))
        }
        guard logits.allSatisfy(\.isFinite), zip(logits, logits.dropFirst()).allSatisfy({ $0 >= $1 }) else {
            throw QualificationError("MiMo step line \(ordinal) has candidates out of order")
        }
        return .init(ordinal: ordinal, frameSequence: ordinal, committedTokens: ordinal, tokenID: ids[0], topTokenIDs: ids,
                     topLogits: logits, maximumTieCount: logits.filter { $0 == logits[0] }.count, rowSHA256: row, rowDType: dtype)
    }
}
