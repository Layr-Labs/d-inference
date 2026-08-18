import Foundation
import Testing
@testable import DarkbloomApp

@Test("Payout entry stays exact at micro-USD precision")
func payoutEntryUsesExactMicroUSD() {
    let locale = Locale(identifier: "en_US_POSIX")

    #expect(
        ContributionsPresentation.microUSD(fromDollars: "1.25", locale: locale) ==
            MicroUSD(1_250_000)
    )
    #expect(
        ContributionsPresentation.microUSD(fromDollars: "0.000001", locale: locale) ==
            MicroUSD(1)
    )
    #expect(ContributionsPresentation.microUSD(fromDollars: "0.0000001", locale: locale) == nil)
    #expect(ContributionsPresentation.microUSD(fromDollars: "-1", locale: locale) == nil)
    #expect(ContributionsPresentation.microUSD(fromDollars: "not money", locale: locale) == nil)
    #expect(ContributionsPresentation.microUSD(fromDollars: "1,000.00", locale: locale) == nil)
    #expect(ContributionsPresentation.microUSD(fromDollars: "1.00junk", locale: locale) == nil)
    #expect(ContributionsPresentation.microUSD(fromDollars: "1e2", locale: locale) == nil)

    let german = Locale(identifier: "de_DE")
    #expect(
        ContributionsPresentation.microUSD(fromDollars: "1,25", locale: german) ==
            MicroUSD(1_250_000)
    )
    #expect(ContributionsPresentation.microUSD(fromDollars: "1.000,25", locale: german) == nil)
}

@Test("Editable payout amounts round-trip without binary floating point")
func editablePayoutAmountRoundTrips() throws {
    let locale = Locale(identifier: "en_US_POSIX")
    let original = MicroUSD(7_500_125)
    let text = ContributionsPresentation.editableDollars(original, locale: locale)
    let decoded = try #require(
        ContributionsPresentation.microUSD(fromDollars: text, locale: locale)
    )

    #expect(decoded == original)
}

@Test("Contribution update copy distinguishes current and stale samples")
func contributionUpdateCopyIsLegible() {
    let now = Date(timeIntervalSince1970: 10_000)

    #expect(ContributionsPresentation.updateText(now, relativeTo: now) == "Updated just now")
    #expect(
        ContributionsPresentation.updateText(now.addingTimeInterval(-300), relativeTo: now) ==
            "Updated 5m ago"
    )
}
