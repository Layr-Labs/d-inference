import Foundation
import MLX

struct Gemma4BenchmarkPhase: Encodable {
    let name: String, timestampNanoseconds: UInt64
    let tokenCount: Int, committedTokens: Int
}
struct Gemma4BenchmarkFrameTiming: Encodable {
    let sequence: Int, phase: String, offset: Int, tokenCount: Int
    let startedNanoseconds: UInt64, completedNanoseconds: UInt64
    let ownerPhases: [Gemma4BenchmarkPhase]
}
struct Gemma4BenchmarkSample: Encodable {
    let ordinal: Int, warmup: Bool, requestID: String, requestSHA256: String
    let binding: Gemma4ShortSessionBinding
    let selectedTokenIDs: [Int], selectedTokenIDsSHA256: String
    let startedNanoseconds: UInt64, firstLogitsNanoseconds: UInt64?, tokenAgreementNanoseconds: [UInt64]
    let completedNanoseconds: UInt64, prefillNanoseconds: UInt64, decodeNanoseconds: UInt64
    let prefillTokensPerSecond: Double, decodeTokensPerSecond: Double
    let frames: [Gemma4BenchmarkFrameTiming]
    let finalRow: Gemma4ShortFile?, finalState: Gemma4ShortState?
    let committedTokens: Int
    let prefillSummary: QwenGenerationPrefillSummary?
    let guardMetrics: Gemma4BenchmarkGuardMetrics.Sample
    let requestStateRetired = true, evidenceOutsideTimedPath = true
    let timingsAreSameProcess = true, clockAcrossHostsCompared = false
    let durationIncludesResourceChecksAndSerialTransport: Bool
    let mtpEnabled = false, numericalComparisonPerformed = false
}

