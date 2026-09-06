import Testing
@testable import DarkbloomApp

@Test("Menu bar does not read provider fixtures before setup completes")
func menuBarSetupContentIsLazy() {
    var didReadSnapshot = false

    let content = ProviderMenuBarContent.resolve(
        hasCompletedSetup: false,
        snapshot: {
            didReadSnapshot = true
            return ProviderPreviewScenario.online.snapshot
        }()
    )

    #expect(content == .setup)
    #expect(!content.showsProviderControls)
    #expect(didReadSnapshot == false)
}

@Test("Menu bar exposes provider content only after setup completes")
func menuBarProviderContentRequiresCompletedSetup() {
    let snapshot = ProviderPreviewScenario.serving.snapshot
    let content = ProviderMenuBarContent.resolve(
        hasCompletedSetup: true,
        snapshot: snapshot
    )

    #expect(content == .provider(snapshot))
    #expect(content.showsProviderControls)
}

@Test("Menu bar keeps its brand icon and announces provider state")
func menuBarLabelTracksProviderState() {
    let setup = ProviderMenuBarLabelPresentation(content: .setup)
    let online = ProviderMenuBarLabelPresentation(
        content: .provider(ProviderPreviewScenario.online.snapshot)
    )
    let serving = ProviderMenuBarLabelPresentation(
        content: .provider(ProviderPreviewScenario.serving.snapshot)
    )
    let attention = ProviderMenuBarLabelPresentation(
        content: .provider(ProviderPreviewScenario.attention.snapshot)
    )
    let stale = ProviderMenuBarLabelPresentation(
        content: .provider(ProviderPreviewScenario.stale.snapshot)
    )

    #expect([setup, online, serving, attention, stale].allSatisfy { $0.systemImage == "sparkle" })
    #expect(setup.accessibilityLabel == "Darkbloom, network setup required")
    #expect(online.accessibilityLabel == "Darkbloom network, Network provider running")
    #expect(attention.accessibilityLabel == "Darkbloom network, Network needs attention")
    #expect(stale.accessibilityLabel == "Darkbloom network, Sharing status unknown")
    #expect(serving.accessibilityLabel == "Darkbloom network, Handling requests")
}

@Test("Menu bar label represents transition states")
func menuBarLabelTracksTransitions() {
    var snapshot = ProviderPreviewScenario.online.snapshot

    snapshot.runState = .starting
    #expect(
        ProviderMenuBarLabelPresentation(content: .provider(snapshot)).accessibilityLabel
            == "Darkbloom network, Starting network provider"
    )

    snapshot.runState = .restarting
    #expect(
        ProviderMenuBarLabelPresentation(content: .provider(snapshot)).accessibilityLabel
            == "Darkbloom network, Restarting network provider"
    )
}
