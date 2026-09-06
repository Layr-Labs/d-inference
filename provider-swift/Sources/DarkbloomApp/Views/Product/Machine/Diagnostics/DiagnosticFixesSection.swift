import SwiftUI

struct DiagnosticFixesSection: View {
    let fixes: [DiagnosticFix]
    let presentation: (DiagnosticFix) -> DiagnosticActionPresentation
    let onOpen: (DiagnosticFix) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProductSectionHeader("Recommended next steps", detail: "Highest impact first")

            VStack(spacing: 0) {
                ForEach(Array(fixes.enumerated()), id: \.element.id) { index, fix in
                    let action = presentation(fix)
                    HStack(spacing: 13) {
                        Text("\(index + 1)")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(width: 25, height: 25)
                            .background(fix.priority == .urgent ? ProductPalette.critical : DarkbloomTheme.accent, in: Circle())

                        VStack(alignment: .leading, spacing: 2) {
                            Text(fix.title)
                                .font(.system(size: 13, weight: .semibold))
                            Text(fix.detail)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            if let reason = action.disabledReason {
                                Text(reason)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        if index == 0 {
                            Button(action.title) {
                                onOpen(fix)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!action.isEnabled)
                        } else {
                            Button(action.title) {
                                onOpen(fix)
                            }
                            .buttonStyle(.bordered)
                            .disabled(!action.isEnabled)
                        }
                    }
                    .padding(15)

                    if index < fixes.count - 1 {
                        Divider().padding(.leading, 52)
                    }
                }
            }
            .productSurface()
        }
    }
}
