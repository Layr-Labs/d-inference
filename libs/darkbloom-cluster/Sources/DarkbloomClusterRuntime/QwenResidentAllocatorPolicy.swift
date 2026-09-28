import Foundation

/// Explicit process policy. Default facade callers preserve MLX's existing
/// cache setting; the separately launched dedicated worker selects zero.
public enum QwenResidentAllocatorPolicy: String, Sendable {
    case unchanged = "unchanged_v1"
    case disableFreedBufferCache = "disable_freed_buffer_cache_v1"

    func configure(setCacheLimit: (Int) throws -> Void, check: () throws -> Void) throws {
        guard self == .disableFreedBufferCache else { return }
        try check()
        try setCacheLimit(0)
        try check()
    }

    /// The caller owns the native-error scope and supplies actual operations.
    /// These callbacks permit CPU tests without invoking MLX or fabricating an
    /// admission permit. All live resource gates remain outside this policy.
    func prepareReady(synchronize: () throws -> Void,
                      snapshot: () -> QwenResidentAllocatorSnapshot,
                      clearCache: () throws -> Void,
                      check: () throws -> Void) throws {
        guard self == .disableFreedBufferCache else { return }
        try check()
        try synchronize()
        try check()
        let before = snapshot()
        try clearCache()
        try check()
        let after = snapshot()
        guard before.activeBytes >= 0, before.cachedBytes >= 0,
              before.peakBytes >= before.activeBytes,
              after.cachedBytes == 0, after.activeBytes == before.activeBytes,
              after.peakBytes == before.peakBytes else {
            throw ProbeError("Resident cache clearing changed active/peak storage or retained cached buffers")
        }
    }
}

struct QwenResidentAllocatorSnapshot: Equatable {
    let activeBytes: Int
    let cachedBytes: Int
    let peakBytes: Int
}
