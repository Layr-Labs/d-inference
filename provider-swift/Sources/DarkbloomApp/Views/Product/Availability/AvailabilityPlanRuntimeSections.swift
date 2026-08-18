import SwiftUI

struct AvailabilityPlanSection: View {
    let policy: AvailabilityPolicy
    let onSelectMode: (AvailabilityPolicyMode) -> Void
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProductSectionHeader(
                "Availability plan",
                detail: "Changes require a provider restart"
            )

            VStack(spacing: 0) {
                ForEach(Array(AvailabilityPolicyMode.allCases.enumerated()), id: \.element) { index, mode in
                    if index > 0 { Divider() }
                    PlanOptionRow(
                        title: AvailabilityPresentation.planTitle(mode),
                        detail: AvailabilityPresentation.planDetail(mode),
                        isSelected: policy.mode == mode,
                        action: { onSelectMode(mode) }
                    )
                    .padding(.vertical, 14)
                }
            }
            .padding(.horizontal, 2)

            HStack(spacing: 12) {
                if policy.mode == .scheduled {
                    Label(
                        AvailabilityPresentation.scheduleSummary(policy),
                        systemImage: "calendar.badge.clock"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                }
                Spacer()
                Button(policy.mode == .scheduled ? "Edit Schedule…" : "Edit Plan…", action: onEdit)
                    .buttonStyle(.bordered)
            }
            .padding(.top, 5)
        }
    }
}

private struct PlanOptionRow: View {
    let title: String
    let detail: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(isSelected ? DarkbloomTheme.accent : Color.secondary)
                    .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 16)
                if isSelected {
                    Text("CURRENT")
                        .font(.caption2.weight(.semibold))
                        .tracking(0.7)
                        .foregroundStyle(DarkbloomTheme.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? "Current plan" : "Not selected")
        .accessibilityHint(isSelected ? "Opens the plan editor" : "Selects this plan and opens the editor")
    }
}

struct AvailabilityRuntimeControlSection: View {
    let policy: AvailabilityPolicy
    let runtime: AvailabilityRuntimeSnapshot?
    let providerSnapshot: ProviderSnapshot
    let onRequestProviderAction: (ProviderAction) -> Void
    let onRunSystemCheck: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProductSectionHeader("Current provider")
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 16) {
                    runtimeLabel
                    Spacer(minLength: 12)
                    controls
                }
                VStack(alignment: .leading, spacing: 13) {
                    runtimeLabel
                    controls
                }
            }
            .padding(.top, 13)
        }
    }

    private var runtimeLabel: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: runtimeSymbol)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(runtimeTint)
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 3) {
                Text(AvailabilityPresentation.runtimeTitle(runtime?.state))
                    .font(.system(size: 13, weight: .semibold))
                Text(AvailabilityPresentation.runtimeDetail(runtime?.state, policy: policy))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 510, alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            if let action = providerAction {
                Button(action.title, systemImage: action.systemImage) {
                    onRequestProviderAction(action.action)
                }
                .buttonStyle(.bordered)
                .disabled(providerSnapshot.runState.isTransitioning)
            } else if runtime?.state == .scheduledOff {
                Label("Returns automatically", systemImage: "clock.arrow.circlepath")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("No manual action. The provider returns automatically at the next schedule window.")
            }

            Button("System Check", systemImage: "stethoscope", action: onRunSystemCheck)
                .buttonStyle(.link)
        }
    }

    private var providerAction: (title: String, systemImage: String, action: ProviderAction)? {
        switch runtime?.state {
        case .paused: ("Resume", "play.fill", .start)
        case .available, .serving, .attention: ("Pause", "pause.fill", .stop)
        case .stale: ("Restart", "arrow.clockwise", .restart)
        case .scheduledOff, .starting, .stopping, .restarting, nil: nil
        }
    }

    private var runtimeSymbol: String {
        switch runtime?.state {
        case .available: "checkmark.circle.fill"
        case .serving: "sparkles"
        case .paused: "pause.circle.fill"
        case .scheduledOff: "moon.zzz.fill"
        case .attention: "exclamationmark.triangle.fill"
        case .stale: "clock.badge.exclamationmark"
        case .starting, .stopping, .restarting: "arrow.triangle.2.circlepath"
        case nil: "questionmark.circle"
        }
    }

    private var runtimeTint: Color {
        switch runtime?.state {
        case .available, .serving: DarkbloomTheme.accent
        case .attention: ProductPalette.warning
        case .paused, .scheduledOff, .stale, .starting, .stopping, .restarting, nil: .secondary
        }
    }
}
