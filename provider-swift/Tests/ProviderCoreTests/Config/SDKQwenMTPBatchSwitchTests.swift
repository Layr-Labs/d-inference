import Testing
@testable import ProviderCore

/// The SDK reads how many Qwen 3.5-family decode rows may speculate together
/// once per process. Its rollback (`1`, one speculating row) must reach a
/// background provider too, so the LaunchAgent forwards the operator's value.
@Suite("SDK Qwen MTP batch switch reaches the LaunchAgent")
struct SDKQwenMTPBatchSwitchTests {
    @Test func batchRollbackIsForwarded() {
        let key = "DARKBLOOM_QWEN_MTP_MAX_BATCH"
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(key))
        #expect(LaunchAgent.passthroughEnvironment(from: [key: "1"])[key] == "1")
        #expect(LaunchAgent.passthroughEnvironment(from: [:])[key] == nil)
    }
}
