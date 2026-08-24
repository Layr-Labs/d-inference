import SwiftUI

struct ContentView: View {
    let showsLaunchExperience: Bool
    let launchMode: DarkbloomLaunchMode
    let onboardingPreview: OnboardingPreviewConfiguration?
    let productPreview: ProductPreviewConfiguration?
    let appFlowStore: AppFlowStore
    let providerStore: ProviderStore
    let modelLibraryStore: ModelLibraryStore
    let diagnosticsStore: DiagnosticsStore
    let contributionsStore: ContributionsStore
    let localAPIStore: LocalAPIStore
    let myMacsStore: MyMacsStore
    let availabilityStore: AvailabilityStore

    @State private var appIsVisible: Bool
    @State private var launchIsVisible: Bool
    @State private var identity = MachineIdentity.loading

    private var showsPreviewChrome: Bool {
        PreviewChromePresentation.isVisible(
            hasOnboardingPreview: onboardingPreview != nil,
            hasProductPreview: productPreview != nil
        )
    }

    init(
        showsLaunchExperience: Bool = true,
        launchMode: DarkbloomLaunchMode = .full,
        onboardingPreview: OnboardingPreviewConfiguration? = nil,
        productPreview: ProductPreviewConfiguration? = nil,
        appFlowStore: AppFlowStore = AppFlowStore(),
        providerStore: ProviderStore = ProviderStore(),
        modelLibraryStore: ModelLibraryStore = ModelLibraryStore(),
        diagnosticsStore: DiagnosticsStore = DiagnosticsStore(),
        contributionsStore: ContributionsStore = ContributionsStore(),
        localAPIStore: LocalAPIStore = LocalAPIStore(),
        myMacsStore: MyMacsStore = MyMacsStore(),
        availabilityStore: AvailabilityStore = AvailabilityStore()
    ) {
        self.showsLaunchExperience = showsLaunchExperience
        self.launchMode = launchMode
        self.onboardingPreview = onboardingPreview
        self.productPreview = productPreview
        self.appFlowStore = appFlowStore
        self.providerStore = providerStore
        self.modelLibraryStore = modelLibraryStore
        self.diagnosticsStore = diagnosticsStore
        self.contributionsStore = contributionsStore
        self.localAPIStore = localAPIStore
        self.myMacsStore = myMacsStore
        self.availabilityStore = availabilityStore
        _appIsVisible = State(initialValue: !showsLaunchExperience)
        _launchIsVisible = State(initialValue: showsLaunchExperience)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !launchIsVisible, showsPreviewChrome {
                UIPreviewNotice()
            }

            ZStack {
                if appIsVisible {
                    switch appFlowStore.phase {
                    case .welcome:
                        WelcomeView(
                            identity: identity,
                            resumableDraft: appFlowStore.resumableOnboardingDraft,
                            showsPreviewChrome: showsPreviewChrome,
                            onContinue: {
                                withAnimation(.easeOut(duration: 0.44)) {
                                    appFlowStore.startOnboarding()
                                }
                            },
                            onResume: {
                                withAnimation(.easeOut(duration: 0.44)) {
                                    appFlowStore.resumeOnboarding()
                                }
                            },
                            onStartOver: {
                                withAnimation(.easeOut(duration: 0.44)) {
                                    appFlowStore.startOverOnboarding()
                                }
                            }
                        )
                        .transition(.opacity.combined(with: .offset(x: -10)))
                    case .onboarding:
                        OnboardingFlowView(
                            identity: identity,
                            flow: appFlowStore.onboardingFlow,
                            previewConfiguration: onboardingPreview,
                            onExit: {
                                withAnimation(.easeOut(duration: 0.4)) {
                                    appFlowStore.leaveOnboarding()
                                }
                            },
                            onFinish: { choice in
                                withAnimation(.easeOut(duration: 0.44)) {
                                    _ = appFlowStore.completeOnboarding(opening: choice.destination)
                                }
                            }
                        )
                        .transition(.opacity.combined(with: .offset(x: 10)))
                    case .product:
                        ProductShellView(
                            identity: identity,
                            providerStore: providerStore,
                            modelLibraryStore: modelLibraryStore,
                            diagnosticsStore: diagnosticsStore,
                            contributionsStore: contributionsStore,
                            localAPIStore: localAPIStore,
                            myMacsStore: myMacsStore,
                            availabilityStore: availabilityStore,
                            chatFixture: productPreview?.chatFixture ?? .empty,
                            isPreview: showsPreviewChrome,
                            initialDestination: productPreview?.destination
                                ?? appFlowStore.pendingInitialProductDestination,
                            onSelectDestination: appFlowStore.selectProductDestination,
                            onInitialDestinationApplied: appFlowStore.consumePendingInitialProductDestination
                        )
                        .transition(.opacity)
                    }
                }

                if launchIsVisible {
                    DarkbloomLaunchView(
                        mode: launchMode,
                        onRevealApp: {
                            appIsVisible = true
                        },
                        onFinished: {
                            launchIsVisible = false
                        }
                    )
                    .zIndex(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            let detected = await SystemProfilerMachineIdentityProvider().current()
            withAnimation(.easeOut(duration: 0.28)) {
                identity = detected
            }
        }
        .onChange(of: providerStore.snapshot) { _, snapshot in
            guard !showsPreviewChrome else { return }
            appFlowStore.applyBootstrapEvidence(
                AppFlowBootstrapEvidence(snapshot: snapshot)
            )
        }
        #if DEBUG
        .task {
            await PreviewCapture.captureIfRequested()
        }
        #endif
    }
}
