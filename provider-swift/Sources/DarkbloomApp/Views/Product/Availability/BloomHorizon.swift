import SwiftUI

/// A semantic local-day view of the provider plan. Blue regions are elapsed
/// eligibility, pale regions are upcoming eligibility, and the seam is the
/// current local wall-clock time. It deliberately does not imply jobs or flow.
struct BloomHorizon: View {
    let policy: AvailabilityPolicy
    let runtime: AvailabilityRuntimeSnapshot?
    let now: Date

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var revealProgress: CGFloat = 0

    private var segments: [AvailabilityHorizonSegment] {
        AvailabilityPresentation.horizonSegments(for: policy, at: now)
    }

    private var currentMinute: Int {
        AvailabilityPresentation.minuteOfDay(at: now, timeZone: policy.localTimeZone)
    }

    private var isPaused: Bool {
        runtime?.state == .paused
    }

    private var isCurrentlyInsidePlan: Bool {
        segments.contains {
            $0.startMinute <= currentMinute && currentMinute < $0.endMinute
        }
    }

    private var liveTint: Color {
        isPaused ? Color.secondary : DarkbloomTheme.accent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 19) {
            horizonHeader
            horizon
            horizonLabels
            horizonLegend
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .background(horizonBackground)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(ProductPalette.stroke, lineWidth: 1)
        }
        .shadow(
            color: isPaused ? .clear : DarkbloomTheme.accent.opacity(0.08),
            radius: reduceTransparency ? 0 : 24,
            y: 12
        )
        .onAppear(perform: reveal)
        .onChange(of: reduceMotion) { _, _ in
            reveal()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Availability horizon, local 24-hour day")
        .accessibilityValue(
            AvailabilityPresentation.horizonAccessibilityValue(
                policy: policy,
                runtime: runtime,
                at: now
            )
        )
        .accessibilityHint("Blue regions are elapsed eligible time. Pale regions are upcoming eligible time. The seam marks the current local time.")
    }

