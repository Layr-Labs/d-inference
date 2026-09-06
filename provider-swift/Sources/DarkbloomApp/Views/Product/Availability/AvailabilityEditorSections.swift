import SwiftUI

struct AvailabilityEditorPlanSection: View {
    let store: AvailabilityStore
    let policy: AvailabilityPolicy

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            AvailabilityEditorSectionHeader(
                title: "Availability plan",
                detail: "Network provider policy"
            )

            Picker("Availability plan", selection: modeBinding) {
                ForEach(AvailabilityPolicyMode.allCases, id: \.self) { mode in
                    Text(AvailabilityPresentation.planTitle(mode))
                        .tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            Text(AvailabilityPresentation.planDetail(policy.mode))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var modeBinding: Binding<AvailabilityPolicyMode> {
        Binding(
            get: { policy.mode },
            set: { store.setMode($0) }
        )
    }
}

struct AvailabilityEditorIdleUnloadSection: View {
    let store: AvailabilityStore
    let policy: AvailabilityPolicy

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            AvailabilityEditorSectionHeader(
                title: "Idle model unloading",
                detail: "Default · 60 minutes"
            )

            Stepper(value: idleMinutesBinding, in: 0 ... 1_440, step: 15) {
                LabeledContent("Unload a model") {
                    Text(AvailabilityPresentation.idleUnloadTitle(policy.idleUnloadMinutes))
                        .font(.system(.body, design: .rounded).weight(.medium))
                        .monospacedDigit()
                }
            }

            Text(AvailabilityPresentation.idleUnloadDetail(policy.idleUnloadMinutes))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if policy.idleUnloadMinutes == AvailabilityPolicy.defaultIdleUnloadMinutes {
                Label("Using the Darkbloom default", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(ProductPalette.positive)
            } else if policy.idleUnloadingIsDisabled {
                Label("0 disables idle model unloading", systemImage: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(DarkbloomTheme.accent)
            }
        }
    }

    private var idleMinutesBinding: Binding<Int> {
        Binding(
            get: { policy.idleUnloadMinutes },
            set: { store.setIdleUnloadMinutes($0) }
        )
    }
}

struct AvailabilityEditorValidationSection: View {
    let store: AvailabilityStore
    let policy: AvailabilityPolicy

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !globalIssues.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(globalIssues.enumerated()), id: \.offset) { _, issue in
                        Label(
                            AvailabilityPresentation.validationMessage(issue, policy: policy),
                            systemImage: "exclamationmark.circle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(ProductPalette.critical)
                    }
                }
                .padding(.top, 18)
            }

            saveNotice
        }
    }

    private var globalIssues: [AvailabilityPolicyValidationIssue] {
        policy.validation.issues.filter { issue in
            switch issue {
            case .scheduleHasNoWindows, .invalidIdleUnloadMinutes: true
            case .windowHasNoDays, .windowHasEqualStartAndEnd, .windowsOverlapOrTouch: false
            }
        }
    }

    @ViewBuilder
    private var saveNotice: some View {
        switch store.saveState {
        case .failed(let message):
            AvailabilityInlineNotice(
                title: "Save failed",
                detail: store.isLive
                    ? message
                    : "\(message) No provider configuration or process changed.",
                systemImage: "exclamationmark.triangle.fill",
                tint: ProductPalette.critical
            )
            .padding(.top, 18)

        case .validationFailed(let issues):
            AvailabilityInlineNotice(
                title: "Review the schedule",
                detail: issues
                    .map { AvailabilityPresentation.validationMessage($0, policy: policy) }
                    .joined(separator: " "),
                systemImage: "exclamationmark.circle.fill",
                tint: ProductPalette.critical
            )
            .padding(.top, 18)

        case .idle, .saving, .savedAndRestarted, .savedRequiresRestart:
            EmptyView()
        }
    }
}

struct AvailabilityEditorSectionHeader: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
