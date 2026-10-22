import Foundation
import MLX
import MLXLMCommon

/// Takes the last rows of a verify window back out of a stage's attention
/// caches, so that the caches hold exactly what they would hold had only the
/// kept rows run.
///
/// A window of n >= 2 rows enters every cache through its multi-token update:
/// a growing cache (full attention) appends at its offset; a rotating cache
/// (sliding window) first puts its ring in temporal order, keeps the last
/// `window - 1` positions and appends the n rows, so its buffer ends with the
/// window in order and its write index is the buffer's length. Removing r rows
/// is then exact in both: the growing cache moves its offset back (the rows
/// past it are overwritten by the next update); the rotating cache keeps the
/// buffer without its last r positions and moves offset and write index back.
/// Either cache's next update, of one row or of a window, then sees what it
/// would have seen after only the kept rows: the rotating cache's single-row
/// update trims to its window and wraps, its multi-row update re-reads the
/// buffer in temporal order.
///
/// A window of one row never needs a roll back (it is always kept); any other
/// state is refused rather than repaired.
enum MiMoWindowRollback {
    static func trim(_ caches: [KVCache], by count: Int) throws {
        guard count >= 0 else { throw ProbeError("A verify window cannot remove a negative number of rows") }
        guard count > 0 else { return }
        // Check every cache before changing any.
        for cache in caches {
            switch cache {
            case let rotating as RotatingKVCache:
                let meta = rotating.metaState.compactMap(Int.init)
                let state = rotating.innerState()
                guard meta.count == 5, meta[0] == 0, state.count == 2, state[0].ndim == 4,
                      state[0].dim(2) == state[1].dim(2), meta[4] == state[0].dim(2),
                      meta[4] > count, meta[3] >= count else {
                    throw ProbeError("A sliding-window cache is not in the state a verify window leaves it in")
                }
            case let simple as KVCacheSimple:
                guard simple.offset >= count else {
                    throw ProbeError("A full-attention cache holds fewer rows than the window removes")
                }
            default:
                throw ProbeError("A verify window can only roll back the stage's own attention caches")
            }
        }
        for cache in caches {
            switch cache {
            case let rotating as RotatingKVCache:
                var meta = rotating.metaState
                let state = rotating.innerState()
                let length = state[0].dim(2) - count
                rotating.state = state.map { $0[.ellipsis, ..<length, 0...] }
                meta[3] = String(rotating.offset - count)
                meta[4] = String(length)
                rotating.metaState = meta
            case let simple as KVCacheSimple:
                guard simple.trim(count) == count else {
                    throw ProbeError("A full-attention cache did not remove the window's rows")
                }
            default:
                throw ProbeError("A verify window can only roll back the stage's own attention caches")
            }
        }
    }
}

/// Per-row digests of a window's residual `[1, n, H]`: a kept row's digest is
/// what a plain decode step's boundary digest is for the same position.
enum MiMoWindowRows {
    static func rowSHA256(_ residual: MLXArray) throws -> [String] {
        guard residual.ndim == 3, residual.dim(0) == 1, residual.dim(1) >= 1 else {
            throw ProbeError("A verify window residual is [1, n, H]")
        }
        return (0..<residual.dim(1)).map { sha256(residual[0..., $0 ..< ($0 + 1), 0...].asData().data) }
    }
}
