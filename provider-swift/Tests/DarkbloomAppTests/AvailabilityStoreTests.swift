import Foundation
import Testing
@testable import DarkbloomApp

@Test("Availability fixtures cover policy and runtime edge states")
@MainActor
func availabilityFixturesCoverRequiredStates() throws {
    let always = AvailabilityStore(fixture: .always)
    #expect(always.savedPolicy?.mode == .wheneverRunning)
    #expect(always.runtime?.state == .available)

    let active = AvailabilityStore(fixture: .scheduledActive)
    #expect(active.savedPolicy?.mode == .scheduled)
    #expect(active.runtime?.state == .available)
    #expect(active.runtime?.nextObservedTransitionAt != nil)

    let scheduledOff = AvailabilityStore(fixture: .scheduledOff)
    #expect(scheduledOff.runtime?.state == .scheduledOff)

    let paused = AvailabilityStore(fixture: .pausedScheduled)
    #expect(paused.savedPolicy?.mode == .scheduled)
    #expect(paused.runtime?.state == .paused)

    let serving = AvailabilityStore(fixture: .serving)
    #expect(serving.runtime?.state == .serving)

    let loading = AvailabilityStore(fixture: .loading)
    #expect(loading.savedPolicy == nil)
    #expect(loading.draft == nil)
    #expect(loading.loadState == .loading)

    let stale = AvailabilityStore(fixture: .stale)
    guard case .stale = stale.loadState else {
        Issue.record("Stale policy must remain visible as stale")
        return
    }
    #expect(stale.runtime?.isStale == true)

    let malformed = AvailabilityStore(fixture: .malformed)
    guard case .malformed = malformed.loadState else {
        Issue.record("Malformed config must remain distinct")
        return
    }
    #expect(malformed.savedPolicy == nil)
    #expect(malformed.draft == nil)
}

@Test("Successful Save and Restart persists the draft")
@MainActor
func availabilityPreviewSaveAndRestartSucceeds() async throws {
    let store = AvailabilityStore(fixture: .always)
    store.setMode(.scheduled)
    store.addWindow(AvailabilityWindow(
        id: "night",
        days: [.monday, .tuesday],
        start: try #require(AvailabilityTimeOfDay(hour: 20, minute: 0)),
        end: try #require(AvailabilityTimeOfDay(hour: 7, minute: 0))
    ))
    store.setIdleUnloadMinutes(0)

    #expect(store.hasUnsavedChanges)
    #expect(store.canSaveAndRestart)

    let saveDate = AvailabilityFixtures.referenceDate.addingTimeInterval(10)
    await store.saveAndRestartPreview(at: saveDate)

    #expect(store.savedPolicy == store.draft)
    #expect(store.savedPolicy?.idleUnloadingIsDisabled == true)
    #expect(!store.hasUnsavedChanges)
    #expect(store.saveState == .savedAndRestarted(at: saveDate))
}

@Test("Failed Save and Restart retains edits and the persisted policy")
@MainActor
func availabilityPreviewSaveFailureRetainsDraft() async {
    let store = AvailabilityStore(fixture: .saveFailure)
    let original = store.savedPolicy
    let edited = store.draft

    guard case .failed = store.saveState else {
        Issue.record("Save-failure fixture should render the retained-failure state immediately")
        return
    }
    #expect(store.hasUnsavedChanges)

    await store.saveAndRestartPreview(at: AvailabilityFixtures.referenceDate)

    guard case .failed(let message) = store.saveState else {
        Issue.record("Save-failure fixture must fail deterministically")
        return
    }
    #expect(message.contains("changes are still here"))
    #expect(store.savedPolicy == original)
    #expect(store.draft == edited)
    #expect(store.hasUnsavedChanges)

    store.dismissSaveResult()
    #expect(store.saveState == .idle)
    #expect(store.draft == edited)
}

@Test("Invalid edits never enter the saving state")
@MainActor
func availabilityInvalidDraftIsNotSaved() async throws {
    let store = AvailabilityStore(fixture: .always)
    store.setMode(.scheduled)
    store.addWindow(AvailabilityWindow(
        id: "equal",
        days: [.friday],
        start: try #require(AvailabilityTimeOfDay(hour: 9, minute: 0)),
        end: try #require(AvailabilityTimeOfDay(hour: 9, minute: 0))
    ))

    #expect(!store.canSaveAndRestart)
    await store.saveAndRestartPreview()

    guard case .validationFailed(let issues) = store.saveState else {
        Issue.record("Invalid draft should expose validation issues")
        return
    }
    #expect(issues.contains(.windowHasEqualStartAndEnd(windowID: "equal")))
    #expect(store.savedPolicy?.mode == .wheneverRunning)
    #expect(store.draft?.mode == .scheduled)
}

@Test("Discard restores the persistent policy after editing")
@MainActor
func availabilityDiscardRestoresSavedPolicy() {
    let store = AvailabilityStore(fixture: .scheduledActive)
    let original = store.savedPolicy
    store.setIdleUnloadMinutes(5)
    #expect(store.hasUnsavedChanges)

    store.discardDraftChanges()
    #expect(store.draft == original)
    #expect(!store.hasUnsavedChanges)
    #expect(store.saveState == .idle)
}
