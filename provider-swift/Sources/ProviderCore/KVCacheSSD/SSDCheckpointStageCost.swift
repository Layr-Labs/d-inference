// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon

/// The restore cost a complete-checkpoint store advertises in its ready
/// receipts (`PrefixCacheReadyResult.stageMs`). The coordinator charges it
/// against a holder's prefill saving until a hit's measured lookup replaces
/// it. Bytes at the planning rate
/// (`SSDPrefixCachePolicy.conservativeStageBytesPerSecond`) price the read
/// and decrypt but miss the part of a restore that does not grow with the
/// file: on GLM it is mostly the device's first work after idling, plus engine
/// turns under load. The estimate adds an exponentially weighted average of
/// what this store's completed stages took beyond the byte price. Until the
/// first one completes, a layout with a measured fixed part starts from it;
/// any other layout starts from zero.
final class SSDCheckpointStageCost: @unchecked Sendable {
    /// Weight of the newest stage.
    static let smoothing = 0.25

    /// GLM-5.3-Flash on an M5 Ultra: the median, over nine restores of the
    /// 187, 301 and 716 MB BF16 checkpoints, of the stage beyond the byte price.
    static let glm5NextPriorOverheadMilliseconds = 935.0

    static func priorOverheadMilliseconds(backendLayout: String) -> Double {
        backendLayout == CBv2CompleteCheckpointManifest.glm5NextPagedLayout
            ? glm5NextPriorOverheadMilliseconds : 0
    }

    private let lock = NSLock()
    private var overheadMilliseconds: Double
    private var observed = false

    init(priorOverheadMilliseconds: Double) {
        overheadMilliseconds = max(0, priorOverheadMilliseconds)
    }

    /// One completed stage of a `bytes`-byte file. The first measurement
    /// replaces the prior; later ones are averaged in.
    func record(bytes: Int, milliseconds: Double) {
        guard bytes > 0, milliseconds.isFinite, milliseconds >= 0 else { return }
        let overhead = max(
            0, milliseconds - SSDPrefixCachePolicy.estimatedStageMillisDouble(bytes: bytes))
        lock.withLock {
            overheadMilliseconds =
                observed
                ? overheadMilliseconds + Self.smoothing * (overhead - overheadMilliseconds)
                : overhead
            observed = true
        }
    }

    func estimatedMilliseconds(bytes: Int) -> Double {
        let priced = SSDPrefixCachePolicy.estimatedStageMillisDouble(bytes: bytes)
        guard priced > 0 else { return 0 }
        let overhead = lock.withLock { overheadMilliseconds }
        return min(PrefixCacheReadyResult.maxStageMs, (priced + overhead).rounded(.up))
    }
}
