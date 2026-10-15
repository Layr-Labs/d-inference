import Foundation

@main enum LookaheadControls {
    static func require(_ condition: Bool) throws {
        if !condition { throw ProbeError("Lookahead control failed") }
    }
    static func refuse(_ body: () throws -> Void) throws {
        do { try body() } catch is ProbeError { return }
        throw ProbeError("Invalid lookahead transition was accepted")
    }
    static func main() throws {
        var groups = 0
        for (prompt, chunk) in [(128,128), (128,64), (256,64), (8192,128)] {
            var w = try QwenGenerationPrefillWindow(promptCount: prompt, chunkSize: chunk)
            var native = 0
            for sequence in 0..<w.frameCount {
                if w.prepared == nil {
                    try w.beginPreparation(sequence: sequence, nativeCommittedTokens: native)
                    native = min(prompt, (sequence + 1) * chunk)
                    try w.commitPreparation(sequence: sequence, nativeCommittedTokens: native)
                }
                let commit = try w.beginSend(sequence: sequence, nativeCommittedTokens: native)
                try w.completeSend(commit)
                if sequence + 1 < w.frameCount {
                    try w.beginPreparation(sequence: sequence + 1, nativeCommittedTokens: native)
                    native = min(prompt, (sequence + 2) * chunk)
                    try w.commitPreparation(sequence: sequence + 1, nativeCommittedTokens: native)
                }
                // The ack uses the old commit despite the actual native frontier advancing.
                try w.consume(commit)
            }
            try require(w.complete && native == prompt && w.preparedAheadFrames == w.frameCount - 1
                        && w.maximumPreparedBoundaries == 1)
            groups += 1
        }
        try refuse { var w = try QwenGenerationPrefillWindow(promptCount: 128, chunkSize: 64)
            try w.beginPreparation(sequence: 1, nativeCommittedTokens: 0) }; groups += 1
        try refuse { var w = try QwenGenerationPrefillWindow(promptCount: 128, chunkSize: 64)
            try w.beginPreparation(sequence: 0, nativeCommittedTokens: 0)
            try w.commitPreparation(sequence: 0, nativeCommittedTokens: 64)
            _ = try w.beginSend(sequence: 0, nativeCommittedTokens: 64)
            try w.beginPreparation(sequence: 1, nativeCommittedTokens: 64) }; groups += 1
        try refuse { var w = try QwenGenerationPrefillWindow(promptCount: 128, chunkSize: 64)
            try w.beginPreparation(sequence: 0, nativeCommittedTokens: 0)
            try w.commitPreparation(sequence: 0, nativeCommittedTokens: 65) }; groups += 1
        try refuse { var w = try QwenGenerationPrefillWindow(promptCount: 128, chunkSize: 64)
            try w.beginPreparation(sequence: 0, nativeCommittedTokens: 0)
            try w.commitPreparation(sequence: 0, nativeCommittedTokens: 64)
            let c = try w.beginSend(sequence: 0, nativeCommittedTokens: 64); try w.completeSend(c)
            try w.beginPreparation(sequence: 1, nativeCommittedTokens: 64)
            try w.commitPreparation(sequence: 1, nativeCommittedTokens: 128)
            _ = try w.beginSend(sequence: 1, nativeCommittedTokens: 128) }; groups += 1
        try refuse { var w = try QwenGenerationPrefillWindow(promptCount: 128, chunkSize: 64)
            try w.beginPreparation(sequence: 0, nativeCommittedTokens: 0)
            try w.commitPreparation(sequence: 0, nativeCommittedTokens: 64)
            let c = try w.beginSend(sequence: 0, nativeCommittedTokens: 64); try w.completeSend(c)
            try w.consume(.init(sequence: 0, committedTokens: 128)) }; groups += 1
        try refuse { var w = try QwenGenerationPrefillWindow(promptCount: 128, chunkSize: 128)
            try w.beginPreparation(sequence: 0, nativeCommittedTokens: 0)
            try w.commitPreparation(sequence: 0, nativeCommittedTokens: 128)
            let c = try w.beginSend(sequence: 0, nativeCommittedTokens: 128)
            try w.completeSend(c); try w.consume(c); try w.consume(c) }; groups += 1
        try refuse { var w = try QwenGenerationPrefillWindow(promptCount: 128, chunkSize: 64)
            w.cancel(); try w.beginPreparation(sequence: 0, nativeCommittedTokens: 0) }; groups += 1
        for chunk in [64,128] {
            let producer = try QwenGenerationPrefillAllowance.derive(rank: 0, promptCount: 256,
                chunkSize: chunk, hiddenSize: 2816, elementBytes: 4, bound: { $0 })
            let receiver = try QwenGenerationPrefillAllowance.derive(rank: 1, promptCount: 256,
                chunkSize: chunk, hiddenSize: 2816, elementBytes: 4, bound: { $0 })
            try require(producer.extraNativeBytes == chunk * 2816 * 4
                && producer.extraHostBytes == chunk * 2816 * 4 + 65_536
                && receiver.extraNativeBytes == 0 && receiver.extraHostBytes == 65_536)
        }; groups += 1
        let single = try QwenGenerationPrefillAllowance.derive(rank: 0, promptCount: 128,
            chunkSize: 128, hiddenSize: 2816, elementBytes: 4, bound: { $0 })
        try require(single.extraNativeBytes == 0 && single.extraHostBytes == 65_536); groups += 1
        try refuse { _ = try QwenGenerationPrefillAllowance.derive(rank: 0, promptCount: 256,
            chunkSize: 128, hiddenSize: 2816, elementBytes: 4, bound: { $0 - 1 }) }; groups += 1
        print("Gemma lookahead shared-guard controls: \(groups) groups passed; metadata only")
    }
}
