import SwiftUI

struct ContributionPulseView: View {
    let preview: ContributionPulsePreview

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathes = false

    private var points: [ContributionPulsePreviewPoint] {
        preview.points
    }

    private var maximum: Int64 {
        max(1, points.map(\.amount.rawValue).max() ?? 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProductSectionHeader(
                "Sample contribution pulse",
                detail: "UI preview · 7 days"
            )

            chart
                .frame(height: 150)
                .padding(.top, 16)

            dayLabels
                .padding(.top, 7)
        }
        .padding(18)
        .productSurface()
        .onAppear {
            breathes = !reduceMotion
        }
        .onChange(of: reduceMotion) { _, isReduced in
            breathes = !isReduced
        }
        .accessibilityElement(children: .contain)
    }

    private var chart: some View {
        GeometryReader { proxy in
            let samples = chartSamples(in: proxy.size)

            ZStack {
                Canvas { context, size in
                    guard !samples.isEmpty else { return }
                    drawGuides(in: &context, size: size)
                    drawArea(samples: samples, size: size, in: &context)
                    drawLine(samples: samples, in: &context)
                }

                ForEach(samples) { sample in
                    Circle()
                        .fill(sample.isLatest ? DarkbloomTheme.accent : ProductPalette.elevatedSurface)
                        .frame(width: sample.isLatest ? 8 : 6, height: sample.isLatest ? 8 : 6)
                        .overlay {
                            Circle()
                                .stroke(DarkbloomTheme.accent.opacity(sample.isLatest ? 1 : 0.58), lineWidth: 1.5)
                        }
                        .position(sample.position)
                        .accessibilityLabel(sample.point.date.formatted(date: .abbreviated, time: .omitted))
                        .accessibilityValue(
                            "\(ContributionsPresentation.amount(sample.point.amount)), " +
                                "\(sample.point.jobs.formatted()) jobs"
                        )

                    if sample.isLatest {
                        Circle()
                            .stroke(DarkbloomTheme.accent.opacity(0.24), lineWidth: 1)
                            .frame(width: 20, height: 20)
                            .scaleEffect(reduceMotion ? 1 : (breathes ? 1.38 : 0.72))
                            .opacity(reduceMotion ? 0.45 : (breathes ? 0 : 0.62))
                            .position(sample.position)
                            .animation(
                                reduceMotion
                                    ? nil
                                    : .easeInOut(duration: 1.9).repeatForever(autoreverses: false),
                                value: breathes
                            )
                            .accessibilityHidden(true)
                    }
                }
            }
        }
    }

    private var dayLabels: some View {
        HStack {
            ForEach(points) { point in
                Text(point.date.formatted(.dateTime.weekday(.narrow)))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }

    private func chartSamples(in size: CGSize) -> [ChartSample] {
        guard !points.isEmpty else { return [] }
        let horizontalInset: CGFloat = 8
        let verticalInset: CGFloat = 9
        let width = max(0, size.width - horizontalInset * 2)
        let height = max(0, size.height - verticalInset * 2)
        let denominator = max(1, points.count - 1)

        return points.enumerated().map { index, point in
            let x = horizontalInset + width * CGFloat(index) / CGFloat(denominator)
            let fraction = CGFloat(point.amount.rawValue) / CGFloat(maximum)
            let y = verticalInset + height * (1 - max(0, min(1, fraction)))
            return ChartSample(
                index: index,
                point: point,
                position: CGPoint(x: x, y: y),
                isLatest: index == points.count - 1
            )
        }
    }

    private func drawGuides(in context: inout GraphicsContext, size: CGSize) {
        for fraction in [0.25, 0.5, 0.75] {
            var guide = Path()
            guide.move(to: CGPoint(x: 0, y: size.height * fraction))
            guide.addLine(to: CGPoint(x: size.width, y: size.height * fraction))
            context.stroke(guide, with: .color(ProductPalette.stroke), lineWidth: 1)
        }
    }

    private func drawLine(samples: [ChartSample], in context: inout GraphicsContext) {
        guard !samples.isEmpty else { return }
        let path = smoothPath(samples)
        context.stroke(
            path,
            with: .linearGradient(
                Gradient(colors: [DarkbloomTheme.nodePale, DarkbloomTheme.accent]),
                startPoint: samples.first?.position ?? .zero,
                endPoint: samples.last?.position ?? .zero
            ),
            style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
        )
    }

    private func drawArea(
        samples: [ChartSample],
        size: CGSize,
        in context: inout GraphicsContext
    ) {
        guard let first = samples.first, let last = samples.last else { return }
        var path = Path()
        path.move(to: CGPoint(x: first.position.x, y: size.height))
        path.addLine(to: first.position)
        for pair in zip(samples, samples.dropFirst()) {
            let midpoint = (pair.0.position.x + pair.1.position.x) / 2
            path.addCurve(
                to: pair.1.position,
                control1: CGPoint(x: midpoint, y: pair.0.position.y),
                control2: CGPoint(x: midpoint, y: pair.1.position.y)
            )
        }
        path.addLine(to: CGPoint(x: last.position.x, y: size.height))
        path.closeSubpath()

        context.fill(
            path,
            with: .linearGradient(
                Gradient(colors: [
                    DarkbloomTheme.accent.opacity(0.20),
                    DarkbloomTheme.nodePale.opacity(0.025),
                ]),
                startPoint: CGPoint(x: size.width / 2, y: 0),
                endPoint: CGPoint(x: size.width / 2, y: size.height)
            )
        )
    }

    private func smoothPath(_ samples: [ChartSample]) -> Path {
        var path = Path()
        guard let first = samples.first else { return path }
        path.move(to: first.position)

        for pair in zip(samples, samples.dropFirst()) {
            let midpoint = (pair.0.position.x + pair.1.position.x) / 2
            path.addCurve(
                to: pair.1.position,
                control1: CGPoint(x: midpoint, y: pair.0.position.y),
                control2: CGPoint(x: midpoint, y: pair.1.position.y)
            )
        }
        return path
    }
}

private struct ChartSample: Identifiable {
    let index: Int
    let point: ContributionPulsePreviewPoint
    let position: CGPoint
    let isLatest: Bool

    var id: Int { index }
}
