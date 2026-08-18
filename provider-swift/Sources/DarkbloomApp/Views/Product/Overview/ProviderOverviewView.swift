import SwiftUI

struct ProviderOverviewView: View {
    let identity: MachineIdentity
    let store: ProviderStore
    let onOpenChat: () -> Void
    let onOpenLocalAPI: () -> Void
    let onOpenAvailability: () -> Void
    let onOpenMachine: () -> Void
    let onRequestAction: (ProviderAction) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bloomPulse = false

    private var snapshot: ProviderSnapshot { store.snapshot }
    private var presentation: ProviderStatePresentation { snapshot.presentation }

    var body: some View {
        ProductPage {
            providerHero

            if let problem = snapshot.lastProblem {
                problemBanner(problem)
                    .padding(.top, 14)
            }

            metrics
                .padding(.top, 14)

            HStack(alignment: .top, spacing: 14) {
                providerDetails
                privateAI
            }
            .padding(.top, 14)
        }
        .navigationTitle("Overview")
        .task {
            store.startMonitoring()
        }
        .onChange(of: snapshot.runState) { previous, current in
            guard !current.isTransitioning, previous != current else { return }
            bloomPulse = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(700))
                bloomPulse = false
            }
        }
    }

    private var providerHero: some View {
        ZStack {
            SpatialFieldView(
                presentation: .welcome,
                focus: presentation.fieldFocus,
                pointer: CGPoint(x: 0.73, y: 0.50),
                activity: presentation.fieldActivity
            )

            LinearGradient(
                colors: [.white.opacity(0.96), .white.opacity(0.68), .white.opacity(0.18)],
                startPoint: .leading,
                endPoint: .trailing
            )

            HStack(spacing: 28) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(presentation.tint)
                            .frame(width: 8, height: 8)
                            .shadow(color: presentation.tint.opacity(0.45), radius: 5)
                        Text(presentation.overline)
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(1.0)
                    }

                    Text(presentation.title)
                        .font(DarkbloomTheme.chivo(34))
                        .tracking(-1)
                        .lineSpacing(-2)
                        .padding(.top, 13)

                    Text(presentation.detail)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 430, alignment: .leading)
                        .padding(.top, 9)

                    HStack(spacing: 10) {
                        Button {
                            if snapshot.runState == .scheduledOff {
                                onOpenAvailability()
                            } else if snapshot.runState == .attention {
                                onOpenMachine()
                            } else {
                                onRequestAction(store.primaryAction)
                            }
                        } label: {
                            if let pendingAction = store.pendingAction, pendingAction == store.primaryAction {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(minWidth: 100)
                            } else {
                                Label(
                                    snapshot.runState == .attention ? "Review verification" : presentation.primaryActionTitle,
                                    systemImage: snapshot.runState == .scheduledOff
                                        ? "calendar.badge.clock"
                                        : (snapshot.runState == .attention
                                            ? "checkmark.shield"
                                            : store.primaryAction.systemImage)
                                )
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(
                            snapshot.runState == .scheduledOff
                                ? false
                                : !store.canPerform(store.primaryAction)
                        )

                    }
                    .padding(.top, 24)
                }

                Spacer(minLength: 10)

                ZStack {
                    Circle()
                        .stroke(presentation.tint.opacity(reduceMotion ? 0.12 : 0.26), lineWidth: 1)
                        .frame(width: 160, height: 160)
                        .scaleEffect(reduceMotion ? 1 : (bloomPulse ? 1.24 : 0.78))
                        .opacity(reduceMotion ? 1 : (bloomPulse ? 0 : 0.42))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.7), value: bloomPulse)

                    Circle()
                        .fill(.white.opacity(0.52))
                        .frame(width: 152, height: 152)
                        .overlay {
                            Circle().stroke(.white.opacity(0.76), lineWidth: 1)
                        }
                        .shadow(color: DarkbloomTheme.accent.opacity(0.14), radius: 30, y: 12)

                    Image(systemName: identity.formFactor.symbolName)
                        .symbolRenderingMode(.monochrome)
                        .font(.system(size: 82, weight: .ultraLight))
                        .foregroundStyle(.black)

                    if snapshot.isServing {
                        Circle()
                            .fill(DarkbloomTheme.accent)
                            .frame(width: 9, height: 9)
                            .overlay {
                                Circle()
                                    .stroke(.white, lineWidth: 2)
                            }
                            .offset(x: 56, y: -52)
                            .accessibilityLabel("Currently serving")
                    }
                }
                .frame(width: 190)
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 28)
        }
        .frame(minHeight: 266)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.88), lineWidth: 1)
        }
        .shadow(color: DarkbloomTheme.accent.opacity(0.09), radius: 28, y: 14)
        .environment(\.colorScheme, .light)
        .accessibilityElement(children: .contain)
    }

    private var metrics: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4),
            spacing: 10
        ) {
            ProductMetricTile(
                label: "Requests",
                value: snapshot.activity.requestsServed.formatted(),
                detail: "Since provider started"
            )
            ProductMetricTile(
                label: "Tokens",
                value: ProductFormat.compactCount(snapshot.activity.tokensGenerated),
                detail: "Since provider started"
            )
            ProductMetricTile(
                label: "Uptime",
                value: ProductFormat.duration(snapshot.uptime),
                detail: snapshot.pid.map { "Process \($0)" } ?? "Provider is offline"
            )
            ProductMetricTile(
                label: "Inference memory",
                value: ProductFormat.memory(snapshot.capacity?.usedMemoryGB),
                detail: snapshot.capacity.map { "of \(ProductFormat.memory($0.totalMemoryGB))" } ?? "Available when online"
            )
        }
    }

    private var providerDetails: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProductSectionHeader("Network provider")

            VStack(spacing: 17) {
                Button(action: onOpenMachine) {
                    ProductDisclosureRow(
                        icon: snapshot.trust.state == .verified ? "checkmark.shield.fill" : "shield.lefthalf.filled.badge.checkmark",
                        title: snapshot.trust.level,
                        detail: snapshot.trust.reason,
                        tint: snapshot.trust.state == .verified ? ProductPalette.positive : ProductPalette.warning
                    )
                }
                .buttonStyle(.plain)

                Divider()

                Button(action: onOpenAvailability) {
                    ProductDisclosureRow(
                        icon: "calendar.badge.clock",
                        title: snapshot.availability.summary,
                        detail: ProductFormat.nextChange(snapshot.availability.nextChangeAt),
                        tint: DarkbloomTheme.accent
                    )
                }
                .buttonStyle(.plain)

                Divider()

                ProductDisclosureRow(
                    icon: "cube.transparent",
                    title: snapshot.currentModel?.displayName ?? "Models ready",
                    detail: warmModelDetail,
                    tint: DarkbloomTheme.accent,
                    showsChevron: false
                )
            }
            .padding(17)
            .productSurface()
            .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var privateAI: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProductSectionHeader("For you")

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .symbolRenderingMode(.hierarchical)
                        .font(.system(size: 25))
                        .foregroundStyle(DarkbloomTheme.accent)
                    Spacer()
                    ProductStatusBadge(
                        title: snapshot.localEndpoint?.isReachable == true ? "Local" : "Not running",
                        systemImage: snapshot.localEndpoint?.isReachable == true ? "lock.fill" : "pause.fill",
                        tint: snapshot.localEndpoint?.isReachable == true ? ProductPalette.positive : .secondary
                    )
                }

                Text("Private AI on this Mac")
                    .font(.system(size: 16, weight: .semibold))
                    .padding(.top, 18)
                Text(
                    snapshot.localEndpoint?.isReachable == true
                        ? "Connect your own client here, or use the in-app Chat preview. Network routing remains a separate choice."
                        : "Set up an OpenAI-compatible endpoint for your own clients, or explore the in-app Chat preview."
                )
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .padding(.top, 5)

                HStack(spacing: 12) {
                    Button(snapshot.localEndpoint?.isReachable == true ? "Open Local API" : "Set up Local API", systemImage: "arrow.right") {
                        onOpenLocalAPI()
                    }
                    .buttonStyle(.link)

                    Button("Preview Chat") {
                        onOpenChat()
                    }
                    .buttonStyle(.link)
                }
                .padding(.top, 20)
            }
            .padding(17)
            .productSurface()
            .padding(.top, 10)
        }
        .frame(width: 310, alignment: .topLeading)
    }

    private func problemBanner(_ problem: ProviderProblem) -> some View {
        HStack(spacing: 13) {
            Image(systemName: problem.severity == .critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 17))
                .foregroundStyle(problem.severity == .critical ? ProductPalette.critical : ProductPalette.warning)

            VStack(alignment: .leading, spacing: 2) {
                Text(problem.title)
                    .font(.system(size: 12, weight: .semibold))
                Text(problem.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let recoveryTitle = problem.recoveryTitle {
                Button(recoveryTitle) {
                    if snapshot.runState == .stale {
                        onRequestAction(.restart)
                    } else {
                        onOpenMachine()
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .background(ProductPalette.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .stroke(ProductPalette.warning.opacity(0.18), lineWidth: 1)
        }
    }

    private var warmModelDetail: String {
        guard !snapshot.warmModels.isEmpty else { return "No models are resident" }
        let names = snapshot.warmModels.map(\.displayName).joined(separator: ", ")
        return "Warm: \(names)"
    }

}
