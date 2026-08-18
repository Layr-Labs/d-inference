import SwiftUI

struct OnboardingStageScaffold<Detail: View, Visual: View>: View {
    let step: OnboardingStep
    let title: String
    let message: String
    let isCompact: Bool
    let detail: Detail
    let visual: Visual

    init(
        step: OnboardingStep,
        title: String? = nil,
        message: String? = nil,
        isCompact: Bool,
        @ViewBuilder detail: () -> Detail,
        @ViewBuilder visual: () -> Visual
    ) {
        self.step = step
        self.title = title ?? step.title
        self.message = message ?? step.message
        self.isCompact = isCompact
        self.detail = detail()
        self.visual = visual()
    }

    var body: some View {
        HStack(alignment: .center, spacing: isCompact ? 24 : 40) {
            VStack(alignment: .leading, spacing: 0) {
                Text(step.eyebrow)
                    .font(DarkbloomTheme.chivo(10, weight: .medium))
                    .tracking(1.25)
                    .foregroundStyle(DarkbloomTheme.accent)

                Text(title)
                    .font(DarkbloomTheme.chivo(isCompact ? 40 : 44))
                    .tracking(-1.15)
                    .lineSpacing(-4)
                    .foregroundStyle(DarkbloomTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 13)
                    .accessibilityAddTraits(.isHeader)

                Text(message)
                    .font(DarkbloomTheme.chivo(15))
                    .lineSpacing(4)
                    .foregroundStyle(DarkbloomTheme.ink.opacity(0.66))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 18)

                detail
                    .padding(.top, isCompact ? 22 : 27)
            }
            .frame(width: isCompact ? 330 : 365, alignment: .leading)

            visual
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}
