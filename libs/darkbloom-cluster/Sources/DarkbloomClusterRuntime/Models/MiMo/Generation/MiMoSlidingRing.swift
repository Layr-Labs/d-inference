import MLXLMCommon

/// The metadata (`RotatingKVCache.metaState`) of a MiMo sliding-window
/// layer's ordinary cache, `RotatingKVCache(maxSize: window)`
/// (`MiMoV26TextModel.newCache`), in the layout the pinned SDK writes: keep,
/// window, step, offset, write index, capacity origin and whether the ring
/// has wrapped. Writes move only the offset, the write index and the wrapped
/// flag; every other value stays the fresh ring's. A ring with a kept prefix,
/// another step or origin, or a rewind reserve (an eighth value) is not the
/// model's: the prefix snapshot and the phase split refuse it, as they refuse
/// any other layout.
enum MiMoSlidingRing {
    private static let offsetField = 3, indexField = 4, wrappedField = 6

    /// The model's ring of `window` positions after writes that left it at
    /// `offset`, writing next at `index`; nil when a fresh ring writes
    /// another layout.
    static func metadata(window: Int, offset: Int, index: Int, wrapped: Bool) -> [String]? {
        var fields = RotatingKVCache(maxSize: window).metaState
        guard fields.count == 7, fields[offsetField] == "0", fields[indexField] == "0",
              fields[wrappedField] == "false" else { return nil }
        fields[offsetField] = String(offset); fields[indexField] = String(index); fields[wrappedField] = String(wrapped)
        return fields
    }

    /// Whether `ring` is the model's ring: its metadata is a fresh ring's of
    /// its window in every value but the three that writes move.
    static func isModelRing(_ ring: RotatingKVCache) -> Bool {
        let fields = ring.metaState
        guard let window = ring.maxSize, window > 0, fields.count > wrappedField,
              let index = Int(fields[indexField]), let wrapped = Bool(fields[wrappedField]) else { return false }
        return fields == metadata(window: window, offset: ring.offset, index: index, wrapped: wrapped)
    }
}
