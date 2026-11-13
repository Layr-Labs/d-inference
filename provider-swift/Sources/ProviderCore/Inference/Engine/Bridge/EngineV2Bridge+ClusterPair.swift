import Foundation
import MLXLMCommon

extension EngineV2Bridge {
    /// The slot serves through a cluster pair (`DistributedCBv2Engine`): the
    /// pair-only request behavior keys on this, never on the request.
    var servesDistributedPair: Bool { ownedEngine is DistributedCBv2Engine }

    /// Whether this slot's engine samples under a request's token constraint.
    var runsTokenConstraints: Bool {
        Self.runsTokenConstraints(
            servesDistributedPair: servesDistributedPair, tracksNativeShutdown: tracksNativeShutdown)
    }

    /// A cluster pair refuses a token constraint before reserving
    /// (`DistributedRequestRefusal.constrainedDecodingUnsupported`), and a
    /// native-tracked engine at submit (`EngineV2.validateRequest`).
    static func runsTokenConstraints(servesDistributedPair: Bool, tracksNativeShutdown: Bool) -> Bool {
        !servesDistributedPair && !tracksNativeShutdown
    }
}
