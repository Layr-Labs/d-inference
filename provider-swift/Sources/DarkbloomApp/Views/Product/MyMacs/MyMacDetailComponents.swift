import SwiftUI

struct MyMacDetailSection<Content: View>: View {
    let title: String
    let detail: String?
    let content: Content

    init(
        _ title: String,
        detail: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProductSectionHeader(title, detail: detail)
            content
        }
        .padding(.vertical, 4)
    }
}

struct MyMacFactRow<Trailing: View>: View {
    let label: String
    let value: String
    let isPrivacySensitive: Bool
    let trailing: Trailing

    init(
        _ label: String,
        value: String,
        isPrivacySensitive: Bool = false,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.label = label
        self.value = value
        self.isPrivacySensitive = isPrivacySensitive
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 132, alignment: .leading)

            Text(value)
                .font(.caption.weight(.medium))
                .textSelection(.enabled)
                .privacySensitive(isPrivacySensitive)
                .frame(maxWidth: .infinity, alignment: .leading)

            trailing
        }
    }
}

extension MyMacFactRow where Trailing == EmptyView {
    init(_ label: String, value: String) {
        self.init(label, value: value, isPrivacySensitive: false) { EmptyView() }
    }
}

struct MyMacStatusBadge: View {
    let mac: MyMac

    var body: some View {
        Label(
            MyMacsPresentation.lifecycleTitle(mac.lifecycle),
            systemImage: MyMacsPresentation.lifecycleSymbol(mac.lifecycle)
        )
        .font(.caption2.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(tint.opacity(0.10), in: Capsule())
        .overlay {
            Capsule().stroke(tint.opacity(0.18), lineWidth: 1)
        }
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
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(items) { item in
                    Label {
                        Text(MyMacsPresentation.attentionDescription(item.reason))
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: noticeSymbol(item.level))
                    }
                    .font(.caption)
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
