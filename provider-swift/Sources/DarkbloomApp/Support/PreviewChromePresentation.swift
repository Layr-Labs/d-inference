enum PreviewChromePresentation {
    static func isVisible(
        hasOnboardingPreview: Bool,
        hasProductPreview: Bool
    ) -> Bool {
        hasOnboardingPreview || hasProductPreview
    }
}
