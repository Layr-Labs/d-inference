import Testing
@testable import ProviderCore

@Suite("SDK feature defaults")
struct SDKFeatureDefaultsTests {
    @Test func listedSwitchesTurnOnOnlyWhereTheOperatorSetNothing() {
        let keys = ["DARKBLOOM_A", "DARKBLOOM_B", "DARKBLOOM_C"]
        // The operator's value always wins: `0` is the kill switch, and an
        // explicit value of any spelling is left exactly as given.
        let projection = SDKFeatureDefaults.projection(
            onByDefault: keys, environment: ["DARKBLOOM_B": "0", "DARKBLOOM_C": "off", "UNRELATED": "x"])
        #expect(projection == ["DARKBLOOM_A": "1"])
        #expect(SDKFeatureDefaults.projection(onByDefault: keys, environment: ["DARKBLOOM_A": ""]).keys.sorted()
            == ["DARKBLOOM_B", "DARKBLOOM_C"])
        #expect(SDKFeatureDefaults.projection(onByDefault: [], environment: [:]).isEmpty)
    }

    @Test func everyDefaultOnSwitchReachesTheInstalledService() {
        // A default-ON switch is only a kill switch if the LaunchAgent forwards it.
        for key in SDKFeatureDefaults.onByDefault {
            #expect(LaunchAgent.passthroughEnvKeys.contains(key), "\(key)")
        }
    }
}
