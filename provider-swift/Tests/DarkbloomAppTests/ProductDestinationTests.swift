import Testing
@testable import DarkbloomApp

@Test("Product destinations keep a stable desktop navigation order")
func productDestinationOrderIsStable() {
    #expect(ProductDestination.allCases == [
        .overview,
        .chat,
        .localAPI,
        .myMacs,
        .contributions,
        .availability,
        .activity,
        .models,
        .machine,
    ])
    #expect(Set(ProductDestination.allCases.map(\.id)).count == ProductDestination.allCases.count)
}

@Test("Every product destination has a visible label and symbol")
func productDestinationsHavePresentationMetadata() {
    for destination in ProductDestination.allCases {
        #expect(!destination.title.isEmpty)
        #expect(!destination.systemImage.isEmpty)
    }
}

@Test("Product preview resolves the requested My Macs state")
func productPreviewResolvesMyMacs() {
    let preview = ProductPreviewConfiguration.resolve(environment: [
        "DARKBLOOM_PREVIEW_PRODUCT_DESTINATION": "MY-MACS",
        "DARKBLOOM_PREVIEW_MY_MACS_FIXTURE": "partial-summary",
    ])

    #expect(preview?.destination == .myMacs)
    #expect(preview?.myMacsFixture == .partialSummary)
    #expect(preview?.availabilityFixture == .always)
}

@Test("Availability preview defaults coordinate policy and runtime fixtures")
func availabilityPreviewDefaultsStayAligned() {
    let scheduledOff = ProductPreviewConfiguration.resolve(environment: [
        "DARKBLOOM_PREVIEW_PRODUCT_DESTINATION": "availability",
        "DARKBLOOM_PREVIEW_AVAILABILITY_FIXTURE": "scheduled-off",
    ])
    let defaultAvailability = ProductPreviewConfiguration.resolve(environment: [
        "DARKBLOOM_PREVIEW_PRODUCT_DESTINATION": "availability",
    ])
    let pausedAvailability = ProductPreviewConfiguration.resolve(environment: [
        "DARKBLOOM_PREVIEW_PRODUCT_DESTINATION": "availability",
        "DARKBLOOM_PREVIEW_AVAILABILITY_FIXTURE": "paused-scheduled",
    ])

    #expect(scheduledOff?.availabilityFixture == .scheduledOff)
    #expect(scheduledOff?.providerScenario == .scheduledOff)
    #expect(defaultAvailability?.availabilityFixture == .scheduledActive)
    #expect(defaultAvailability?.providerScenario == .scheduledActive)
    #expect(defaultAvailability?.providerScenario.snapshot.availability.state == .scheduledActive)
    #expect(pausedAvailability?.providerScenario == .pausedScheduled)
}
