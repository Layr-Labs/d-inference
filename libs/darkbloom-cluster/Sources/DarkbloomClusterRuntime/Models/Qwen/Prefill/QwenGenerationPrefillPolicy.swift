import Foundation

/// Native prefill policy. The ordinary resident facade defaults to serial.
@_spi(Benchmark) public enum QwenResidentPrefillPolicy: String, Sendable {
    case serial
    case oneChunkLookahead
}

struct QwenGenerationPrefillSummary: Encodable {
    let policy: String
    let rank: Int
    let preparedAheadFrames: Int
    let maximumPreparedBoundaries: Int
    let pendingConsumedAtCompletion = 0
    let decodePrefetchCount = 0
}

/// CPU frontier/slot guard, not evidence of native execution. The private
/// producer advances this only around actual Session/transport returns.
struct QwenGenerationPrefillWindow {
    struct Commit: Equatable { let sequence: Int, committedTokens: Int }
    let promptCount: Int
    let chunkSize: Int
    let frameCount: Int
    private(set) var nextSequence = 0
    private(set) var preparing: Int?
    private(set) var prepared: Commit?
    private(set) var pending: Commit?
    private(set) var sendCompleted = false
    private(set) var preparedAheadFrames = 0
    private(set) var maximumPreparedBoundaries = 0
    private(set) var failed = false
    var complete: Bool { !failed && nextSequence == frameCount && preparing == nil && prepared == nil && pending == nil }

    init(promptCount: Int, chunkSize: Int) throws {
        guard (1...32_768).contains(promptCount), (1...512).contains(chunkSize) else {
            throw ProbeError("Invalid bounded prefill window geometry")
        }
        self.promptCount = promptCount; self.chunkSize = chunkSize
        frameCount = (promptCount - 1) / chunkSize + 1
    }
    mutating func beginPreparation(sequence: Int, nativeCommittedTokens: Int) throws {
        let expected = nextSequence + (pending == nil ? 0 : 1)
        try require(sequence == expected && sequence < frameCount && preparing == nil && prepared == nil
            && (pending == nil || sendCompleted) && nativeCommittedTokens == sequence * chunkSize,
            "Prefill preparation exceeds one slot, unsent credit or exact native frontier")
        preparing = sequence
    }
    mutating func commitPreparation(sequence: Int, nativeCommittedTokens: Int) throws {
        try require(preparing == sequence && prepared == nil
            && nativeCommittedTokens == min(promptCount, (sequence + 1) * chunkSize),
            "Prepared prefill commit differs from its actual frame")
        prepared = .init(sequence: sequence, committedTokens: nativeCommittedTokens); preparing = nil
        maximumPreparedBoundaries = 1
        if pending != nil { preparedAheadFrames += 1 }
    }
    mutating func beginSend(sequence: Int, nativeCommittedTokens: Int) throws -> Commit {
        let value = Commit(sequence: sequence, committedTokens: nativeCommittedTokens)
        try require(sequence == nextSequence && pending == nil && preparing == nil && prepared == value,
            "Prefill send lacks its exact prepared commit or prior consumed credit")
        prepared = nil; pending = value; sendCompleted = false; return value
    }
    mutating func completeSend(_ value: Commit) throws {
        try require(pending == value && !sendCompleted, "Prefill send completion is stale or repeated")
        sendCompleted = true
    }
    mutating func consume(_ value: Commit) throws {
        try require(pending == value && sendCompleted && preparing == nil,
            "Prefill consumed acknowledgment lacks its captured committed frontier")
        pending = nil; sendCompleted = false; nextSequence += 1
    }
    mutating func cancel() { failed = true; preparing = nil; prepared = nil; pending = nil }
    private mutating func require(_ value: Bool, _ message: String) throws {
        guard !failed && value else { cancel(); throw ProbeError(message) }
    }
}
