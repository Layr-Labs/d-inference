import SwiftUI

struct AvailabilityScheduleSummarySection: View {
    let policy: AvailabilityPolicy
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProductSectionHeader(
                "Schedule",
                detail: AvailabilityPresentation.timeZoneTitle(policy.localTimeZone)
            )

            if policy.mode == .scheduled {
                VStack(spacing: 0) {
                    ForEach(Array(policy.windows.enumerated()), id: \.element.id) { index, window in
                        if index > 0 { Divider() }
                        scheduleRow(window)
                            .padding(.vertical, 12)
                    }
                }
                .padding(.top, 3)
            } else {
                Text("No schedule boundary is active. Darkbloom may connect whenever the provider process is running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 10)
            }

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Label("Follows this Mac’s current timezone", systemImage: "globe.americas.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Edit…", action: onEdit)
                    .buttonStyle(.link)
            }
            .padding(.top, 9)
        }
    }

    private func scheduleRow(_ window: AvailabilityWindow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: window.isOvernight ? "moon.stars.fill" : "sun.max.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(DarkbloomTheme.accent)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(AvailabilityPresentation.daySummary(window.days))
                    .font(.system(size: 13, weight: .medium))
                Text(
                    "\(AvailabilityPresentation.timeString(window.start, timeZone: policy.localTimeZone))–" +
                        AvailabilityPresentation.timeString(window.end, timeZone: policy.localTimeZone)
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            Spacer()
            if window.isOvernight, window.start != window.end {
                Text("OVERNIGHT")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.65)
                    .foregroundStyle(DarkbloomTheme.accent)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            AvailabilityPresentation.windowSummary(window, timeZone: policy.localTimeZone)
        )
    }
}

struct AvailabilityBehaviorSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProductSectionHeader("What this changes")
            VStack(spacing: 0) {
                behaviorRow(
                    icon: "network",
                    title: "Darkbloom network",
                    detail: "The provider connects to the private AI network only when this plan allows it."
                )
                Divider()
                behaviorRow(
                    icon: "point.3.connected.trianglepath.dotted",
                    title: "Unified Local API",
                    detail: "The endpoint follows the provider and is unavailable outside schedule windows.",
                    command: "darkbloom start --local-endpoint"
                )
                Divider()
                behaviorRow(
                    icon: "lock.laptopcomputer",
                    title: "Standalone Local API",
                    detail: "The local-only server is separate, so this plan does not control it. Darkbloom runs one provider mode at a time; stop network/unified mode before starting standalone local mode.",
                    command: "darkbloom start --local"
                )
            }
            .padding(.top, 3)
        }
    }

    private func behaviorRow(
        icon: String,
        title: String,
        detail: String,
        command: String? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(DarkbloomTheme.accent)
                .frame(width: 25)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let command {
                    Text(command)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(.top, 1)
                }
            }
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}
