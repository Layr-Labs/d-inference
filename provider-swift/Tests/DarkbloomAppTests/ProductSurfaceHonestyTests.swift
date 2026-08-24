import Testing
@testable import DarkbloomApp

@Suite("Live product surfaces do not advertise preview-only behavior")
struct ProductSurfaceHonestyTests {
    @Test("Preview chrome is opt-in")
    func previewChromeIsOptIn() {
        #expect(!PreviewChromePresentation.isVisible(
            hasOnboardingPreview: false,
            hasProductPreview: false
        ))
        #expect(PreviewChromePresentation.isVisible(
            hasOnboardingPreview: true,
            hasProductPreview: false
        ))
        #expect(PreviewChromePresentation.isVisible(
            hasOnboardingPreview: false,
            hasProductPreview: true
        ))
    }

    @Test("Local API copy distinguishes live credentials and endpoints")
    func localAPICopyDistinguishesLiveState() {
        #expect(
            LocalAPIPresentation.stateTitle(.starting, isLive: true)
                == "Endpoint is starting"
        )
        #expect(
            LocalAPIPresentation.stateTitle(.starting, isLive: false)
                == "Sample endpoint is starting"
        )
        #expect(LocalAPIPresentation.apiKeyLabel(isLive: true) == "API key")
        #expect(LocalAPIPresentation.apiKeyLabel(isLive: false) == "Sample API key")
        #expect(!LocalAPIPresentation.credentialsDetail(isLive: true).contains("preview"))
        #expect(LocalAPIPresentation.credentialsDetail(isLive: false).contains("preview"))
    }

    @Test("Live chat controls and messages describe real inference")
    func liveChatCopyDescribesRealInference() {
        let liveResponse = LocalChatMessage(
            role: .assistant,
            text: "Hello",
            isPreview: false
        )
        let previewResponse = LocalChatMessage(
            role: .assistant,
            text: "Hello",
            isPreview: true
        )
        let userMessage = LocalChatMessage(role: .user, text: "Hello")

        #expect(ChatPresentation.sendLabel(isLive: true) == "Send message")
        #expect(ChatPresentation.stopLabel(isLive: true) == "Stop response")
        #expect(
            ChatPresentation.messageLabel(liveResponse, isLive: true)
                == "Darkbloom response"
        )
        #expect(
            ChatPresentation.messageLabel(previewResponse, isLive: false)
                == "Simulated response"
        )
        #expect(
            ChatPresentation.messageLabel(userMessage, isLive: true)
                == "Your message"
        )
        #expect(
            ChatPresentation.messageLabel(userMessage, isLive: false)
                == "Your preview message"
        )
    }

    @Test("Unwired live actions are hidden or demoted to guidance")
    func liveActionsDoNotPromiseMutations() {
        #expect(!ModelLibraryPresentation.allowsTransientSelection(isLive: true))
        #expect(ModelLibraryPresentation.allowsTransientSelection(isLive: false))
        #expect(!ContributionsPresentation.allowsPayoutActions(isLive: true))
        #expect(ContributionsPresentation.allowsPayoutActions(isLive: false))
        #expect(
            DiagnosticFixAction.restartProvider.buttonTitle(isLive: true)
                == "View Guidance"
        )
        #expect(
            DiagnosticFixAction.restartProvider.buttonTitle(isLive: false)
                == "Restart"
        )
    }
}