    private var horizonHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                status
                Spacer(minLength: 10)
                transition
            }

            VStack(alignment: .leading, spacing: 5) {
                status
                transition
            }
        }
    }

    private var status: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Circle()
                .fill(statusTint)
                .frame(width: 8, height: 8)
                .shadow(
                    color: statusTint.opacity(reduceTransparency ? 0 : 0.35),
                    radius: reduceTransparency ? 0 : 5
                )

            Text(AvailabilityPresentation.runtimeTitle(runtime?.state))
                .font(.system(size: 13, weight: .semibold))

            Text("TODAY · 24 HOURS")
                .font(.caption2.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var transition: some View {
        if let detail = AvailabilityPresentation.nextPlannedBoundaryDetail(
            for: policy,
            after: now
        ) ?? AvailabilityPresentation.transitionDetail(
            runtime?.nextObservedTransitionAt,
            timeZone: policy.localTimeZone
        ) {
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        } else {
            Text(AvailabilityPresentation.scheduleSummary(policy))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var horizon: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let seamX = width * CGFloat(currentMinute) / 1_440

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.secondary.opacity(isPaused ? 0.08 : 0.065))
                    .overlay {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .stroke(Color.primary.opacity(0.055), lineWidth: 1)
                    }

                segmentLayer(width: width)
                    .mask(alignment: .leading) {
                        Rectangle()
                            .frame(width: width * revealProgress)
                    }

                horizonTicks(width: width)

                currentSeam
                    .position(x: seamX, y: proxy.size.height / 2)

                continuityMarks(width: width)
            }
        }
        .frame(height: 52)
    }

    private func segmentLayer(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            ForEach(segments) { segment in
                let start = width * CGFloat(segment.startFraction)
                let end = width * CGFloat(segment.endFraction)
                let segmentWidth = max(1, end - start)
                let elapsedEnd = min(segment.endMinute, currentMinute)
                let elapsedWidth = max(
                    0,
                    width * CGFloat(elapsedEnd - segment.startMinute) / 1_440
                )

                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(futureSegmentColor)
                    .frame(width: segmentWidth, height: 32)
                    .offset(x: start)

                if elapsedWidth > 0 {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(elapsedSegmentStyle)
                        .frame(width: elapsedWidth, height: 32)
                        .offset(x: start)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var elapsedSegmentStyle: LinearGradient {
        LinearGradient(
            colors: isPaused
                ? [Color.secondary.opacity(0.34), Color.secondary.opacity(0.22)]
                : [DarkbloomTheme.accent.opacity(0.93), DarkbloomTheme.accent.opacity(0.62)],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var futureSegmentColor: Color {
        isPaused
            ? Color.secondary.opacity(0.14)
            : DarkbloomTheme.nodePale.opacity(reduceTransparency ? 0.64 : 0.46)
    }

    private var currentSeam: some View {
        VStack(spacing: 0) {
            Circle()
                .fill(statusTint)
                .frame(width: 7, height: 7)
                .overlay {
                    Circle().stroke(ProductPalette.elevatedSurface, lineWidth: 2)
                }
            Rectangle()
                .fill(statusTint.opacity(0.82))
                .frame(width: 1, height: 38)
        }
        .frame(width: 12, height: 48)
        .shadow(
            color: statusTint.opacity(reduceTransparency ? 0 : 0.22),
            radius: reduceTransparency ? 0 : 5
        )
        .accessibilityHidden(true)
    }

    private func horizonTicks(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            ForEach(1 ..< 4, id: \.self) { index in
                Rectangle()
                    .fill(Color.primary.opacity(0.09))
                    .frame(width: 1, height: 12)
                    .offset(x: width * CGFloat(index) / 4)
            }
        }
        .accessibilityHidden(true)
    }

    private func continuityMarks(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            if segments.contains(where: \.continuesFromPreviousDay) {
                Image(systemName: "chevron.left.2")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(liveTint.opacity(0.72))
                    .offset(x: 5)
            }
            if segments.contains(where: \.continuesIntoNextDay) {
                Image(systemName: "chevron.right.2")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(futureSegmentColor)
                    .offset(x: max(0, width - 16))
            }
        }
        .accessibilityHidden(true)
    }

    private var horizonLabels: some View {
        HStack {
            Text("12 AM")
            Spacer()
            Text("6 AM")
            Spacer()
            Text("12 PM")
            Spacer()
            Text("6 PM")
            Spacer()
            Text("12 AM")
        }
        .font(.caption2.monospaced().weight(.medium))
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .accessibilityHidden(true)
    }

    private var horizonLegend: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) {
                legendItem("Eligible time elapsed", color: liveTint)
                legendItem("Eligible time ahead", color: futureSegmentColor)
                legendItem("Current time", color: statusTint, isSeam: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                legendItem("Eligible time elapsed", color: liveTint)
                legendItem("Eligible time ahead", color: futureSegmentColor)
                legendItem("Current time", color: statusTint, isSeam: true)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private func legendItem(
        _ title: String,
        color: Color,
        isSeam: Bool = false
    ) -> some View {
        HStack(spacing: 6) {
            if isSeam {
                Rectangle()
                    .fill(color)
                    .frame(width: 2, height: 11)
            } else {
                Capsule()
                    .fill(color)
                    .frame(width: 18, height: 6)
            }
            Text(title)
        }
    }

    private var statusTint: Color {
        switch runtime?.state {
        case .available, .serving:
            isCurrentlyInsidePlan ? DarkbloomTheme.accent : ProductPalette.warning
        case .paused, .stale, .scheduledOff, nil:
            Color.secondary
        case .attention:
            ProductPalette.warning
        case .starting, .stopping, .restarting:
            DarkbloomTheme.accent
        }
    }

    private var horizonBackground: some View {
        ZStack {
            ProductPalette.surface

            if !reduceTransparency {
                LinearGradient(
                    colors: isPaused
                        ? [Color.secondary.opacity(0.05), Color.clear]
                        : [DarkbloomTheme.nodePale.opacity(0.18), Color.clear],
                    startPoint: .topTrailing,
                    endPoint: .bottomLeading
                )

                RadialGradient(
                    colors: [
                        DarkbloomTheme.accent.opacity(isPaused ? 0.04 : 0.10),
                        Color.clear,
                    ],
                    center: .bottomLeading,
                    startRadius: 0,
                    endRadius: 420
                )
            }
        }
    }

    private func reveal() {
        if reduceMotion {
            revealProgress = 1
            return
        }

        revealProgress = 0
        withAnimation(.easeOut(duration: 0.72)) {
            revealProgress = 1
        }
    }
}
