import Foundation
import MLX
import MLXLLM

enum Gemma4TargetWidthIsolationMode: String, Codable, CaseIterable {
    case ordinary
    case verificationOne
    case verificationThreeKeepThree
    case verificationThreeKeepOne
}

struct Gemma4TargetWidthIsolationEvidence: Encodable {
    struct Row: Encodable {
        let outputOrdinal: Int
        let inputFrontier: Int
        let argmax: Int
        let file: Gemma4ShortFile
    }
    let ordinal: Int
    let mode: Gemma4TargetWidthIsolationMode
    let requestSHA256: String
    let forcedInputSequence: [Int]
    let actualTargetArgmax: [Int]
    let expectedGreedyIDs: [Int]
    let allArgmaxMatchReference: Bool
    let checkpointFrontier: Int
    let rows: [Row]
    let checkpointState: Gemma4ShortState
    let binding: Gemma4ShortSessionBinding
    let assistantForwardExecuted = false
    let teacherForcedInputs = true
    let numericalQualificationPassed = false
    let performanceMeasurement = false
}

/// A model-bearing diagnostic, invoked ONLY inside the existing admitted cohort.
/// The outer caller supplies a fresh original session and retains its existing
/// error/cancellation/weak-owner/retirement path. This creates no owner or grant.
///
/// Run one mode per fresh request, ordinal 0...3. Target tokens come from the
/// pinned same-build ordinary report, not an assistant or this arm's predictions.
/// All modes prime position 128 through ordinary decode, then compare the same
/// positions 129...131. The rest of the request uses ordinary forced decode.
/// Evidence is diagnostic-only; all numerical comparison is external and exact.
enum Gemma4TargetWidthIsolation {
    static func execute(input: Gemma4BenchmarkRequestInput,
        session: Gemma4OwnedForwardSession, mode: Gemma4TargetWidthIsolationMode,
        expectedGreedyIDs: [Int], sidecars: Gemma4BenchmarkSidecars,
        admitVerification: (CBv2AttentionVerificationPlan) throws -> Void,
        check: () throws -> Void
    ) throws -> Gemma4TargetWidthIsolationEvidence {
        guard input.job.rank == nil, input.request.promptCount == 128,
              input.request.chunkSize == 64, input.request.outputCount == 16,
              input.request.profile.vocabularySize == 262_144,
              input.request.finalCommittedTokens == 143,
              expectedGreedyIDs.count == 16,
              expectedGreedyIDs.allSatisfy({ (0..<262_144).contains($0) }),
              (0..<4).contains(input.ordinal), session.request == input.request,
              session.committedTokens == 0, !session.isClosed, !session.isFailed,
              case .full = session.loaded.model else {
            throw ProbeError("Target width isolation requires a fresh admitted P128/C64/O16 full session")
        }
        return try MLX.withError { native in
            func checked() throws { try native.check(); try check(); try native.check() }
            var rows: [Gemma4TargetWidthIsolationEvidence.Row] = []
            var actual: [Int] = []
            var checkpoint: Gemma4ShortState?
            let prefix = "request-\(input.ordinal)-width-\(mode.rawValue.lowercased())"

            // Six rows/request: prompt, prime, each of the first three compared
            // inputs, and final row. Each host record is written and released
            // before constructing the next; only small file records persist.
            func observe(_ logits: MLXArray, outputOrdinal: Int, frontier: Int) throws {
                try checked()
                guard logits.shape == [1,262_144], actual.count == outputOrdinal else {
                    throw ProbeError("Target width isolation row order/shape differs")
                }
                let capture = outputOrdinal <= 4 || outputOrdinal == 15
                let token: Int
                if capture {
                    token = try autoreleasepool {
                        let record = try QwenRecordedLogits(logits, vocabularySize: 262_144, check: checked)
                        guard let maximum = record.record.values.max(),
                              let index = record.record.values.firstIndex(of: maximum) else {
                            throw ProbeError("Target width isolation has no finite complete row")
                        }
                        let file = try sidecars.write("\(prefix)-row-\(outputOrdinal).json",
                            data: canonicalJSONData(record), check: checked)
                        rows.append(.init(outputOrdinal: outputOrdinal, inputFrontier: frontier,
                            argmax: index, file: file))
                        return index
                    }
                } else {
                    let selected = argMax(logits, axis: -1), finite = all(isFinite(logits))
                    eval(selected, finite); try checked()
                    guard finite.item(Bool.self), selected.dtype == .uint32, selected.size == 1 else {
                        throw ProbeError("Target width isolation has invalid uncaptured target logits")
                    }
                    token = Int(selected.item(UInt32.self))
                }
                actual.append(token); try checked()
            }

            func ordinaryInput(_ index: Int) throws {
                try autoreleasepool {
                    try checked()
                    let output = try session.decode(expectedGreedyIDs[index], offset: 128 + index, check: checked)
                    guard case .logits(let logits) = output else {
                        throw ProbeError("Target width isolation ordinary decode omitted logits")
                    }
                    try observe(logits, outputOrdinal: index + 1, frontier: 129 + index)
                }
            }

            func verifiedInput(_ index: Int, width: Int, keep: Int) throws {
                try autoreleasepool {
                    try checked()
                    let tokens = Array(expectedGreedyIDs[index..<(index + width)])
                    let window = try session.evaluateMTPInputs(tokens, offset: 128 + index,
                        admit: admitVerification, check: checked)
                    _ = try session.reconcileMTP(window, keeping: keep, check: checked)
                    // Only retained positions are compared. Rejected suffixes
                    // remain actually evaluated and reconciled by the same API.
                    for column in 0..<keep {
                        let row = window.logits[0..., column..<(column + 1), 0...].reshaped([1,262_144])
                        try observe(row, outputOrdinal: index + column + 1, frontier: 129 + index + column)
                    }
                    try checked()
                }
            }

            do {
                try checked()
                let binding = try session.shortDiagnosticBinding()
                for sequence in 0..<2 {
                    try autoreleasepool {
                        let frame = try Gemma4BenchmarkFrames.frame(sequence, request: input.request)
                        let tokens = Array(input.request.promptTokenIDs[frame.tokenOffset..<(frame.tokenOffset + frame.tokenCount)])
                        let output = try session.prefillChunk(tokens, offset: frame.tokenOffset,
                            final: frame.finalPromptChunk, check: checked)
                        switch output {
                        case .evaluationHandle:
                            guard !frame.finalPromptChunk else { throw ProbeError("Isolation prefill lost final logits") }
                        case .logits(let logits):
                            guard frame.finalPromptChunk else { throw ProbeError("Isolation prefill projected early") }
                            try observe(logits.reshaped([1,262_144]), outputOrdinal: 0, frontier: 128)
                        case .residual: throw ProbeError("Isolation full target returned residual")
                        }
                    }
                }
                // Original decode primes every arm identically; no MTP capture
                // or assistant binding/forward is required by this control.
                try ordinaryInput(0)
                switch mode {
                case .ordinary:
                    for index in 1...3 { try ordinaryInput(index) }
                case .verificationOne:
                    for index in 1...3 { try verifiedInput(index, width: 1, keep: 1) }
                case .verificationThreeKeepThree:
                    try verifiedInput(1, width: 3, keep: 3)
                case .verificationThreeKeepOne:
                    for index in 1...3 { try verifiedInput(index, width: 3, keep: 1) }
                }
                guard session.committedTokens == 132, actual.count == 5 else {
                    throw ProbeError("Target width isolation checkpoint chronology differs")
                }
                checkpoint = try autoreleasepool {
                    let snapshot = try session.snapshot(includeBytes: true, check: checked)
                    guard snapshot.committedTokens == 132, snapshot.entries.count == 90 else {
                        throw ProbeError("Target width isolation requires all30 actual KV states")
                    }
                    var entries: [Gemma4ShortState.Entry] = []
                    for value in snapshot.entries {
                        guard let bytes = value.bytes, bytes.count == value.byteCount,
                              sha256(bytes) == value.sha256 else {
                            throw ProbeError("Isolation checkpoint lacks actual state bytes")
                        }
                        let file = try sidecars.write("\(prefix)-state-\(value.globalLayerIndex)-\(value.component).bin",
                            data: bytes, check: checked)
                        entries.append(.init(localLayerIndex: value.localLayerIndex,
                            globalLayerIndex: value.globalLayerIndex, component: value.component,
                            dtype: value.dtype, sha256: value.sha256, shape: value.shape,
                            byteCount: value.byteCount,
                            logicalRange: value.logicalRange.map { [$0.lowerBound,$0.upperBound] } ?? [], file: file))
                    }
                    return .init(frontier: 132, fingerprint: snapshot.fingerprint, entries: entries)
                }
                // Complete the original owned schedule even if the captured
                // numeric rows differ; a mismatch is evidence, not a kill race.
                for index in 4..<15 { try ordinaryInput(index) }
                try checked()
                guard actual.count == 16, session.committedTokens == 143,
                      let checkpoint, rows.count == 6 else {
                    throw ProbeError("Target width isolation final counts differ")
                }
                let evidence = Gemma4TargetWidthIsolationEvidence(ordinal: input.ordinal, mode: mode,
                    requestSHA256: input.request.fingerprint, forcedInputSequence: Array(expectedGreedyIDs.prefix(15)),
                    actualTargetArgmax: actual, expectedGreedyIDs: expectedGreedyIDs,
                    allArgmaxMatchReference: actual == expectedGreedyIDs, checkpointFrontier: 132,
                    rows: rows, checkpointState: checkpoint, binding: binding)
                try session.finish(.length, selectedTokenCount: actual.count, lastTokenID: actual[15])
                try checked()
                return evidence
            } catch { try native.check(); throw error }
        }
    }
}
