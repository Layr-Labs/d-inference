import Foundation
import MLXLMCommon

extension EngineV2Bridge {
    /// The slot serves through a cluster pair (`DistributedCBv2Engine`): the
    /// pair-only request behavior keys on this, never on the request.
    var servesDistributedPair: Bool { ownedEngine is DistributedCBv2Engine }
    /// The slot's engine runs token constraints (`EngineV2.acceptsTokenConstraints`):
    /// an untracked `EngineV2`, or a native-tracked one whose contract
    /// qualifies them. False for every other engine, a cluster pair included.
    var acceptsTokenConstraints: Bool { (ownedEngine as? EngineV2)?.acceptsTokenConstraints == true }
}
