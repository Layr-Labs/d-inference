// Copyright © 2026 Eigen Labs.
import Foundation
import MLXLMCommon

extension EngineV2Factory {
    /// The loop settings both native MiMo engines (contiguous and paged) run with.
    static func nativeMiMoLoopConfig(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CBv2EngineLoopConfig {
        CBv2EngineLoopConfig(useLegacyRequestTimeout: legacyRequestTimeoutEnabled(environment: environment))
    }
}
