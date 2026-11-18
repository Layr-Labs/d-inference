import Testing
@testable import ProviderCore

/// The SDK reads three Gemma 4 decode switches once per process. Each one's
/// rollback must reach a background provider too, so the LaunchAgent forwards
/// the operator's value.
@Suite("SDK Gemma 4 decode switches reach the LaunchAgent")
struct SDKGemmaDecodeSwitchesTests {
    @Test(arguments: [
        "DARKBLOOM_GEMMA4_MTP_COMMAND_BUFFERS",
        "DARKBLOOM_GEMMA4_COMPILED_FEEDFORWARD",
        "DARKBLOOM_GEMMA4_COMPILED_FEEDFORWARD_SORTED",
    ])
    func rollbackIsForwarded(key: String) {
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(key))
        #expect(LaunchAgent.passthroughEnvironment(from: [key: "0"])[key] == "0")
        #expect(LaunchAgent.passthroughEnvironment(from: [:])[key] == nil)
    }
}
