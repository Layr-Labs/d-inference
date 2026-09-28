import Foundation

/// Root owns the CPU-only collector, actual request/profile/role admission and
/// one-shot acquisition. The factory must validate the selected local frame
/// against its fixed sequence 7 / offset 3584 / width 512 / nonfinal identity.
/// Only the callback is passed into native owners; no collector is stored there.
typealias QwenPrefillOwnerObserverFactory = (QwenLayerStageFrame) throws -> CBv2OwnerPhaseObserver

/// Selection precedes factory invocation and observer construction. Other
/// chunks and disabled calls create no observer and emit no owner events.
/// The incoming frame is from the admitted local recorded request, never wire
/// geometry. Publication remains gated by the entire outer owner's success.
func qwenPrefillSelectedOwnerObserver(for frame: QwenLayerStageFrame,
    factory: QwenPrefillOwnerObserverFactory?
) throws -> CBv2OwnerPhaseObserver? {
    guard frame.sequence == 7, let factory else { return nil }
    return try factory(frame)
}
