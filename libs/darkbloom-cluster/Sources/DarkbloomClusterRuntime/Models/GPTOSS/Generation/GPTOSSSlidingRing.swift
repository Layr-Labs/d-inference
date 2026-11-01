import MLXLMCommon

/// The metadata (`RotatingKVCache.metaState`) of GPT-OSS's sliding-window
/// ring, `RotatingKVCache(maxSize: window)` (`makeSlidingWindowKVCache`), in
/// the layout the pinned SDK writes: keep, window, step, offset, write index,
/// capacity origin and whether the ring has wrapped. Writes move only the
/// offset, the index and the flag. The ring's state holds its first `index`
/// rows, or the whole window once wrapped.
enum GPTOSSSlidingRing {
    struct Position: Equatable {
        let offset: Int, index: Int, wrapped: Bool
    }

    private static let offsetField = 3, indexField = 4, wrappedField = 6

    /// The metadata of a ring of `window` positions at `position`; nil when a
    /// fresh ring writes another layout.
    static func metadata(window: Int, at position: Position) -> [String]? {
        var fields = RotatingKVCache(maxSize: window).metaState
        guard fields.count == 7, fields[offsetField] == "0", fields[indexField] == "0",
              fields[wrappedField] == "false" else { return nil }
        fields[offsetField] = String(position.offset); fields[indexField] = String(position.index)
        fields[wrappedField] = String(position.wrapped)
        return fields
    }

    /// The position `metadata` gives a ring of `window` positions holding
    /// `rows` rows; nil unless that ring writes exactly this metadata.
    static func position(of metadata: [String], window: Int, rows: Int) -> Position? {
        guard metadata.count > wrappedField, let offset = Int(metadata[offsetField]),
              let index = Int(metadata[indexField]), let wrapped = Bool(metadata[wrappedField]) else { return nil }
        let position = Position(offset: offset, index: index, wrapped: wrapped)
        guard metadata == Self.metadata(window: window, at: position), offset >= rows,
              wrapped ? rows == window && index >= 0 && index <= rows : index == rows else { return nil }
        return position
    }
}
