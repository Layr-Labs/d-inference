import Testing
@testable import ProviderCore

@Suite("SDK feature defaults")
struct SDKFeatureDefaultsTests {
    @Test func listedSwitchesTurnOnOnlyWhereTheOperatorSetNothing() {
        let keys = ["DARKBLOOM_A", "DARKBLOOM_B", "DARKBLOOM_C"]
        // The operator's non-empty value always wins: `0` is the kill switch,
        // and any explicit spelling is left exactly as given.
        let projection = SDKFeatureDefaults.projection(
            onByDefault: keys, environment: ["DARKBLOOM_B": "0", "DARKBLOOM_C": "off", "UNRELATED": "x"])
        #expect(projection == ["DARKBLOOM_A": "1"])
        // Empty means unset, as for the LaunchAgent, which drops empty values:
        // foreground and installed service agree.
        #expect(SDKFeatureDefaults.projection(onByDefault: keys, environment: ["DARKBLOOM_A": ""]).keys.sorted()
            == keys)
        #expect(SDKFeatureDefaults.projection(onByDefault: [], environment: [:]).isEmpty)
    }

    @Test func injectedDefaultsAreNeverWrittenIntoAServicePlist() {
        // review prov-2109 SF1: an installing `darkbloom` process carries its own
        // injected defaults; persisting them would pin today's default into the
        // plist, so a later release could not change it without a reinstall.
        let key = "DARKBLOOM_CONSTRAINT_SPANS"
        #expect(LaunchAgent.passthroughEnvironment(from: [key: "1"], injected: [key]).isEmpty)
        // The operator's own value (not injected) is still forwarded, `0` included.
        #expect(LaunchAgent.passthroughEnvironment(from: [key: "0"], injected: []) == [key: "0"])
        #expect(LaunchAgent.passthroughEnvironment(from: [key: "1"], injected: []) == [key: "1"])
    }

    @Test func everyDefaultOnSwitchReachesTheInstalledService() {
        // A default-ON switch is only a kill switch if the LaunchAgent forwards it.
        for key in SDKFeatureDefaults.onByDefault {
            #expect(LaunchAgent.passthroughEnvKeys.contains(key), "\(key)")
        }
    }
}
