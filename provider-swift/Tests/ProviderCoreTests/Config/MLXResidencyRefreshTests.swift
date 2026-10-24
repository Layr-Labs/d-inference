import Testing

@testable import ProviderCore

@Suite("MLX residency-refresh default")
struct MLXResidencyRefreshTests {
    @Test("an unset key gets the default interval")
    func exportsDefaultWhenUnset() {
        var written: [String: String] = [:]
        let value = MLXResidencyRefresh.applyDefault(
            getenv: { _ in nil },
            setenv: { written[$0] = $1 })
        #expect(value == "1000")
        #expect(written == [MLXResidencyRefresh.environmentKey: "1000"])
    }

    @Test("an operator value, including 0 (off), is kept")
    func keepsOperatorValue() {
        for operatorValue in ["0", "250", ""] {
            var written: [String: String] = [:]
            let value = MLXResidencyRefresh.applyDefault(
                getenv: { $0 == MLXResidencyRefresh.environmentKey ? operatorValue : nil },
                setenv: { written[$0] = $1 })
            #expect(value == operatorValue)
            #expect(written.isEmpty)
        }
    }

    @Test("the default stays below macOS's ~2 s idle unwiring window")
    func intervalBelowIdleWindow() {
        #expect(MLXResidencyRefresh.defaultIntervalMilliseconds > 0)
        #expect(MLXResidencyRefresh.defaultIntervalMilliseconds < 2000)
    }

    @Test("the launchd job forwards an operator override")
    func launchAgentForwardsKey() {
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(MLXResidencyRefresh.environmentKey))
    }
}
