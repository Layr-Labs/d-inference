// Copyright © 2026 Eigen Labs.
import Foundation
import MLXLMCommon
import Testing

enum BonsaiNativeFixtureDrain {
    /// Stream completion can precede asynchronous checkpoint donation and
    /// native retirement. Observe the real ledgers; never force-clear owners.
    static func require(_ engine: EngineV2) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while true {
            let capacity = engine.capacity()
            let idle = capacity.activeRequests == 0 && capacity.waitingRequests == 0
                && capacity.kvBytesReserved == 0 && capacity.kvBytesInUse == 0
            if idle { return }
            try #require(ContinuousClock.now < deadline,
                "native drain timed out: active=\(capacity.activeRequests), waiting=\(capacity.waitingRequests), reserved=\(capacity.kvBytesReserved), live=\(capacity.kvBytesInUse)")
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
