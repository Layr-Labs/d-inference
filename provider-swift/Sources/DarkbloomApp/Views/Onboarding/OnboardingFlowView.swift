import SwiftUI

struct OnboardingFlowView: View {
    let identity: MachineIdentity
    let onExit: () -> Void
    let onFinish: (OnboardingCompletionChoice) -> Void

    let flow: OnboardingFlowModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isCapturingDarkbloomPreview) private var isCapturingPreview

    init(
        identity: MachineIdentity,
        flow: OnboardingFlowModel? = nil,
        previewConfiguration: OnboardingPreviewConfiguration? = nil,
        onExit: @escaping () -> Void,
        onFinish: @escaping (OnboardingCompletionChoice) -> Void
    ) {
        self.identity = identity
        self.onExit = onExit
        self.onFinish = onFinish
        self.flow = flow ?? OnboardingFlowModel(
            startingAt: previewConfiguration?.step ?? .readiness,
            previewVariant: previewConfiguration?.variant,
            freezesAutomaticProgress: previewConfiguration != nil
        )
    }

    private var motionIsReduced: Bool {
        reduceMotion || isCapturingPreview
    }

    var body: some View {
        GeometryReader { geometry in
            let isCompact = geometry.size.width < 960
            let horizontalInset: CGFloat = isCompact ? 40 : 54
            let fieldWidth = min(
                geometry.size.width,
                max(640, geometry.size.width * 0.74)
            )

            ZStack {
                DarkbloomTheme.canvas
                    .ignoresSafeArea()

                SpatialFieldView(
                    presentation: .welcome,
                    focus: flow.fieldFocus,
                    pointer: CGPoint(x: 0.67, y: 0.5),
                    activity: flow.fieldActivity
                )
                .frame(width: fieldWidth, height: geometry.size.height + 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .offset(x: 1)
                .animation(
                    motionIsReduced ? nil : .easeInOut(duration: 0.42),
                    value: flow.fieldFocus
                )
                .animation(
                    motionIsReduced ? nil : .easeInOut(duration: 0.42),
                    value: flow.fieldActivity
                )

                VStack(spacing: 0) {
                    header

                    if flow.isRestoredFromDraft {
                        ResumedSetupNotice(state: flow.resumeReconciliationState)
                            .padding(.top, 8)
                            .transition(.opacity)
                    }

                    ZStack {
                        currentStep(isCompact: isCompact)
                            .id(flow.step)
                            .transition(stepTransition)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(.horizontal, horizontalInset)
                .padding(.top, isCompact ? 30 : 34)
                .padding(.bottom, isCompact ? 26 : 30)
            }
        }
        .animation(
            motionIsReduced ? .easeOut(duration: 0.2) : .easeOut(duration: 0.44),
            value: flow.step
        )
        .task(id: flow.step) {
            await flow.reconcileRestoredProgress()
            await flow.runAutomaticWorkForCurrentStep()
        }
    }

    private var header: some View {
        HStack {
            BrandWordmarkView()

            Spacer()

            if flow.step != .complete {
                Button {
                    if !flow.goBack() {
                        onExit()
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 9, weight: .semibold))
                        Text(flow.step == .readiness ? "Back to welcome" : "Back")
                            .font(DarkbloomTheme.chivo(11, weight: .medium))
                    }
                    .foregroundStyle(DarkbloomTheme.ink.opacity(0.44))
                    .frame(height: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("onboarding.back")
            }
        }
        .frame(height: 32)
    }

    @ViewBuilder
    private func currentStep(isCompact: Bool) -> some View {
        switch flow.step {
        case .readiness:
            ReadinessStepView(
                flow: flow,
                identity: identity,
                isCompact: isCompact,
                onExit: onExit
            )
        case .account:
            AccountLinkStepView(flow: flow, identity: identity, isCompact: isCompact)
        case .enrollment:
            EnrollmentStepView(flow: flow, isCompact: isCompact)
        case .preparation:
            PreparationStepView(flow: flow, identity: identity, isCompact: isCompact)
        case .verification:
            VerificationStepView(flow: flow, identity: identity, isCompact: isCompact)
        case .complete:
            SetupCompleteStepView(identity: identity, isCompact: isCompact, onFinish: onFinish)
        }
    }

    private var stepTransition: AnyTransition {
        if motionIsReduced {
            return .opacity
        }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 10)),
            removal: .opacity.combined(with: .offset(y: -8))
        )
    }
}
