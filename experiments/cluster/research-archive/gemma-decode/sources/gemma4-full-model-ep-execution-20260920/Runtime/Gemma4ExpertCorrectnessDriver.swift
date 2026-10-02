import Foundation
import MLX

enum Gemma4ExpertCorrectnessDriver {
    static func run(_ input: Gemma4ExpertCorrectnessInput, session: Gemma4OwnedForwardSession,
                    sidecars: Gemma4ShortSidecars, wire: Gemma4ExpertWire?,
                    check: () throws -> Void) throws -> Data {
        try check()
        guard (input.job.rank != nil) == (wire != nil) else { throw ProbeError("Gemma EP driver rank responsibility differs") }
        let binding = try session.shortDiagnosticBinding()
        guard binding.layers.count == 30, binding.layers.map(\.globalIndex) == Array(0..<30) else {
            throw ProbeError("Gemma EP correctness requires each complete original decoder state")
        }
        try wire?.checkpoint("ready", check: check)
        var selected: [Int] = [], rows: [Gemma4ShortRow] = [], frames: [Gemma4ShortFrame] = []
        for sequence in 0..<3 {
            try autoreleasepool {
                try check()
                let frame = try input.request.frame(sequence: sequence)
                let tokens: [Int]
                if frame.phase == .prefill {
                    tokens = Array(input.request.promptTokenIDs[frame.tokenOffset..<(frame.tokenOffset+frame.tokenCount)])
                } else {
                    guard selected.count == 1 else { throw ProbeError("Gemma EP decode lacks agreed first token") }
                    tokens = [selected[0]]
                }
                let output: Gemma4ForwardOutput
                if frame.phase == .prefill {
                    output = try session.prefillChunk(tokens, offset: frame.tokenOffset,
                        final: frame.finalPromptChunk, check: check)
                } else { output = try session.decode(tokens[0], offset: frame.tokenOffset, check: check) }
                guard session.committedTokens == frame.tokenOffset + frame.tokenCount else {
                    throw ProbeError("Gemma EP owner did not commit the exact original frame")
                }
                let row: Gemma4ShortRow?
                switch output {
                case .evaluationHandle:
                    guard sequence == 0 else { throw ProbeError("Gemma EP token frame returned an evaluation handle") }
                    row = nil
                case .logits(let logits):
                    guard sequence > 0 else { throw ProbeError("Gemma EP nonfinal frame produced logits") }
                    row = try Gemma4ShortCapture.row(logits, ordinal: sequence-1, sidecars: sidecars, check: check)
                case .residual: throw ProbeError("Gemma EP must not run the layer-pipeline residual route")
                }
                try wire?.frameCommitted(frame, tokens: tokens, row: row, check: check)
                frames.append(.init(sequence: sequence, frontier: session.committedTokens,
                    tokenIDsSHA256: qwenGenerationTokenHash(tokens), boundarySHA256: nil))
                if let row { rows.append(row); selected.append(row.tokenID) }
                try check()
            }
        }
        guard selected.count == 2, rows.count == 2, session.committedTokens == 33 else {
            throw ProbeError("Gemma EP lacks both actual full token rows")
        }
        let snapshot = try autoreleasepool { try Gemma4ShortCapture.state(session, sidecars: sidecars, check: check) }
        guard snapshot.entries.count == 90,
              Set(snapshot.entries.map { "\($0.globalLayerIndex):\($0.component)" })
                == Set((0..<30).flatMap { layer in ["kv.keys","kv.values","kv.position_offsets"].map { "\(layer):\($0)" } }) else {
            throw ProbeError("Gemma EP did not capture each complete original decoder state")
        }
        try session.finish(.length, selectedTokenCount: 2, lastTokenID: selected[1])
        guard session.isClosed, !session.isFailed else { throw ProbeError("Gemma EP request did not retire cleanly") }
        try wire?.checkpoint("request-retired", selected: selected, check: check)
        return try canonicalJSONData(Gemma4ShortExecution(binding: binding, sourceLoad: session.shortLoadReceipt,
            selectedTokenIDs: selected, selectedTokenIDsSHA256: qwenGenerationTokenHash(selected),
            frames: frames, rows: rows, finalState: snapshot, files: sidecars.files))
    }
}
