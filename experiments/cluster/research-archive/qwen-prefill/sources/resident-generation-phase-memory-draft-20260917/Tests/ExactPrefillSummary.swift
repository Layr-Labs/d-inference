import Foundation

struct QwenGenerationPrefillSummary: Encodable {
    let policy: String
    let rank: Int
    let preparedAheadFrames: Int
    let maximumPreparedBoundaries: Int
    let pendingConsumedAtCompletion = 0
    let decodePrefetchCount = 0
}
