import Testing
@testable import DarkbloomApp

@Test("Mac form factor follows the human-readable hardware name")
func classifiesCurrentMacFamilies() {
    #expect(MacFormFactor.classify(displayName: "MacBook Pro", modelIdentifier: "Mac16,5") == .macBook)
    #expect(MacFormFactor.classify(displayName: "Mac mini", modelIdentifier: "Mac16,10") == .macMini)
    #expect(MacFormFactor.classify(displayName: "Mac Studio", modelIdentifier: "Mac15,14") == .macStudio)
    #expect(MacFormFactor.classify(displayName: "iMac", modelIdentifier: "Mac15,5") == .iMac)
    #expect(MacFormFactor.classify(displayName: "Mac Pro", modelIdentifier: "Mac14,8") == .macPro)
}

@Test("Legacy identifiers remain useful when the display name is unavailable")
func classifiesLegacyIdentifiers() {
    #expect(MacFormFactor.classify(displayName: "Mac", modelIdentifier: "Macmini9,1") == .macMini)
    #expect(MacFormFactor.classify(displayName: "Mac", modelIdentifier: "MacBookPro18,4") == .macBook)
    #expect(MacFormFactor.classify(displayName: "Mac", modelIdentifier: "Mac16,5") == .mac)
}

@Test("Apple silicon facts identify the generation introduction year")
func resolvesAppleSiliconFacts() {
    #expect(AppleSiliconFacts.resolve(chipName: "Apple M4 Max") == AppleSiliconFacts(
        generation: 4,
        introductionYear: 2024
    ))
    #expect(AppleSiliconFacts.resolve(chipName: "Apple M2 Ultra")?.introductionYear == 2022)
    let m3 = AppleSiliconFacts.resolve(chipName: "Apple M3 Max")
    #expect(m3?.introductionYear == 2023)
    #expect(AppleSiliconFacts.resolve(chipName: "Intel Core i9") == nil)
}

@Test("Machine facts keep unavailable values honest")
func formatsUnavailableMachineFacts() {
    #expect(MachineFactsFormatter.memory(nil) == "—")
    #expect(MachineFactsFormatter.storageSummary(total: nil, available: nil) == "—")
}
