import MLX

/// Borrow the production attention/fence implementation without exposing its
/// mutable cache flags. No model, row transaction or admission is created here.
@_spi(OwnedTargetVerification)
public enum CBv2OwnedRectangularAttention {
    public enum Failure: Error { case unsupportedOrBusyCache }

    public struct Capture {
        public let row: any CBv2SequenceKV
        public let keys: MLXArray
        public let values: MLXArray
        public init(row: any CBv2SequenceKV, keys: MLXArray, values: MLXArray) {
            self.row = row; self.keys = keys; self.values = values
        }
    }

    public static func withSerialQueries<T>(
        caches: [any CBv2AttendingLayerCache], body: () throws -> T
    ) throws -> T {
        let serializing = caches.compactMap { $0 as? any CBv2MTPRectangularSerializing }
        guard !caches.isEmpty, serializing.count == caches.count,
              Set(caches.map { ObjectIdentifier($0) }).count == caches.count,
              serializing.allSatisfy({ !$0.mtpSerializesRectangularAttention && !$0.mtpBatchesRectangularAttention }) else {
            throw Failure.unsupportedOrBusyCache
        }
        for cache in serializing { cache.mtpSerializesRectangularAttention = true }
        defer { for cache in serializing { cache.mtpSerializesRectangularAttention = false } }
        return try body()
    }

    public static func stagingRoots(rows: [any CBv2SequenceKV]) -> [MLXArray] {
        rows.flatMap { ($0 as? CBv2WindowedSequenceKV)?.cbv2SpeculativeEvaluationRoots() ?? [] }
    }

    /// Same backend decision and exact fence as mtpFreezeCaptures. Contiguous
    /// snapshots retain their pre-write descriptors; no extra eval is needed.
    /// A future recyclable backend must publish the edge or evaluate fallback
    /// roots BEFORE any speculative writes are constructed.
    public static func protectCaptures(
        _ captures: [Capture], backend: any CBv2KVBackend, check: () throws -> Void
    ) throws {
        try check()
        if backend.requiresMaterializedSnapshots {
            let unfenceable = CBv2MTPCaptureFence.publish(captures.map {
                (row: $0.row, keys: $0.keys, values: $0.values)
            })
            if !unfenceable.isEmpty {
                eval(unfenceable); CBv2CoreInstrumentation.recordHostSync(); try check()
            }
        }
        try check()
    }
}
