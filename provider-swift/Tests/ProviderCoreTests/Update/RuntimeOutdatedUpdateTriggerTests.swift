// Contract under test: `RuntimeOutdatedUpdateTrigger.shouldCheck`, the pure
// policy gate `ProviderLoop.handleRuntimeOutdatedEvent` consults before
// starting a tracked update-check task, in Sources/ProviderCore/Update/:
//
//     public enum RuntimeOutdatedUpdateTrigger {
//         public static func shouldCheck(
//             autoUpdateEnabled: Bool,
//             envDisabled: Bool,
//             lastCheckAt: Double?,
//             now: Double
//         ) -> Bool
//     }
//
// When background auto-update is enabled, the provider runs one update
// check immediately, at most once per 10 minutes, through the existing
// AutoUpdateController. `shouldCheck` is the decision only -- ProviderLoop
// is expected to call the existing `performAutoUpdateCheck`-style path when
// this returns true, and to record `lastCheckAt` itself; this type does not
// call AutoUpdateController and carries no state of its own.
//
// Decision table:
//   autoUpdateEnabled=false                       -> false, always
//   envDisabled=true                               -> false, always
//   lastCheckAt=nil (never checked)                -> true, when eligible
//   now - lastCheckAt < 600s (10 min)               -> false
//   now - lastCheckAt >= 600s (10 min)              -> true

import Testing
@testable import ProviderCore

@Suite("RuntimeOutdatedUpdateTrigger")
struct RuntimeOutdatedUpdateTriggerTests {
    @Test("auto-update disabled never checks, regardless of spacing")
    func autoUpdateDisabledSkips() {
        #expect(!RuntimeOutdatedUpdateTrigger.shouldCheck(
            autoUpdateEnabled: false, envDisabled: false, lastCheckAt: nil, now: 1_000))
        #expect(!RuntimeOutdatedUpdateTrigger.shouldCheck(
            autoUpdateEnabled: false, envDisabled: false, lastCheckAt: 0, now: 100_000))
    }

    @Test("DARKBLOOM_NO_UPDATE_CHECK (envDisabled) never checks, even when otherwise due")
    func envDisabledSkips() {
        #expect(!RuntimeOutdatedUpdateTrigger.shouldCheck(
            autoUpdateEnabled: true, envDisabled: true, lastCheckAt: nil, now: 1_000))
        #expect(!RuntimeOutdatedUpdateTrigger.shouldCheck(
            autoUpdateEnabled: true, envDisabled: true, lastCheckAt: 0, now: 100_000))
    }

    @Test("never checked before and eligible checks immediately")
    func firstCheckRunsImmediately() {
        #expect(RuntimeOutdatedUpdateTrigger.shouldCheck(
            autoUpdateEnabled: true, envDisabled: false, lastCheckAt: nil, now: 1_000))
    }

    @Test("a check inside the 10-minute minimum spacing is skipped")
    func withinSpacingSkips() {
        #expect(!RuntimeOutdatedUpdateTrigger.shouldCheck(
            autoUpdateEnabled: true, envDisabled: false, lastCheckAt: 1_000, now: 1_000))
        #expect(!RuntimeOutdatedUpdateTrigger.shouldCheck(
            autoUpdateEnabled: true, envDisabled: false, lastCheckAt: 1_000, now: 1_000 + 599))
    }

    @Test("a check at or beyond the 10-minute minimum spacing runs")
    func atOrBeyondSpacingChecks() {
        #expect(RuntimeOutdatedUpdateTrigger.shouldCheck(
            autoUpdateEnabled: true, envDisabled: false, lastCheckAt: 1_000, now: 1_000 + 600))
        #expect(RuntimeOutdatedUpdateTrigger.shouldCheck(
            autoUpdateEnabled: true, envDisabled: false, lastCheckAt: 1_000, now: 1_000 + 1_200))
    }
}
