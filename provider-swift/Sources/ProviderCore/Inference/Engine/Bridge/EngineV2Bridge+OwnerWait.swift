// Me first: the owner's request asks Darkbloom work that hasn't answered to give way while it waits in the engine.

import Foundation

extension EngineV2Bridge {
    func setOwnerWaitPollIntervalForTesting(_ interval: Duration) {
        ownerWaitPollInterval = interval
    }
}
