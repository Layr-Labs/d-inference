import MLX

/// Scalar/shape metadata only: no array, slice, concatenation, eval or readback.
/// Inspect under the same serialized request owner that mutates the row.
public struct CBv2ContiguousKVMetadata: Sendable {
    public struct Tensor: Sendable {
        public let shape: [Int]
        public let dtype: DType
        public let bytes: Int
        init(_ array: MLXArray) { shape = array.shape; dtype = array.dtype; bytes = array.nbytes }
    }
    public let absoluteOffset: Int
    public let retainedStart: Int
    public let retainedCount: Int
    public let window: Int?
    public let keys: Tensor?
    public let values: Tensor?
    public let retainedChunkKeys: Tensor?
    public let retainedChunkValues: Tensor?
    public let speculativeWritePending: Bool
    /// Optional staged-window metadata; inspecting it never exports a root.
    public var stagedBaseOffset: Int? = nil
    public var stagedKeys: Tensor? = nil
    public var stagedValues: Tensor? = nil
}

/// Optional introspection; existing row implementations/callers are unaffected.
public protocol CBv2ContiguousKVMetadataProviding: AnyObject {
    var cbv2ContiguousMetadata: CBv2ContiguousKVMetadata { get }
}