enum Gemma4BenchmarkDriver {
    static func execute(_ input: Gemma4BenchmarkRequestInput, session: Gemma4OwnedForwardSession,
        sidecars: Gemma4BenchmarkSidecars, wire: Gemma4BenchmarkWire?,
        guardMetrics: Gemma4BenchmarkGuardMetrics, check: () throws -> Void
    ) throws -> Gemma4BenchmarkSample {
        try check()
        guard (input.job.rank != nil) == (wire != nil) else { throw ProbeError("Gemma benchmark peer responsibility differs") }
        let binding = try session.shortDiagnosticBinding()
        try wire?.checkpoint("ready", check: check)
        let producer = input.job.prefill == .oneChunkLookahead && input.job.rank == 0
            ? try Gemma4BenchmarkLookahead(request: input.request) : nil
        defer { producer?.cancel() }
        var selected: [Int] = [], agreements: [UInt64] = [], frames: [Gemma4BenchmarkFrameTiming] = []
        var firstLogits: UInt64?, retainedFinalRow: MLXArray?
        let frameCount = (input.request.promptCount + input.request.chunkSize - 1) / input.request.chunkSize
            + input.request.outputCount - 1
        let guardStart = guardMetrics.snapshot()
        var guardFirst: Gemma4BenchmarkGuardMetrics.Snapshot?, guardLast: Gemma4BenchmarkGuardMetrics.Snapshot?
        let start = DispatchTime.now().uptimeNanoseconds
        for sequence in 0..<frameCount {
            try autoreleasepool {
                try check()
                let frame = try Gemma4BenchmarkFrames.frame(sequence, request: input.request)
                var frameStart = DispatchTime.now().uptimeNanoseconds
                let tokens: [Int]
                if frame.phase == .prefill {
                    tokens = Array(input.request.promptTokenIDs[frame.tokenOffset..<(frame.tokenOffset+frame.tokenCount)])
                } else {
                    guard let last = selected.last else { throw ProbeError("Gemma decode lacks accepted predecessor") }
                    tokens = [last]
                }
                var phases: [Gemma4BenchmarkPhase] = []
                var localToken: Int?
                if let producer, frame.phase == .prefill {
                    guard let wire else { throw ProbeError("Gemma lookahead lacks the original wire") }
                    let observation = try producer.run(frame: frame, session: session, wire: wire, check: check)
                    guard observation.committedTokens == frame.tokenOffset + frame.tokenCount else {
                        throw ProbeError("Gemma lookahead ACK changed its captured frontier")
                    }
                    frameStart = observation.startedNanoseconds; phases = observation.phases
                } else {
                    guard producer == nil || producer!.isComplete else { throw ProbeError("Gemma decode precedes prompt drain") }
                    let incoming = input.job.rank == 1 ? try wire!.receiveFrame(frame, tokens: tokens, check: check) : nil
                    let step = try Gemma4BenchmarkForward.run(frame: frame, tokens: tokens, session: session,
                                                              incoming: incoming, check: check)
                    phases = step.phases
                    let output = step.output
                    switch output {
                    case .residual(let boundary):
                        guard input.job.rank == 0, let wire else { throw ProbeError("Gemma residual lacks peer") }
                        try wire.sendFrame(boundary, check: check)
                    case .evaluationHandle:
                        guard frame.phase == .prefill, !frame.finalPromptChunk, input.job.rank != 0 else {
                            throw ProbeError("Gemma evaluation handle appeared at a selected-token boundary")
                        }
                        try wire?.consume(sequence: sequence, frontier: session.committedTokens, check: check)
                    case .logits(let logits):
                        guard input.job.rank != 0, frame.phase == .decode || frame.finalPromptChunk else {
                            throw ProbeError("Gemma logits appeared before final prefill")
                        }
                        if firstLogits == nil { firstLogits = DispatchTime.now().uptimeNanoseconds }
                        try wire?.consume(sequence: sequence, frontier: session.committedTokens, check: check)
                        guard logits.shape == [1,262_144] else { throw ProbeError("Gemma sampling row shape differs") }
                        let maximum = argMax(logits), finite = all(isFinite(logits))
                        eval(maximum, finite); try check()
                        guard maximum.dtype == .uint32, maximum.size == 1, finite.item(Bool.self) else {
                            throw ProbeError("Gemma sampling did not produce a finite native argmax")
                        }
                        localToken = Int(maximum.item(UInt32.self))
                        if sequence == frameCount-1 && input.job.captureEvidence { retainedFinalRow = logits }
                    }
                }
                if frame.phase == .decode || frame.finalPromptChunk {
                    let token: Int
                    if let wire { token = try wire.acceptToken(localToken, ordinal: selected.count, check: check) }
                    else { guard let localToken else { throw ProbeError("Gemma full forward lost logits") }; token = localToken }
                    selected.append(token); agreements.append(DispatchTime.now().uptimeNanoseconds)
                    if selected.count == 1 { guardFirst = guardMetrics.snapshot() }
                    if selected.count == input.request.outputCount { guardLast = guardMetrics.snapshot() }
                }
                let end = DispatchTime.now().uptimeNanoseconds
                frames.append(.init(sequence: sequence, phase: frame.phase.rawValue, offset: frame.tokenOffset,
                    tokenCount: frame.tokenCount, startedNanoseconds: frameStart, completedNanoseconds: end, ownerPhases: phases))
                try check()
            }
        }
        let end = DispatchTime.now().uptimeNanoseconds
        guard selected.count == input.request.outputCount, agreements.count == selected.count,
              let first = agreements.first, let last = agreements.last, first > start, last > first,
              session.committedTokens == input.request.promptCount + input.request.outputCount-1,
              let guardFirst, let guardLast else {
            throw ProbeError("Gemma benchmark timing/token/frontier completion differs")
        }
        guard producer == nil || producer!.isComplete else { throw ProbeError("Gemma lookahead did not drain before retirement") }
        let prefillSummary: QwenGenerationPrefillSummary?
        if let rank = input.job.rank, input.job.prefillPolicy != nil {
            prefillSummary = producer?.summary ?? .init(policy: input.job.prefill.rawValue, rank: rank,
                preparedAheadFrames: 0, maximumPreparedBoundaries: 0)
        } else { prefillSummary = nil }
        // The timed interval has ended. No serialization or full-row/state copy occurs above.
        var finalRow: Gemma4ShortFile?, finalState: Gemma4ShortState?
        if input.job.captureEvidence {
            if input.job.rank != 0 {
                guard let row = retainedFinalRow else { throw ProbeError("Gemma evidence lost its final row") }
                let record = try QwenRecordedLogits(row, vocabularySize: 262_144, check: check)
                guard let maximum = record.record.values.max(),
                      record.record.values.firstIndex(of: maximum) == selected.last else {
                    throw ProbeError("Gemma final row does not reproduce the last native argmax")
                }
                finalRow = try sidecars.write("request-\(input.ordinal)-final-row.json", data: canonicalJSONData(record), check: check)
            }
            finalState = try captureState(session, ordinal: input.ordinal, sidecars: sidecars, check: check)
        }
        retainedFinalRow = nil
        try session.finish(.length, selectedTokenCount: selected.count, lastTokenID: selected.last!)
        guard session.isClosed, !session.isFailed else { throw ProbeError("Gemma benchmark state retirement failed") }
        try wire?.checkpoint("request-retired", tokenIDs: selected, check: check)
        return .init(ordinal: input.ordinal, warmup: input.ordinal == 0, requestID: input.request.requestID.uuidString.lowercased(),
            requestSHA256: input.request.fingerprint, binding: binding, selectedTokenIDs: selected,
            selectedTokenIDsSHA256: qwenGenerationTokenHash(selected), startedNanoseconds: start,
            firstLogitsNanoseconds: firstLogits, tokenAgreementNanoseconds: agreements, completedNanoseconds: end,
            prefillNanoseconds: first-start, decodeNanoseconds: last-first,
            prefillTokensPerSecond: Double(input.request.promptCount) * 1e9 / Double(first-start),
            decodeTokensPerSecond: Double(selected.count-1) * 1e9 / Double(last-first), frames: frames,
            finalRow: finalRow, finalState: finalState, committedTokens: session.committedTokens,
            prefillSummary: prefillSummary,
            guardMetrics: .init(prefill: Gemma4BenchmarkGuardMetrics.difference(guardFirst, guardStart),
                                decode: Gemma4BenchmarkGuardMetrics.difference(guardLast, guardFirst)),
            durationIncludesResourceChecksAndSerialTransport: input.job.prefill == .serial)
    }

