import SwiftUI

struct ProductPage<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: 980, alignment: .leading)
                .padding(.horizontal, 34)
                .padding(.top, 30)
                .padding(.bottom, 44)
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(ProductPalette.pageBackground)
    }
}

struct ProductPageHeader<Trailing: View>: View {
    let eyebrow: String?
    let title: String
    let subtitle: String
    let trailing: Trailing

    init(
        eyebrow: String? = nil,
        title: String,
        subtitle: String,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.eyebrow = eyebrow
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                if let eyebrow {
                    Text(eyebrow.uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(1.1)
                        .foregroundStyle(DarkbloomTheme.accent)
                }

                Text(title)
                    .font(DarkbloomTheme.chivo(30))
                    .tracking(-0.8)
                    .accessibilityAddTraits(.isHeader)

                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 580, alignment: .leading)
            }

            Spacer(minLength: 12)
            trailing
        }
    }
}

extension ProductPageHeader where Trailing == EmptyView {
    init(eyebrow: String? = nil, title: String, subtitle: String) {
        self.init(eyebrow: eyebrow, title: title, subtitle: subtitle) {
            EmptyView()
        }
    }
}

struct ProductSectionHeader: View {
    let title: String
    let detail: String?

    init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct ProductMetricTile: View {
    let label: String
    let value: String
    let detail: String?
    var tint = DarkbloomTheme.accent

    init(label: String, value: String, detail: String? = nil, tint: Color = DarkbloomTheme.accent) {
        self.label = label
        self.value = value
        self.detail = detail
        self.tint = tint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
                Text(label.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
            }

            Text(value)
                .font(.system(size: 24, weight: .medium, design: .rounded))
                .monospacedDigit()
                .tracking(-0.5)
                .padding(.top, 12)

            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .padding(16)
        .productSurface()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue([value, detail].compactMap { $0 }.joined(separator: ", "))
    }
}

struct ProductStatusBadge: View {
    let title: String
    let systemImage: String
    var tint = DarkbloomTheme.accent

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tint.opacity(0.10), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(tint.opacity(0.18), lineWidth: 1)
            }
            .accessibilityElement(children: .combine)
    }
}

struct ProductDisclosureRow: View {
    let icon: String
    let title: String
    let detail: String
    var tint = DarkbloomTheme.accent
    var showsChevron = true

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 29, height: 29)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct ProductSurfaceModifier: ViewModifier {
    let padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(ProductPalette.surface)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(ProductPalette.stroke, lineWidth: 1)
                    }
            }
    }
}

extension View {
    func productSurface(padding: CGFloat = 0) -> some View {
        modifier(ProductSurfaceModifier(padding: padding))
    }
}

enum ProductPalette {
    static let pageBackground = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor).opacity(0.82)
    static let elevatedSurface = Color(nsColor: .textBackgroundColor)
    static let stroke = Color.primary.opacity(0.075)
    static let positive = adaptiveColor(
        light: NSColor(srgbRed: 0.02, green: 0.39, blue: 0.23, alpha: 1),
        dark: NSColor(srgbRed: 0.34, green: 0.86, blue: 0.60, alpha: 1)
    )
    static let warning = adaptiveColor(
        light: NSColor(srgbRed: 0.59, green: 0.30, blue: 0.01, alpha: 1),
        dark: NSColor(srgbRed: 1.00, green: 0.70, blue: 0.28, alpha: 1)
    )
    static let critical = adaptiveColor(
        light: NSColor(srgbRed: 0.72, green: 0.08, blue: 0.08, alpha: 1),
        dark: NSColor(srgbRed: 1.00, green: 0.48, blue: 0.46, alpha: 1)
    )

    private static func adaptiveColor(light: NSColor, dark: NSColor) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? dark
                    : light
            }
        )
    }
}
