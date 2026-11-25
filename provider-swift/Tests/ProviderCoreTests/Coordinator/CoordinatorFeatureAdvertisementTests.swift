import Testing

@testable import ProviderCore

@Suite("Coordinator feature advertisement")
struct CoordinatorFeatureAdvertisementTests {
    @Test("only the latest trust status of the connection turns it on")
    func latestTrustStatusDecides() {
        let advertisement = CoordinatorFeatureAdvertisement(feature: "terminal_fields_sealed")
        #expect(!advertisement.value)
        advertisement.update(features: ["other", "terminal_fields_sealed"])
        #expect(advertisement.value)
        advertisement.update(features: ["other"])
        #expect(!advertisement.value)
        advertisement.update(features: ["terminal_fields_sealed"])
        advertisement.update(features: nil)
        #expect(!advertisement.value)
        advertisement.update(features: ["terminal_fields_sealed"])
        advertisement.reset()
        #expect(!advertisement.value)
    }
}
