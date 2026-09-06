import SwiftUI

struct AvailabilityIdleUnloadSection: View {
    let policy: AvailabilityPolicy
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProductSectionHeader("Idle model unloading", detail: "Default · 60 minutes")
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    idleDescription
                    Spacer(minLength: 12)
                    editButton
                }
                VStack(alignment: .leading, spacing: 12) {
                    idleDescription
                    editButton
                }
            }
            .padding(.top, 12)
        }
    }

    private var idleDescription: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: policy.idleUnloadingIsDisabled ? "pin.fill" : "cube.transparent")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(DarkbloomTheme.accent)
                .frame(width: 25)
            VStack(alignment: .leading, spacing: 3) {
                Text(AvailabilityPresentation.idleUnloadTitle(policy.idleUnloadMinutes))
                    .font(.system(size: 13, weight: .medium))
                Text(AvailabilityPresentation.idleUnloadDetail(policy.idleUnloadMinutes))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 620, alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var editButton: some View {
        Button("Change…", action: onEdit)
            .buttonStyle(.bordered)
    }
}

struct AvailabilityInlineNotice: View {
    let title: String
    let detail: String
    let systemImage: String
    var tint = ProductPalette.warning
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 10)
            if let onDismiss {
                Button("Dismiss", systemImage: "xmark", action: onDismiss)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(tint.opacity(0.15), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}
