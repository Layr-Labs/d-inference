import Foundation
import MLX

struct Gemma4RemoteMTPRequestEvidence: Encodable {
    let finalRow: Gemma4ShortFile?, finalState: Gemma4ShortState?
    let capturedBeforeRequestRetirement = true, outsideGenerationTiming = true
    let numericalComparisonPerformed = false
    static func capture(row: MLXArray, session: Gemma4OwnedForwardSession, input: Gemma4BenchmarkRequestInput,
                        selected: [Int], enabled: Bool, sidecars: Gemma4BenchmarkSidecars,
                        check: () throws -> Void) throws -> Self {
        guard !session.isClosed, !session.isFailed, session.request == input.request,
              session.committedTokens == input.request.finalCommittedTokens,
              selected.count == input.request.outputCount else { throw ProbeError("Remote MTP evidence lost its original open request") }
        guard enabled else { return .init(finalRow:nil,finalState:nil) }
        let record = try QwenRecordedLogits(row,vocabularySize:262_144,check:check)
        guard let maximum = record.record.values.max(), record.record.values.firstIndex(of:maximum) == selected.last else {
            throw ProbeError("Remote MTP final row differs from its actual published target token")
        }
        let finalRow = try sidecars.write("request-\(input.ordinal)-final-row.json",data:canonicalJSONData(record),check:check)
        let snapshot = try session.snapshot(includeBytes:true,check:check)
        var entries: [Gemma4ShortState.Entry] = []
        for value in snapshot.entries {
            guard let bytes = value.bytes, bytes.count == value.byteCount, sha256(bytes) == value.sha256 else {
                throw ProbeError("Remote MTP state evidence omitted actual bytes")
            }
            let file = try sidecars.write("request-\(input.ordinal)-state-\(value.globalLayerIndex)-\(value.component).bin",data:bytes,check:check)
            entries.append(.init(localLayerIndex:value.localLayerIndex,globalLayerIndex:value.globalLayerIndex,
                component:value.component,dtype:value.dtype,sha256:value.sha256,shape:value.shape,byteCount:value.byteCount,
                logicalRange:value.logicalRange.map { [$0.lowerBound,$0.upperBound] } ?? [],file:file))
        }
        guard entries.count == 90, snapshot.committedTokens == input.request.finalCommittedTokens else {
            throw ProbeError("Remote MTP full state coverage/frontier differs")
        }
        return .init(finalRow:finalRow,finalState:.init(frontier:snapshot.committedTokens,fingerprint:snapshot.fingerprint,entries:entries))
    }
}

struct Gemma4RemoteMTPSample: Encodable {
    let ordinal: Int, warmup: Bool, requestID: String, requestSHA256: String, scopeSHA256: String
    let selectedTokenIDs: [Int], selectedTokenIDsSHA256: String, committedTokens: Int
    let binding: Gemma4ShortSessionBinding
    let prefillNanoseconds: UInt64, decodeNanoseconds: UInt64
    let prefillTPS: Double, decodeTPS: Double
    let generatedProposals: Int, offeredProposals: Int, acceptedProposals: Int, branchRestarts: Int
    let reusedProposalsOffered: Int, verificationWidths: [Int], acceptedPrefixes: [Int]
    let evidence: Gemma4RemoteMTPRequestEvidence
    let mtpEnabled = true, remoteAssistant = true, maximumDraftTokens = 2, maximumBufferedProposals = 5
    let timingsAreSameProcess = true, rejectedWorkIncluded = true, requestStateRetired = true
    let targetBatchNumericsQualified = false, physicalOwnerRetirementEstablished = false
}
