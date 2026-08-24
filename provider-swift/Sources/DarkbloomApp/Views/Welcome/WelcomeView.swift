import SwiftUI

struct WelcomeView: View {
    let identity: MachineIdentity
    let resumableDraft: OnboardingDraft?
    let showsPreviewChrome: Bool
    let onContinue: () -> Void
    let onResume: () -> Void
    let onStartOver: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isCapturingDarkbloomPreview) private var isCapturingPreview
    @State private var isPresented = false
    @State private var showsHowItWorks = false
    @State private var confirmsStartOver = false
    @State private var fieldFocus: CGFloat = 0
    @State private var fieldPointer = CGPoint(x: 0.66, y: 0.5)
    @State private var fieldActivity: CGFloat = 0

    private var motionIsReduced: Bool {
        reduceMotion || isCapturingPreview
    }

    var body: some View {
        GeometryReader { geometry in
            let isCompact = geometry.size.width < 960
            let horizontalInset: CGFloat = isCompact ? 44 : 54
            let columnWidth: CGFloat = isCompact ? 340 : 380
            let columnSpacing: CGFloat = isCompact ? 24 : 38
            let fieldWidth = min(
                geometry.size.width,
                max(640, geometry.size.width * 0.74)
            )

            ZStack {
                DarkbloomTheme.canvas
                    .ignoresSafeArea()

                SpatialFieldView(
                    presentation: .welcome,
                    focus: fieldFocus,
                    pointer: fieldPointer,
                    activity: fieldActivity
                )
                .frame(width: fieldWidth, height: geometry.size.height + 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .offset(x: 1)
                .opacity(isPresented ? 1 : 0)
                .scaleEffect(isPresented ? 1 : 1.015, anchor: .trailing)
                .animation(
                    motionIsReduced ? nil : .easeOut(duration: 0.8),
                    value: isPresented
                )

                VStack(spacing: 0) {
                    header
                        .welcomeReveal(isPresented, delay: 0, reduceMotion: motionIsReduced)

                    mainContent(
                        isCompact: isCompact,
                        columnWidth: columnWidth,
                        columnSpacing: columnSpacing
                    )
                    .frame(maxHeight: .infinity, alignment: .center)
                    .offset(y: isCompact ? -10 : -16)
                }
                .padding(.horizontal, horizontalInset)
                .padding(.top, isCompact ? 30 : 34)
                .padding(.bottom, isCompact ? 26 : 30)
            }
        }
        .onAppear {
            isPresented = true
        }
        .sheet(isPresented: $showsHowItWorks) {
            HowItWorksSheet(
                showsPreviewChrome: showsPreviewChrome,
                onStartSetup: onContinue
            )
        }
        .confirmationDialog(
            "Start setup over?",
            isPresented: $confirmsStartOver
        ) {
            Button("Start Over", role: .destructive, action: onStartOver)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears saved UI progress and returns to the first setup screen. It does not change any account, profile, model, or system setting.")
        }
    }

    private var header: some View {
        BrandWordmarkView()
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func mainContent(
        isCompact: Bool,
        columnWidth: CGFloat,
        columnSpacing: CGFloat
    ) -> some View {
        HStack(alignment: .center, spacing: columnSpacing) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Put your Mac\nto work.")
                    .font(DarkbloomTheme.chivo(isCompact ? 44 : 48))
                    .tracking(-1.4)
                    .lineSpacing(-4)
                    .foregroundStyle(DarkbloomTheme.ink)
                    .accessibilityAddTraits(.isHeader)
                    .welcomeReveal(isPresented, delay: 0.04, reduceMotion: motionIsReduced)

                Text("Run AI privately on this Mac. When it’s idle, it can contribute spare capacity to the Darkbloom network.")
                    .font(DarkbloomTheme.chivo(16))
                    .lineSpacing(5)
                    .foregroundStyle(DarkbloomTheme.ink.opacity(0.7))
                    .frame(maxWidth: isCompact ? 340 : 370, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 22)
                    .welcomeReveal(isPresented, delay: 0.11, reduceMotion: motionIsReduced)

                if let resumableDraft {
                    ResumeSetupCard(
                        draft: resumableDraft,
                        showsPreviewChrome: showsPreviewChrome,
                        onResume: onResume,
                        onStartOver: { confirmsStartOver = true }
                    )
                    .padding(.top, isCompact ? 26 : 30)
                    .welcomeReveal(isPresented, delay: 0.18, reduceMotion: motionIsReduced)
                } else {
                    HStack(spacing: isCompact ? 14 : 18) {
                        SetupMacButton(
                            action: onContinue,
                            onHoverChanged: { isHovering in
                                withAnimation(
                                    motionIsReduced ? nil : .easeOut(duration: 0.3)
                                ) {
                                    fieldActivity = isHovering ? 0.42 : 0
                                }
                            }
                        )
                            .keyboardShortcut(.defaultAction)

                        HowItWorksButton(width: isCompact ? 132 : 142) {
                            showsHowItWorks = true
                        }
                    }
                    .padding(.top, isCompact ? 32 : 36)
                    .welcomeReveal(isPresented, delay: 0.18, reduceMotion: motionIsReduced)
                }
            }
            .frame(width: columnWidth, alignment: .leading)

            MacDeviceArtwork(
                identity: identity,
                fieldFocus: $fieldFocus,
                fieldPointer: $fieldPointer
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct WelcomeRevealModifier: ViewModifier {
    let isPresented: Bool
    let delay: TimeInterval
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isPresented ? 1 : 0)
            .offset(y: reduceMotion || isPresented ? 0 : 10)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.48).delay(delay),
                value: isPresented
            )
    }
}

private extension View {
    func welcomeReveal(
        _ isPresented: Bool,
        delay: TimeInterval,
        reduceMotion: Bool
    ) -> some View {
        modifier(
            WelcomeRevealModifier(
                isPresented: isPresented,
                delay: delay,
                reduceMotion: reduceMotion
            )
        )
    }
}