    private static func captureState(_ session: Gemma4OwnedForwardSession, ordinal: Int,
        sidecars: Gemma4BenchmarkSidecars, check: () throws -> Void) throws -> Gemma4ShortState {
        let snapshot = try session.snapshot(includeBytes: true, check: check)
        guard snapshot.committedTokens == session.request.promptCount + session.request.outputCount-1 else {
            throw ProbeError("Gemma benchmark snapshot frontier differs")
        }
        var entries: [Gemma4ShortState.Entry] = []
        for value in snapshot.entries {
            guard let bytes = value.bytes, bytes.count == value.byteCount, sha256(bytes) == value.sha256 else {
                throw ProbeError("Gemma benchmark state evidence lacks actual bytes")
            }
            let file = try sidecars.write("request-\(ordinal)-state-\(value.globalLayerIndex)-\(value.component).bin", data: bytes, check: check)
            entries.append(.init(localLayerIndex: value.localLayerIndex, globalLayerIndex: value.globalLayerIndex,
                component: value.component, dtype: value.dtype, sha256: value.sha256, shape: value.shape,
                byteCount: value.byteCount, logicalRange: value.logicalRange.map { [$0.lowerBound,$0.upperBound] } ?? [], file: file))
        }
        return .init(frontier: snapshot.committedTokens, fingerprint: snapshot.fingerprint, entries: entries)
    }
}
