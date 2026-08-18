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

@Test("Menu bar label is monochrome-ready and changes with provider state")
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

    #expect(setup.systemImage == "circle.dashed")
    #expect(setup.accessibilityLabel == "Darkbloom, setup incomplete")
    #expect(online.systemImage == "checkmark.circle.fill")
    #expect(serving.systemImage == "waveform.path.ecg")
    #expect(attention.systemImage == "exclamationmark.triangle.fill")
    #expect(stale.systemImage == "exclamationmark.octagon.fill")
    #expect(serving.accessibilityLabel == "Darkbloom, Serving")
}

@Test("Menu bar label represents transition states")
func menuBarLabelTracksTransitions() {
    var snapshot = ProviderPreviewScenario.online.snapshot

    snapshot.runState = .starting
    #expect(
        ProviderMenuBarLabelPresentation(content: .provider(snapshot)).systemImage
            == "ellipsis.circle.fill"
    )

    snapshot.runState = .restarting
    #expect(
        ProviderMenuBarLabelPresentation(content: .provider(snapshot)).systemImage
            == "arrow.clockwise.circle.fill"
    )
}
