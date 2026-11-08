import Foundation
import MLXLMCommon

extension EngineV2Bridge {
    /// The slot serves through a cluster pair (`DistributedCBv2Engine`): the
    /// pair-only request behavior keys on this, never on the request.
    var servesDistributedPair: Bool { ownedEngine is DistributedCBv2Engine }
}
