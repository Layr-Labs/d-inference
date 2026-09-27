import Foundation

extension ThroughputSweep {
    struct DecodeWarmupFailure: Error, LocalizedError, CustomStringConvertible {
        let batchSize: Int
        let reason: String

        var description: String {
            "Decode warmup failed for B=\(batchSize): \(reason). No decode measurements recorded."
        }

        var errorDescription: String? { description }
    }

    /// Every requested shape must finish its full token budget before timing
    /// starts. Retrying a failed warmup as a measured cell can charge missing
    /// kernel compilation to one benchmark arm and silently bias comparisons.
    /// The injected runner also lets tests exercise this gate without a GPU.
    static func warmDecodeShapes(
        batchSizes: [Int],
        runBatch: (Int) async -> (constructionFailure: String?, submitFailure: String?)
    ) async throws {
        for batchSize in batchSizes {
            let result = await runBatch(batchSize)
            if let failure = result.constructionFailure {
                throw DecodeWarmupFailure(
                    batchSize: batchSize, reason: "engine construction failed: \(failure)")
            }
            if let failure = result.submitFailure {
                throw DecodeWarmupFailure(batchSize: batchSize, reason: "row failed: \(failure)")
            }
        }
    }
}
