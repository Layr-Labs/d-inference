import Foundation
import MLX
import MLXNN

struct QwenStageMemoryObservation: Encodable {
    let phase: String
    let activeMLXBytes: Int
    let cachedMLXBytes: Int
    let peakMLXBytesSinceProcessStart: Int

    init(_ phase: String) {
        self.phase = phase
        activeMLXBytes = Memory.activeMemory; cachedMLXBytes = Memory.cacheMemory
        peakMLXBytesSinceProcessStart = Memory.peakMemory
    }
}
