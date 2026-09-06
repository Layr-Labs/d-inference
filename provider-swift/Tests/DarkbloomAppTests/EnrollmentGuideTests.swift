import Testing
@testable import DarkbloomApp

@Test("Enrollment guidance preserves the required System Settings sequence")
func enrollmentInstructionsStayOrdered() {
    #expect(EnrollmentGuide.instructions.map(\.id) == [
        "select-profile",
        "install-profile",
        "confirm-install",
        "administrator-approval",
    ])
}

@Test("Enrollment copy names the profile and administrator approval")
func enrollmentCopyIsExplicit() {
    #expect(EnrollmentGuide.profileName == "Darkbloom Provider Enrollment")
    #expect(EnrollmentGuide.administratorApprovalNote.localizedCaseInsensitiveContains("administrator"))
    #expect(EnrollmentGuide.administratorApprovalNote.localizedCaseInsensitiveContains("return"))
    #expect(!EnrollmentGuide.administratorApprovalNote.localizedCaseInsensitiveContains("Touch ID"))
}

@Test("Every UI capture scenario resolves deterministically")
func previewScenariosResolve() {
    let scenarios = [
        "check-running",
        "check-ready",
        "connect",
        "mdm-overview",
        "mdm-instructions",
        "mdm-waiting",
        "preparing",
        "verifying",
        "ready",
    ]

    for scenario in scenarios {
        #expect(OnboardingPreviewConfiguration.scenarioConfiguration(scenario) != nil)
    }
    #expect(OnboardingPreviewConfiguration.scenarioConfiguration("not-a-state") == nil)
}
