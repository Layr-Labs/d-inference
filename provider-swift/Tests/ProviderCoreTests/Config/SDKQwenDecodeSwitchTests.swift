import Testing
@testable import ProviderCore

/// The SDK reads the Qwen 3.5 family's decode command-buffer switch once per
/// process. Its rollback must reach a background provider too, so the
/// LaunchAgent forwards the operator's value.
@Suite("SDK Qwen 3.5 decode switch reaches the LaunchAgent")
struct SDKQwenDecodeSwitchTests {
    @Test func rollbackIsForwarded() {
        let key = "DARKBLOOM_QWEN35_DECODE_COMMAND_BUFFERS"
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(key))
        #expect(LaunchAgent.passthroughEnvironment(from: [key: "0"])[key] == "0")
        #expect(LaunchAgent.passthroughEnvironment(from: [:])[key] == nil)
    }
}
