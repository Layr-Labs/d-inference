import SwiftUI

struct MyMacDetailSection<Content: View>: View {
    let title: String
    let detail: String?
    let content: Content

    init(_ title: String, detail: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                if let detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(.vertical, 4)
    }
}

struct MyMacFactRow: View {
    let label: String
    let value: String

    init(_ label: String, value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                factLabel.frame(width: 144, alignment: .leading)
                factValue
            }
            .frame(minWidth: 390)
            VStack(alignment: .leading, spacing: 4) {
                factLabel
                factValue
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var factLabel: some View {
        Text(label).font(.body).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var factValue: some View {
        Text(value).font(.body.weight(.medium))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MyMacStatusBadge: View {
    let mac: MyMac

    var body: some View {
        Label(
            MyMacsPresentation.lifecycleTitle(mac.lifecycle),
            systemImage: MyMacsPresentation.lifecycleSymbol(mac.lifecycle)
        )
        .font(.callout.weight(.semibold))
        .foregroundStyle(tint)
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tint.opacity(0.10), in: Capsule())
    }

    private var tint: Color {
        switch mac.lifecycle {
        case .serving: DarkbloomTheme.accent
        case .online: ProductPalette.positive
        case .untrusted: ProductPalette.critical
        case .offline, .neverSeen, .unknown: .secondary
        }
    }
}

struct MyMacNoticeList: View {
    let items: [MyMacAttentionItem]
    let emptyText: String
    let tint: Color

    var body: some View {
        if items.isEmpty {
            Label(emptyText, systemImage: "checkmark.circle")
                .font(.body).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(items) { item in
                    Label {
                        Text(MyMacsPresentation.attentionDescription(item.reason))
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: noticeSymbol(item.level))
                    }
                    .font(.body)
                    .foregroundStyle(tint)
                }
            }
        }
    }

    private func noticeSymbol(_ level: MyMacAttentionLevel) -> String {
        switch level {
        case .none: "info.circle"
        case .notice: "info.circle.fill"
        case .degraded: "exclamationmark.circle.fill"
        case .blocking: "exclamationmark.triangle.fill"
        }
    }
}
