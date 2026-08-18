import Testing
@testable import DarkbloomApp

@Test("Stop confirmation distinguishes idle and serving work")
func stopConfirmationReflectsServingState() {
    let idle = ProviderPreviewScenario.online.snapshot
    let serving = ProviderPreviewScenario.serving.snapshot

    let idleConfirmation = ProviderActionConfirmation(action: .stop, snapshot: idle)
    let servingConfirmation = ProviderActionConfirmation(action: .stop, snapshot: serving)

    #expect(idleConfirmation?.title == "Take this Mac offline?")
    #expect(idleConfirmation?.buttonTitle == "Take Offline")
    #expect(idleConfirmation?.message.contains("Active work") == false)
    #expect(servingConfirmation?.title == "Take this Mac offline while it is serving?")
    #expect(servingConfirmation?.message.contains("Active work may be interrupted") == true)
}

@Test("Restart confirmation distinguishes idle and serving work")
func restartConfirmationReflectsServingState() {
    let idleConfirmation = ProviderActionConfirmation(
        action: .restart,
        snapshot: ProviderPreviewScenario.online.snapshot
    )
    let servingConfirmation = ProviderActionConfirmation(
        action: .restart,
        snapshot: ProviderPreviewScenario.serving.snapshot
    )

    #expect(idleConfirmation?.title == "Restart Darkbloom?")
    #expect(idleConfirmation?.message.contains("briefly stop") == true)
    #expect(servingConfirmation?.title == "Restart while private work is active?")
    #expect(servingConfirmation?.message.contains("interrupt active work") == true)
}

@Test("Non-destructive provider actions do not request confirmation")
func nonDestructiveActionsSkipConfirmation() {
    let snapshot = ProviderPreviewScenario.online.snapshot

    #expect(ProviderActionConfirmation(action: .start, snapshot: snapshot) == nil)
    #expect(ProviderActionConfirmation(action: .refresh, snapshot: snapshot) == nil)
    #expect(ProviderActionConfirmation(action: .runDiagnostics, snapshot: snapshot) == nil)
}
