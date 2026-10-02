import Foundation
import MLX
import MLXLLM

struct Gemma4LocalMTPRequestEvidence: Encodable {
    let finalRow: Gemma4ShortFile?, finalState: Gemma4ShortState?
    let conditioning: Gemma4LocalMTPConditioningReceipt?
    let capturedBeforeRequestRetirement = true, outsideGenerationTiming = true
    let numericalComparisonPerformed = false
}

/// Retains only the LAST reconciled native window. There is no all-row recorder
/// or previous-window overlap; numerical comparison remains an external action.
final class Gemma4LocalMTPEvidence {
    private let input: Gemma4BenchmarkRequestInput
    private let captureEvidence: Bool, qualifyConditioning: Bool
    private var terminalWindow: Gemma4OwnedMTPWindow?
    private var terminalKeep: Int?
    private var consumed = false
    private(set) var result: Gemma4LocalMTPRequestEvidence?

    init(input: Gemma4BenchmarkRequestInput, captureEvidence: Bool, qualifyConditioning: Bool) {
        self.input = input; self.captureEvidence = captureEvidence; self.qualifyConditioning = qualifyConditioning
    }

    func observe(_ window: Gemma4OwnedMTPWindow, keeping: Int) throws {
        guard !consumed, (1...window.inputTokens.count).contains(keeping) else {
            throw ProbeError("Local MTP evidence received a replayed or invalid window")
        }
        if window.base + keeping == input.request.finalCommittedTokens && (captureEvidence || qualifyConditioning) {
            guard terminalWindow == nil else { throw ProbeError("Local MTP terminal window was repeated") }
            terminalWindow = window; terminalKeep = keeping
        }
    }

    func finish(session: Gemma4OwnedForwardSession, selected: [Int], assistant: Gemma4AssistantDraftModel,
        auxiliary: Gemma4MTPAuxiliaryOwner, sidecars: Gemma4BenchmarkSidecars, check: () throws -> Void
    ) throws {
        guard !consumed, !session.isClosed, !session.isFailed, session.request == input.request,
              selected.count == input.request.outputCount, session.committedTokens == input.request.finalCommittedTokens,
              let seed = selected.last else { throw ProbeError("Local MTP evidence lost its original open request") }
        consumed = true
        defer { terminalWindow = nil; terminalKeep = nil }
        try check()
        var rowFile: Gemma4ShortFile?, stateFile: Gemma4ShortState?
        var conditioning: Gemma4LocalMTPConditioningReceipt?
        if captureEvidence || qualifyConditioning {
            guard let window = terminalWindow, let keep = terminalKeep,
                  window.base + keep == session.committedTokens else {
                throw ProbeError("Local MTP evidence omitted the actual terminal window")
            }
            if qualifyConditioning {
                guard case .full(let full) = session.loaded.model else { throw ProbeError("Conditioning needs full target") }
                // This scope retires parity arrays/captures before the host state export.
                conditioning = try autoreleasepool {
                    let capture = try session.mtpConditioning(after: window, check: check)
                    return try Gemma4LocalMTPConditioningCheck.run(target: full.textModel, assistant: assistant,
                        capture: capture, seedToken: seed, auxiliary: auxiliary, check: check)
                }
                Stream.gpu.synchronize(); Stream.cpu.synchronize(); try check()
            }
            if captureEvidence {
                let row = window.logits[0..., (keep-1)..<keep, 0...].reshaped([1,262_144])
                let record = try QwenRecordedLogits(row, vocabularySize: 262_144, check: check)
                guard let maximum = record.record.values.max(), record.record.values.firstIndex(of: maximum) == seed else {
                    throw ProbeError("Local MTP final row differs from its published target token")
                }
                rowFile = try sidecars.write("request-\(input.ordinal)-final-row.json", data: canonicalJSONData(record), check: check)
                stateFile = try captureState(session, sidecars: sidecars, check: check)
            }
        }
        result = .init(finalRow: rowFile, finalState: stateFile, conditioning: conditioning)
        try check()
    }

    private func captureState(_ session: Gemma4OwnedForwardSession,
        sidecars: Gemma4BenchmarkSidecars, check: () throws -> Void
    ) throws -> Gemma4ShortState {
        let snapshot = try session.snapshot(includeBytes: true, check: check)
        guard snapshot.committedTokens == input.request.finalCommittedTokens else {
            throw ProbeError("Local MTP evidence snapshot frontier differs")
        }
        var entries: [Gemma4ShortState.Entry] = []
        for value in snapshot.entries {
            guard let bytes = value.bytes, bytes.count == value.byteCount, sha256(bytes) == value.sha256 else {
                throw ProbeError("Local MTP state lacks actual raw evidence")
            }
            let file = try sidecars.write("request-\(input.ordinal)-state-\(value.globalLayerIndex)-\(value.component).bin", data: bytes, check: check)
            entries.append(.init(localLayerIndex: value.localLayerIndex, globalLayerIndex: value.globalLayerIndex,
                component: value.component, dtype: value.dtype, sha256: value.sha256, shape: value.shape,
                byteCount: value.byteCount, logicalRange: value.logicalRange.map { [$0.lowerBound,$0.upperBound] } ?? [], file: file))
        }
        return .init(frontier: snapshot.committedTokens, fingerprint: snapshot.fingerprint, entries: entries)
    }
}
