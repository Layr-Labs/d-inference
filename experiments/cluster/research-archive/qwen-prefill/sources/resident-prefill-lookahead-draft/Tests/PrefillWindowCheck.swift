import Foundation

func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    guard value() else { throw ProbeError(message) }
}
func rejects(_ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw ProbeError("Expected refusal")
}

@main struct PrefillWindowCheck {
    static func main() throws {
        for prompt in [1, 511, 512, 513, 8192] {
            let serial = try simulate(prompt: prompt, ahead: false)
            let ahead = try simulate(prompt: prompt, ahead: true)
            try require(serial == ahead, "Lookahead changed consumed frontiers")
        }
        try slotAndCreditRefusals()
        try capturedFrontier()
        try failureAndFinalFrame()
        try capacities()
        try require(QwenResidentPrefillPolicy.serial.rawValue == "serial", "Serial policy changed")
        print("prefill-window: 6 CPU groups passed; no native/model execution")
    }
    static func simulate(prompt: Int, ahead: Bool) throws -> [Int] {
        var window = try QwenGenerationPrefillWindow(promptCount: prompt, chunkSize: 512)
        var local = 0, consumed = [Int]()
        func end(_ sequence: Int) -> Int { min(prompt, (sequence + 1) * 512) }
        for sequence in 0..<window.frameCount {
            if window.prepared == nil {
                try window.beginPreparation(sequence: sequence, nativeCommittedTokens: local)
                local = end(sequence)
                try window.commitPreparation(sequence: sequence, nativeCommittedTokens: local)
            }
            let ticket = try window.beginSend(sequence: sequence, nativeCommittedTokens: local)
            try window.completeSend(ticket)
            if ahead && sequence + 1 < window.frameCount {
                try window.beginPreparation(sequence: sequence + 1, nativeCommittedTokens: local)
                local = end(sequence + 1)
                try window.commitPreparation(sequence: sequence + 1, nativeCommittedTokens: local)
                try require(ticket.committedTokens == end(sequence), "Pending frame changed when native frontier advanced")
            }
            consumed.append(ticket.committedTokens)
            try window.consume(ticket)
        }
        try require(window.complete && local == prompt, "Prompt was not fully drained")
        try require(window.maximumPreparedBoundaries == 1, "Prepared slot exceeded one")
        try require(window.preparedAheadFrames == (ahead ? window.frameCount - 1 : 0), "Wrong preparation count")
        return consumed
    }
    static func sentWindow() throws -> (QwenGenerationPrefillWindow, QwenGenerationPrefillWindow.Commit) {
        var w = try QwenGenerationPrefillWindow(promptCount: 1025, chunkSize: 512)
        try w.beginPreparation(sequence: 0, nativeCommittedTokens: 0)
        try w.commitPreparation(sequence: 0, nativeCommittedTokens: 512)
        let t = try w.beginSend(sequence: 0, nativeCommittedTokens: 512)
        return (w, t)
    }
    static func slotAndCreditRefusals() throws {
        var (w, t) = try sentWindow()
        try rejects { try w.beginPreparation(sequence: 1, nativeCommittedTokens: 512) }
        try require(w.failed, "Unsent prefetch did not poison the window")
        (w, t) = try sentWindow(); try w.completeSend(t)
        try w.beginPreparation(sequence: 1, nativeCommittedTokens: 512)
        try w.commitPreparation(sequence: 1, nativeCommittedTokens: 1024)
        try rejects { _ = try w.beginSend(sequence: 1, nativeCommittedTokens: 1024) }
        (w, t) = try sentWindow(); try w.completeSend(t)
        try w.beginPreparation(sequence: 1, nativeCommittedTokens: 512)
        try w.commitPreparation(sequence: 1, nativeCommittedTokens: 1024)
        try rejects { try w.beginPreparation(sequence: 2, nativeCommittedTokens: 1024) }
        (w, t) = try sentWindow(); try w.completeSend(t)
        try rejects { try w.completeSend(t) }
        (w, t) = try sentWindow(); try w.completeSend(t); try w.consume(t)
        try rejects { try w.consume(t) }
    }
    static func capturedFrontier() throws {
        var (w, t) = try sentWindow(); try w.completeSend(t)
        try w.beginPreparation(sequence: 1, nativeCommittedTokens: 512)
        try w.commitPreparation(sequence: 1, nativeCommittedTokens: 1024)
        try rejects { try w.consume(.init(sequence: t.sequence, committedTokens: 1024)) }
        var wrong = try QwenGenerationPrefillWindow(promptCount: 1024, chunkSize: 512)
        try rejects { try wrong.beginPreparation(sequence: 0, nativeCommittedTokens: 1) }
        wrong = try .init(promptCount: 1024, chunkSize: 512)
        try wrong.beginPreparation(sequence: 0, nativeCommittedTokens: 0)
        try rejects { try wrong.commitPreparation(sequence: 0, nativeCommittedTokens: 511) }
    }
    static func failureAndFinalFrame() throws {
        var (w, t) = try sentWindow(); try w.completeSend(t)
        try w.beginPreparation(sequence: 1, nativeCommittedTokens: 512)
        // Native prefetch throw/outer cancellation destroys the entire window;
        // it cannot turn a partially advanced local state into a fresh request.
        w.cancel()
        try rejects { try w.commitPreparation(sequence: 1, nativeCommittedTokens: 1024) }
        try require(!w.complete && w.prepared == nil && w.pending == nil, "Cancellation retained a slot or claimed completion")
        var final = try QwenGenerationPrefillWindow(promptCount: 3, chunkSize: 512)
        try final.beginPreparation(sequence: 0, nativeCommittedTokens: 0)
        try final.commitPreparation(sequence: 0, nativeCommittedTokens: 3)
        let ticket = try final.beginSend(sequence: 0, nativeCommittedTokens: 3)
        try final.completeSend(ticket)
        try rejects { try final.beginPreparation(sequence: 1, nativeCommittedTokens: 3) }
        try rejects { _ = try QwenGenerationPrefillWindow(promptCount: 0, chunkSize: 512) }
        try rejects { _ = try QwenGenerationPrefillWindow(promptCount: 8192, chunkSize: 513) }
    }
    static func capacities() throws {
        let a = try QwenGenerationPrefillAllowance.derive(rank: 0, promptCount: 8192, chunkSize: 512,
            hiddenSize: 4096, elementBytes: 2, bound: { $0 + 4096 })
        let extra = try a.reservedBytes
        try require(a.extraNativeBytes == 4_198_400 && a.extraHostBytes == 4_259_840 && extra == 8_458_240,
            "Lookahead did not separately charge allocator-rounded boundary, host copy and bookkeeping")
        try a.requireCapacity(baseBytes: 100, ownerLimit: extra + 100, readinessLimit: extra + 100)
        try rejects { try a.requireCapacity(baseBytes: 100, ownerLimit: extra + 99, readinessLimit: extra + 100) }
        try rejects { try a.requireCapacity(baseBytes: 100, ownerLimit: extra + 100, readinessLimit: extra + 99) }
        try rejects { try a.requireCapacity(baseBytes: Int.max, ownerLimit: Int.max, readinessLimit: Int.max) }
        for (rank, prompt) in [(1, 8192), (0, 512)] {
            let value = try QwenGenerationPrefillAllowance.derive(rank: rank, promptCount: prompt, chunkSize: 512,
                hiddenSize: 4096, elementBytes: 2, bound: { _ in throw ProbeError("Unused native allowance") })
            try require(value.extraNativeBytes == 0 && value.extraHostBytes == 65_536, "Rank/final-only request acquired a prefetch buffer")
        }
        try rejects { _ = try QwenGenerationPrefillAllowance.derive(rank: 0, promptCount: 8192, chunkSize: 512,
            hiddenSize: 4096, elementBytes: 2, bound: { $0 - 1 }) }
        try rejects {
            let value = try QwenGenerationPrefillAllowance.derive(rank: 0, promptCount: 8192, chunkSize: 512,
                hiddenSize: 4096, elementBytes: 2, bound: { _ in Int.max })
            _ = try value.reservedBytes
        }
        for (rank, prompt, chunk, hidden, element) in [(2,8192,512,4096,2), (0,0,512,4096,2),
            (0,8192,513,4096,2), (0,8192,512,8193,2), (0,8192,512,4096,1)] {
            try rejects { _ = try QwenGenerationPrefillAllowance.derive(rank: rank, promptCount: prompt,
                chunkSize: chunk, hiddenSize: hidden, elementBytes: element, bound: { $0 }) }
        }
    }
}
