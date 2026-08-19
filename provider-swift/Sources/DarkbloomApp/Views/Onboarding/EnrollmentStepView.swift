import SwiftUI

struct EnrollmentStepView: View {
    let flow: OnboardingFlowModel
    let isCompact: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        OnboardingStageScaffold(
            step: .enrollment,
            title: title,
            message: message,
            isCompact: isCompact
        ) {
            VStack(alignment: .leading, spacing: 12) {
                actions

                if flow.enrollmentPhase == .overview {
                    privacyDisclosure
                } else {
                    Text(footnote)
                        .font(DarkbloomTheme.chivo(11))
                        .lineSpacing(3)
                        .foregroundStyle(DarkbloomTheme.ink.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } visual: {
            EnrollmentSurface(flow: flow)
        }
    }

    private var title: String {
        switch flow.enrollmentPhase {
        case .overview: "Verify\nthis Mac."
        case .instructions, .systemSettingsOpen, .detectingProfile, .requestingProfile: "Finish in\nSystem Settings."
        case .profileDetected: "Profile\ndetected."
        case .profileMissing: "Profile not\nfound."
        case .conflictingManagement: "Management\nconflict."
        case .enrollmentFailed: "Profile check needs\nattention."
        }
    }

    private var message: String {
        switch flow.enrollmentPhase {
        case .overview:
            "Darkbloom uses a read-only management profile to verify Apple hardware and system security. It cannot erase, lock, install apps, or change settings."
        case .instructions, .systemSettingsOpen, .detectingProfile, .requestingProfile:
            "macOS requires you to click Install and approve the profile with an administrator password. Darkbloom cannot perform either action for you."
        case .profileDetected:
            "The profile is present on this Mac. Enrollment check-in and hardware trust are verified separately in the next step."
        case .profileMissing:
            "Darkbloom could not find the profile locally. Reopen System Settings, or download the profile again if it is no longer listed."
        case .conflictingManagement:
            "This Mac appears to be managed by another MDM service. Do not remove an organization’s profile without its administrator’s approval."
        case .enrollmentFailed:
            "The local profile check did not complete. Check again, or reinstall the profile if it is no longer valid."
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch flow.enrollmentPhase {
        case .overview:
            OnboardingPrimaryButton(title: "Install verification profile", systemImage: "arrow.right") {
                Task { await flow.beginEnrollment() }
            }
            .keyboardShortcut(.defaultAction)
        case .instructions:
            OnboardingPrimaryButton(
                title: flow.usesLiveEnrollment ? "Open verification profile" : "Preview System Settings step",
                systemImage: "arrow.up.right"
            ) {
                Task { await flow.beginEnrollment() }
            }
            .keyboardShortcut(.defaultAction)
        case .requestingProfile:
            OnboardingPrimaryButton(title: "Preparing the profile…", isWorking: true, isDisabled: true, action: {})
        case .systemSettingsOpen:
            OnboardingPrimaryButton(title: "Check for installed profile", systemImage: "arrow.clockwise") {
                Task { await flow.confirmProfileInstallation() }
            }
            .keyboardShortcut(.defaultAction)
        case .detectingProfile:
            OnboardingPrimaryButton(title: "Detecting the profile…", isWorking: true, isDisabled: true, action: {})
        case .profileDetected:
            OnboardingPrimaryButton(title: "Continue", systemImage: "arrow.right") {
                flow.continueToNextStep()
            }
            .keyboardShortcut(.defaultAction)
        case .profileMissing:
            recoveryActions(primaryTitle: "Retry profile detection", primarySymbol: "arrow.clockwise") {
                Task { await flow.retryProfileDetection() }
            }
        case .conflictingManagement:
            OnboardingPrimaryButton(title: "Reopen System Settings", systemImage: "gear") {
                flow.reopenSystemSettings()
            }
            .keyboardShortcut(.defaultAction)
        case .enrollmentFailed:
            recoveryActions(primaryTitle: "Try enrollment again", primarySymbol: "arrow.clockwise") {
                Task { await flow.beginEnrollment() }
            }
        }
    }

    private func recoveryActions(
        primaryTitle: String,
        primarySymbol: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            OnboardingPrimaryButton(title: primaryTitle, systemImage: primarySymbol, action: action)
                .keyboardShortcut(.defaultAction)
            HStack(spacing: 16) {
                OnboardingQuietButton(title: "Reopen System Settings", systemImage: "gear") {
                    flow.reopenSystemSettings()
                }
                OnboardingQuietButton(title: "Download profile again", systemImage: "arrow.down.circle") {
                    flow.downloadProfileAgain()
                }
            }
        }
    }

    private var privacyDisclosure: some View {
        VStack(alignment: .leading, spacing: 0) {
            OnboardingQuietButton(
                title: flow.showsProfilePrivacyDetails ? "Hide details" : "Why is this required?",
                systemImage: flow.showsProfilePrivacyDetails ? "chevron.up" : "chevron.down"
            ) {
                if reduceMotion {
                    flow.showsProfilePrivacyDetails.toggle()
                } else {
                    withAnimation(.easeOut(duration: 0.24)) { flow.showsProfilePrivacyDetails.toggle() }
                }
            }

            if flow.showsProfilePrivacyDetails {
                Text("The network only accepts hardware it can verify. The profile supplies read-only security facts; it never sees prompts, files, or model output.")
                    .font(DarkbloomTheme.chivo(11))
                    .lineSpacing(3)
                    .foregroundStyle(DarkbloomTheme.ink.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private var footnote: String {
        switch flow.enrollmentPhase {
        case .instructions, .systemSettingsOpen, .detectingProfile, .requestingProfile:
            flow.usesLiveEnrollment
                ? "Required macOS step: click Install in System Settings and enter an administrator password. Keep Darkbloom open while it detects the real profile."
                : "Administrator authentication happens in System Settings—not inside Darkbloom. Fixture preview only."
        case .conflictingManagement:
            "This flow remains blocked while another MDM is active. If this is a work or school Mac, contact its administrator before changing management profiles."
        default:
            flow.usesLiveEnrollment
                ? (flow.enrollmentFailureDetail ?? "Darkbloom verifies local profile and server enrollment evidence independently.")
                : "Fixture preview · live setup verifies local profile and server enrollment independently."
        }
    }
}

private struct EnrollmentSurface: View {
    let flow: OnboardingFlowModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if flow.enrollmentPhase == .overview {
                EnrollmentRightsView()
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
            } else {
                EnrollmentInstructionsView(phase: flow.enrollmentPhase)
                    .transition(.opacity.combined(with: .scale(scale: 1.015)))
            }
        }
        .animation(
            reduceMotion ? nil : .spring(response: 0.72, dampingFraction: 0.82),
            value: flow.enrollmentPhase
        )
    }
}
