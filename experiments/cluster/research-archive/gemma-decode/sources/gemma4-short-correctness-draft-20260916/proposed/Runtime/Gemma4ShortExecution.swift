import Foundation
import MLX

enum Gemma4ShortDriver {
    static func execute(_ input: Gemma4ShortCheckInput, session: Gemma4OwnedForwardSession,
                        sidecars: Gemma4ShortSidecars, wire: Gemma4ShortWire?,
                        check: () throws -> Void) throws -> Data {
        try check()
        guard (input.job.rank != nil) == (wire != nil) else { throw ProbeError("Gemma driver transport responsibility differs") }
        let binding = try session.shortDiagnosticBinding()
        try wire?.checkpoint("ready", check: check)
        var selected: [Int] = [], rows: [Gemma4ShortRow] = [], frames: [Gemma4ShortFrame] = []
        for sequence in 0..<3 {
            try autoreleasepool {
                try check()
                let frame = try Gemma4ShortFrames.frame(sequence)
                let tokens: [Int]
                if frame.phase == .prefill { tokens = Array(input.request.promptTokenIDs[frame.tokenOffset..<(frame.tokenOffset+frame.tokenCount)]) }
                else {
                    guard selected.count == 1 else { throw ProbeError("Gemma decode lacks its accepted first token") }
                    tokens = [selected[0]]
                }
                let incoming = input.job.rank == 1 ? try wire!.receiveFrame(frame, tokens: tokens, check: check) : nil
                let output: Gemma4ForwardOutput
                if frame.phase == .prefill {
                    output = try session.prefillChunk(tokens, offset: frame.tokenOffset,
                        final: frame.finalPromptChunk, incoming: incoming, check: check)
                } else { output = try session.decode(tokens[0], offset: frame.tokenOffset, incoming: incoming, check: check) }
                guard session.committedTokens == frame.tokenOffset+frame.tokenCount else {
                    throw ProbeError("Gemma actual state did not commit the exact frame")
                }
                var hash = incoming?.payloadSHA256
                var row: Gemma4ShortRow?
                switch output {
                case .residual(let boundary):
                    guard input.job.rank == 0, let wire else { throw ProbeError("Gemma residual has no actual ingress peer") }
                    try wire.sendFrame(boundary, check: check); hash = boundary.payloadSHA256
                case .evaluationHandle:
                    guard sequence == 0, input.job.rank != 0 else { throw ProbeError("Gemma nonfinal evaluation appears at a token boundary") }
                    try wire?.consume(sequence: sequence, frontier: session.committedTokens, check: check)
                case .logits(let logits):
                    guard sequence > 0, input.job.rank != 0 else { throw ProbeError("Gemma logits appear at a nonfinal boundary") }
                    try wire?.consume(sequence: sequence, frontier: session.committedTokens, check: check)
                    row = try Gemma4ShortCapture.row(logits, ordinal: sequence-1, sidecars: sidecars, check: check)
                }
                frames.append(.init(sequence: sequence, frontier: session.committedTokens,
                    tokenIDsSHA256: qwenGenerationTokenHash(tokens), boundarySHA256: hash))
                if sequence > 0 {
                    let token: Int
                    if let wire { token = try wire.acceptToken(row?.tokenID, ordinal: sequence-1, check: check) }
                    else { guard let row else { throw ProbeError("Gemma full reference did not produce its row") }; token = row.tokenID }
                    if let row { guard row.tokenID == token else { throw ProbeError("Gemma accepted token differs from actual logits") }; rows.append(row) }
                    selected.append(token)
                }
                try check()
            }
        }
        guard selected.count == 2, session.committedTokens == 33, rows.count == (input.job.rank == 0 ? 0 : 2) else {
            throw ProbeError("Gemma short request lacks complete selected-token/row evidence")
        }
        let final = try autoreleasepool { try Gemma4ShortCapture.state(session, sidecars: sidecars, check: check) }
        try session.finish(.length, selectedTokenCount: 2, lastTokenID: selected[1])
        guard session.isClosed, !session.isFailed else { throw ProbeError("Gemma request did not retire cleanly") }
        try wire?.checkpoint("request-retired", tokenIDs: selected, check: check)
        let result = Gemma4ShortExecution(binding: binding, sourceLoad: session.shortLoadReceipt,
            selectedTokenIDs: selected, selectedTokenIDsSHA256: qwenGenerationTokenHash(selected), frames: frames,
            rows: rows, finalState: final, files: sidecars.files)
        return try canonicalJSONData(result)
    }
}
