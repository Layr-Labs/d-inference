import SwiftUI

struct EnrollmentInstructionsView: View {
    let phase: EnrollmentPhase

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Rectangle()
                .fill(DarkbloomTheme.ink.opacity(0.09))
                .frame(height: 1)
                .padding(.vertical, 15)

            if phase == .profileDetected {
                detectedLedger
            } else if isFailure {
                failureLedger
            } else {
                instructionList
                Spacer(minLength: 10)
                installationLedger
            }
        }
        .padding(24)
        .frame(width: 390, height: 420, alignment: .topLeading)
        .onboardingPanel()
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("SYSTEM SETTINGS")
                    .font(DarkbloomTheme.chivo(9, weight: .medium))
                    .tracking(1)
                Text(headerDetail)
                    .font(DarkbloomTheme.chivo(10))
                    .foregroundStyle(DarkbloomTheme.ink.opacity(0.44))
            }
            Spacer()
            statusSymbol
        }
    }

    @ViewBuilder
    private var statusSymbol: some View {
        if phase == .profileDetected {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(DarkbloomTheme.accent)
        } else if phase == .detectingProfile {
            BreathingStatusDot().frame(width: 20, height: 20)
        } else if isFailure {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.orange)
        }
    }

    private var instructionList: some View {
        VStack(spacing: 11) {
            ForEach(Array(EnrollmentGuide.instructions.enumerated()), id: \.element.id) { index, step in
                InstructionRow(number: index + 1, title: step.title, detail: step.detail)
            }
        }
    }

    private var installationLedger: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(DarkbloomTheme.ink.opacity(0.07))
                .frame(height: 1)
                .padding(.bottom, 7)
            SetupStatusRow(title: "Profile downloaded", detail: EnrollmentGuide.profileName, state: .complete)
            SetupStatusRow(
                title: "Administrator authentication",
                detail: phase == .detectingProfile ? "Approved; checking profile" : "Finish in System Settings",
                state: phase == .detectingProfile ? .complete : .working
            )
            SetupStatusRow(
                title: "Profile detected",
                detail: phase == .detectingProfile ? "Checking this Mac" : "Waiting for installation",
                state: phase == .detectingProfile ? .working : .waiting
            )
        }
    }

    private var detectedLedger: some View {
        VStack(spacing: 4) {
            SetupStatusRow(title: "Profile downloaded", detail: EnrollmentGuide.profileName, state: .complete)
            SetupStatusRow(title: "Administrator authentication", detail: "Approved in System Settings", state: .complete)
            SetupStatusRow(title: "Profile detected", detail: "Installed on this Mac", state: .complete)
            SetupStatusRow(title: "Enrollment check-in", detail: "Verified separately in the next step", state: .waiting)
            Text("Local profile presence does not yet mean Darkbloom has completed MDM check-in or hardware trust.")
                .font(DarkbloomTheme.chivo(9))
                .lineSpacing(2)
                .foregroundStyle(DarkbloomTheme.ink.opacity(0.4))
                .padding(.top, 7)
        }
    }

    private var failureLedger: some View {
        VStack(alignment: .leading, spacing: 4) {
            SetupStatusRow(title: "Profile downloaded", detail: EnrollmentGuide.profileName, state: .complete)
            SetupStatusRow(title: failureTitle, detail: failureDetail, state: .issue)
            SetupStatusRow(title: "Hardware trust", detail: "Waiting for enrollment recovery", state: .waiting)

            Text(failureGuidance)
                .font(DarkbloomTheme.chivo(11))
                .lineSpacing(3)
                .foregroundStyle(DarkbloomTheme.ink.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
        }
    }

    private var isFailure: Bool {
        phase == .profileMissing || phase == .conflictingManagement || phase == .enrollmentFailed
    }

    private var headerDetail: String {
        switch phase {
        case .profileDetected: "Profile detected locally"
        case .profileMissing: "Profile not found"
        case .conflictingManagement: "Existing MDM enrollment found"
        case .enrollmentFailed: "Local profile check needs recovery"
        default: "General  ›  Device Management"
        }
    }

    private var failureTitle: String {
        switch phase {
        case .profileMissing: "Profile not detected"
        case .conflictingManagement: "Conflicting MDM enrollment"
        default: "Profile check failed"
        }
    }

    private var failureDetail: String {
        switch phase {
        case .profileMissing: "Reopen System Settings or download again"
        case .conflictingManagement: "macOS supports one MDM enrollment"
        default: "Check the profile again or reinstall"
        }
    }

    private var failureGuidance: String {
        switch phase {
        case .conflictingManagement:
            "A work or school profile may be intentional. Contact its administrator before removing it."
        case .profileMissing:
            "If the Darkbloom profile is not listed, download it again and repeat administrator approval."
        default:
            "Keep Darkbloom open, verify the profile remains installed, then run the system check again."
        }
    }
}

private struct InstructionRow: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(DarkbloomTheme.chivo(10, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(DarkbloomTheme.accent, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(DarkbloomTheme.chivo(12, weight: .medium))
                Text(detail)
                    .font(DarkbloomTheme.chivo(11))
                    .lineSpacing(2)
                    .foregroundStyle(DarkbloomTheme.ink.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}
